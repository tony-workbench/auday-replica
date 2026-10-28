"""Application state: settings, records (Auday format), audio assets, jobs and AI flows.

Records use Auday's shape: id, kind (transcript|highlight|summary|reflection|
memory), title, text, start, timeZone, status, sourceIDs, audioAssetID, revision.
"""

import hashlib
import io
import json
import os
import queue
import re
import sqlite3
import tempfile
import threading
import time
import traceback
import wave
import zipfile
from datetime import datetime, timedelta
from pathlib import Path

from memengine import MemoryEngine, Store, format_context, llm, retrieve, schema
from memengine.embed import HashEmbedder, HTTPEmbedder

from . import ai, auday_chat, auday_mode, health, location, remote_asr, search, secret_box, speaker, transcribe

APP_DDL = """
CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY, body TEXT);
CREATE TABLE IF NOT EXISTS marks(id INTEGER PRIMARY KEY AUTOINCREMENT, start TEXT, note TEXT);
CREATE TABLE IF NOT EXISTS hours(date TEXT, hour INTEGER, state TEXT, error TEXT, attempts INTEGER,
  updated_at TEXT, PRIMARY KEY(date, hour));
CREATE TABLE IF NOT EXISTS chats(id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, role TEXT,
  content TEXT, cited TEXT);
CREATE TABLE IF NOT EXISTS days(end_at TEXT PRIMARY KEY, state TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS places(t TEXT PRIMARY KEY, lat REAL, lon REAL, accuracy REAL, name TEXT,
  session TEXT);
CREATE TABLE IF NOT EXISTS health_samples(kind TEXT, start TEXT, end TEXT, value REAL,
  PRIMARY KEY(kind, start, end));
"""

DEFAULT_SETTINGS = {
    # AI provider (bring your own, like Auday). Default: the local MLX server.
    "provider": "openai",           # openai | anthropic | gemini | none
    "base_url": "http://127.0.0.1:8089/v1",
    "model": "default_model",
    "api_key": "",
    "system_prefix": "/no_think\n",
    # Automatic features
    "auto_transcribe": True,
    "auto_hourly": True,
    "auto_memory": True,
    "auto_daily": True,             # Auday: Daily Reflection on/off
    "audio_retention_days": 0,      # Auday: Keep original audio; 0 = forever
    "omit_silence": True,           # Auday: very quiet stretches keep their time but no stored sound
    "body_data": True,              # Auday: Body data (Apple Health); used once an export is imported
    "location_data": True,          # Auday: Location data (watch places); used once the watch sends some
    # Transcription
    "whisper_model": "sensevoice",  # "sensevoice" = Local efficient; a Whisper size = Local accurate; "remote" = cloud
    # Cloud & self-hosted transcription (whisper_model "remote")
    "asr_service": "openai",        # openai (/audio/transcriptions: OpenAI, Groq, self-hosted Whisper) | deepgram
    "asr_base_url": "",
    "asr_api_key": "",
    "asr_model": "",
    "language": "",                 # "" = auto-detect
    "mic_is_me": True,              # no diarization: microphone speech is the user's voice
    # Embeddings: "hash" (offline) or an OpenAI-compatible /v1/embeddings endpoint
    "embedder": "hash",
    "embed_url": "",
    "embed_model": "",
    "time_zone": "",
    # Pipeline: "improved" (our memory engine) or "auday" (the observed Auday pipeline)
    "pipeline": "improved",
    "voice_labels": "auday",        # how Me* reaches the model in auday mode: auday (me:1) | improved (mixed)
    "primary_language": "English",
    "secondary_language": "",       # e.g. "Chinese": helps transcription; generated text is still the primary language
    "reflection_time": "21:00",     # the "day" is the 24 hours ending here; daily review runs then
    # Connect to your workflow: the official Auday Skill pairs with and syncs from the replica (app/workflow_server.py)
    "workflow_enabled": False,
    "workflow_access": "text",      # text (all text) | text-and-audio; both read-only
    "workflow_password": "",        # 16-character communication password, generated or the user's own
    "workflow_name": "",            # Bonjour name; "" = "Auday Replica (<this Mac>)"
}

SECRET_KEYS = ("api_key", "asr_api_key", "workflow_password")
LANGUAGE_NAMES = ("English", "Chinese", "Cantonese", "Japanese", "Korean")
SESSION_BREAK = 2.0     # seconds of missing audio that end a recording session
MODELS_DIR = Path(os.environ.get("AUDAY_MODELS", Path.home() / ".cache" / "auday-replica" / "models"))


def now_local():
    return datetime.now().astimezone()


def iso(dt):
    return dt.replace(microsecond=0).isoformat()


def stamp(start):
    return re.sub(r"[^0-9]", "", start[:19])[:8] + "-" + re.sub(r"[^0-9]", "", start[11:19])


class App:
    def __init__(self, data_dir, provider=None, transcriber=None):
        self.data = Path(data_dir)
        (self.data / "audio").mkdir(parents=True, exist_ok=True)
        self.db_path = self.data / "auday.sqlite"
        self.secrets = secret_box.SecretBox(self.data)
        self._local = threading.local()
        self._provider_override = provider
        self._transcriber = transcriber or transcribe.transcribe
        self.jobs = queue.Queue()
        self.activity = []          # recent job log for the UI
        self.current = None
        self.usage = llm.Usage()
        with self.db:
            self.db.executescript(APP_DDL + search.DDL)
            self.db.execute("UPDATE hours SET state='pending' WHERE state='running'")  # crash recovery
            if "conversation" not in {r[1] for r in self.db.execute("PRAGMA table_info(chats)")}:
                self.db.execute("ALTER TABLE chats ADD COLUMN conversation TEXT")

    # ---------- per-thread connections ----------
    @property
    def store(self):
        if getattr(self._local, "store", None) is None:
            self._local.store = Store(str(self.db_path), embedder=self.embedder())
        return self._local.store

    @property
    def db(self):
        return self.store.db

    # ---------- settings ----------
    def settings(self):
        row = self.db.execute("SELECT value FROM metadata WHERE key='settings'").fetchone()
        values = {**DEFAULT_SETTINGS, **(json.loads(row[0]) if row else {})}
        if any(values[k] and not values[k].startswith(secret_box.PREFIX) for k in SECRET_KEYS):
            self._save_settings(values)           # settings saved before encryption: seal them now
        for key in SECRET_KEYS:
            values[key] = self.secrets.open(values[key])
        return values

    def _save_settings(self, values):
        stored = {**values, **{k: self.secrets.seal(values[k]) for k in SECRET_KEYS}}
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO metadata VALUES('settings', ?)", (json.dumps(stored),))

    def public_settings(self):
        values = self.settings()
        for key in SECRET_KEYS:
            values[key] = ("•" * 8 + values[key][-4:]) if values[key] else ""
        return values

    def update_settings(self, changes):
        values = self.settings()
        for key, value in changes.items():
            if key not in DEFAULT_SETTINGS:
                continue
            if key in SECRET_KEYS and isinstance(value, str) and value.startswith("•"):
                continue  # masked value sent back unchanged
            if key == "language" and value not in ("", *transcribe.LANGUAGES):
                continue  # the five languages of Auday's Local efficient mode (SenseVoice)
            if key in ("primary_language", "secondary_language") and value not in ("", *LANGUAGE_NAMES):
                continue
            values[key] = value
        self._save_settings(values)
        self._local.store = None  # embedder may have changed
        return self.public_settings()

    def provider(self):
        if self._provider_override is not None:
            return self._provider_override
        s = self.settings()
        if s["provider"] == "none":
            return None
        if s["provider"] == "anthropic":
            return llm.AnthropicProvider(model=s["model"], api_key=s["api_key"] or None,
                                         base_url=s["base_url"] if "anthropic" in s["base_url"] else None)
        if s["provider"] == "gemini":
            return llm.GeminiProvider(model=s["model"], api_key=s["api_key"] or None)
        return llm.OpenAICompatibleProvider(model=s["model"], base_url=s["base_url"],
                                            api_key=s["api_key"], system_prefix=s["system_prefix"])

    def embedder(self):
        row = None
        try:
            conn = sqlite3.connect(str(self.db_path))
            row = conn.execute("SELECT value FROM metadata WHERE key='settings'").fetchone()
            conn.close()
        except sqlite3.Error:
            pass
        s = {**DEFAULT_SETTINGS, **(json.loads(row[0]) if row else {})}
        if s["embedder"] == "http" and s["embed_url"]:
            return HTTPEmbedder(s["embed_url"], s["embed_model"])
        return HashEmbedder()

    # ---------- records ----------
    def put_record(self, record):
        self.store.put_record(record)
        with self.db:
            search.index_record(self.db, self.store.embedder, record)

    def records(self, kind=None, date=None, hour=None):
        sql, args = "SELECT body FROM records WHERE 1=1", []
        if kind:
            sql += " AND kind=?"
            args.append(kind)
        if date:
            sql += " AND date=?"
            args.append(date)
        rows = [json.loads(r[0]) for r in self.db.execute(sql, args)]
        if hour is not None:
            rows = [r for r in rows if int(r.get("start", "T00")[11:13]) == hour]
        return sorted(rows, key=lambda r: (r.get("start") or "", r["id"]))

    def unique_id(self, base):
        candidate, n = base, 2
        while self.store.record(candidate) is not None:
            candidate, n = f"{base}-{n}", n + 1
        return candidate

    def add_transcript(self, start, segments, *, audio_id=None, language=None, title=None):
        record = {"id": self.unique_id(f"transcript-{stamp(start)}"), "kind": "transcript",
                  "title": title or "", "start": start, "timeZone": self.time_zone(),
                  "text": "\n".join(s["text"] for s in segments), "segments": segments,
                  "status": "saved", "sourceIDs": [], "revision": 1}
        if audio_id:
            record["audioAssetID"] = audio_id
        if language:
            record["language"] = language
        self.put_record(record)
        self.touch_hour(start[:10], int(start[11:13]))
        return record

    def time_zone(self):
        return self.settings()["time_zone"] or (now_local().tzname() or "local")

    # ---------- audio ----------
    def save_audio(self, data, start, *, suffix=".webm", speaker=None, language=None, session=None, fragment=None):
        """`session` is the recorder's own session ID (the watch app sends one; a call starts a new one).
        `fragment` makes uploads idempotent: the phone retries until it gets an answer, so a fragment
        that already arrived is returned instead of stored twice."""
        if fragment:
            row = self.db.execute("SELECT body FROM assets WHERE json_extract(body, '$.fragment')=?",
                                  (fragment,)).fetchone()
            if row:
                return {**json.loads(row[0]), "duplicate": True}
        asset_id = self.unique_asset(f"audio-{stamp(start)}")
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as handle:
            handle.write(data)
            raw = Path(handle.name)
        wav = self.data / "audio" / f"{asset_id}.wav"
        try:
            duration = transcribe.to_wav(raw, wav)
        finally:
            raw.unlink(missing_ok=True)
        asset = {"id": asset_id, "mime": "audio/wav", "start": start, "duration": duration,
                 "path": wav.name, "speaker": speaker, "language": language, "state": "saved"}
        if self.settings()["omit_silence"]:
            begin = datetime.fromisoformat(start)
            protect = [((datetime.fromisoformat(m["start"]) - begin).total_seconds() - 10,
                        (datetime.fromisoformat(m["start"]) - begin).total_seconds() + 10)
                       for m in self.marks(start[:10])]
            timeline = transcribe.compact(wav, protect)
            if timeline:
                asset["timeline"] = timeline
        asset.update({k: v for k, v in (("session", session), ("fragment", fragment)) if v})
        self.put_asset(asset)
        if self.settings()["auto_transcribe"]:
            self.enqueue("transcribe", asset_id=asset_id)
        return asset

    def unique_asset(self, base):
        candidate, n = base, 2
        while self.asset(candidate):
            candidate, n = f"{base}-{n}", n + 1
        return candidate

    def put_asset(self, asset):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO assets VALUES(?,?)",
                            (asset["id"], json.dumps(asset, ensure_ascii=False)))

    def asset(self, asset_id):
        row = self.db.execute("SELECT body FROM assets WHERE id=?", (asset_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def audio_path(self, asset_id):
        asset = self.asset(asset_id)
        return self.data / "audio" / asset["path"] if asset and asset.get("path") else None

    def hour_audio(self, date, hour):
        """The hour's recorded pieces back to back as one WAV (Auday's "Saved audio 13:00 – 14:00").
        Cached until the hour's audio changes."""
        assets = []
        for record in sorted(self.records("transcript", date, hour), key=lambda r: r["start"]):
            path = self.audio_path(record["audioAssetID"]) if record.get("audioAssetID") else None
            if path and path.exists() and record["audioAssetID"] not in assets:
                assets.append(record["audioAssetID"])
        if not assets:
            return None
        key = hashlib.sha256("\n".join(assets).encode()).hexdigest()[:16]
        target = self.data / "cache" / f"hour-{date}-{hour:02d}-{key}.wav"
        if not target.exists():
            target.parent.mkdir(exist_ok=True)
            for old in target.parent.glob(f"hour-{date}-{hour:02d}-*.wav"):
                old.unlink()
            with wave.open(str(target), "wb") as out:
                for n, asset_id in enumerate(assets):
                    with wave.open(str(self.audio_path(asset_id)), "rb") as piece:
                        if n == 0:
                            out.setparams(piece.getparams())
                        frames = piece.readframes(piece.getnframes())
                        width, rate = piece.getsampwidth() * piece.getnchannels(), piece.getframerate()
                    timeline = self.asset(asset_id).get("timeline")
                    if not timeline:
                        out.writeframes(frames)
                        continue
                    written = 0.0                  # dropped quiet plays back as silence of its length
                    for part in timeline:
                        gap = part["recordedOffset"] - written
                        if gap > 0:
                            out.writeframes(b"\x00" * width * int(gap * rate))
                        out.writeframes(frames[int(part["fileStart"] * rate) * width:int(part["fileEnd"] * rate) * width])
                        written = part["recordedOffset"] + part["fileEnd"] - part["fileStart"]
                    tail = (self.asset(asset_id).get("duration") or written) - written
                    if tail > 0:
                        out.writeframes(b"\x00" * width * int(tail * rate))
        return target

    def prune_audio(self, now=None):
        """Keep original audio for audio_retention_days (0 = forever). Transcripts stay."""
        days = int(self.settings()["audio_retention_days"] or 0)
        if days <= 0:
            return []
        cutoff = (now or now_local()) - timedelta(days=days)
        pruned = []
        for (body,) in self.db.execute("SELECT body FROM assets").fetchall():
            asset = json.loads(body)
            if not asset.get("path") or asset.get("state") not in ("transcribed", "silent"):
                continue
            if datetime.fromisoformat(asset["start"]) < cutoff:
                (self.data / "audio" / asset["path"]).unlink(missing_ok=True)
                asset["path"], asset["audioDeleted"] = None, True
                self.put_asset(asset)
                pruned.append(asset["id"])
        return pruned

    # ---------- Apple Health (Auday: Body & location data) ----------
    def import_health(self, data):
        """An Apple Health export (zip or export.xml bytes), for history from before the iPhone
        synced. Stays in this data dir."""
        return self._store_health(health.read_export(data))

    def sync_health(self, samples):
        """New HealthKit samples from the iPhone companion, which reads them as Auday does:
        {kind: [[start ISO, end ISO, value], ...]} for hr, hrv, steps, effort, rest, sleep, workout."""
        kinds = set(health.TYPES.values()) | {"sleep", "workout"}
        unknown = set(samples) - kinds
        if unknown:
            raise ValueError(f"Unknown health sample kinds: {sorted(unknown)}")
        parsed = {}
        for kind, rows in samples.items():
            parsed[kind] = []
            for start, end, value in rows:
                a, b = datetime.fromisoformat(start), datetime.fromisoformat(end)
                if a.tzinfo is None or b.tzinfo is None:
                    raise ValueError("Health sample times must include a UTC offset.")
                parsed[kind].append((a, b, float(value)))
        return self._store_health(parsed)

    def _store_health(self, samples):
        """Adds samples (repeats are stored once) and rebuilds the body context from all of them,
        so a day's intervals come out the same however the samples arrived."""
        with self.db:
            self.db.executemany("INSERT OR REPLACE INTO health_samples VALUES(?,?,?,?)",
                                [(kind, a.isoformat(), b.isoformat(), v)
                                 for kind, rows in samples.items() for a, b, v in rows])
        everything = {kind: [] for kind in (*health.TYPES.values(), "sleep", "workout")}
        for kind, a, b, v in self.db.execute("SELECT kind, start, end, value FROM health_samples"):
            everything.setdefault(kind, []).append((datetime.fromisoformat(a), datetime.fromisoformat(b), v))
        for rows in everything.values():
            rows.sort()
        intervals = health.body_context(everything)
        keep = {k: [(a.isoformat(), b.isoformat(), v) for a, b, v in everything[k]] for k in ("hr", "hrv", "rest")}
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO metadata VALUES('health', ?)",
                            (json.dumps({"intervals": intervals, "samples": keep}),))
        return {"intervals": len(intervals), "heartRateSamples": len(keep["hr"]),
                "added": sum(len(rows) for rows in samples.values())}

    def _health(self):
        if not self.settings()["body_data"]:
            return None
        row = self.db.execute("SELECT value FROM metadata WHERE key='health'").fetchone()
        if not row:
            return None
        data = json.loads(row[0])
        samples = {k: [(datetime.fromisoformat(a), datetime.fromisoformat(b), v) for a, b, v in rows]
                   for k, rows in data["samples"].items()}
        return data["intervals"], samples

    def body_for(self, start, end, ranges=()):
        """Body & location context for [start, end): body intervals clipped to it, heart-rate
        statistics per recorded range (Auday computes them per audio fragment), the bodyState
        signals, and the watch's places as locationContext labels."""
        loaded, places = self._health(), self.location_for(start, end)
        if loaded is None and not places:
            return None
        body = {"bodyContext": [], "healthStatistics": [], "signals": [], "locationContext": places}
        if loaded is not None:
            intervals, samples = loaded
            clipped = health.within(intervals, start, end)
            stats = []
            for a, b in (ranges or [(start, end)]):
                stats += health.statistics(samples, a, b)
            body.update(bodyContext=clipped, healthStatistics=stats, signals=health.signals(clipped))
        return body

    # ---------- watch places (Auday: Location data) ----------
    def add_places(self, samples, session=None):
        """Positions the watch noted while recording, named by the phone. Coordinates stay here;
        only approximate labels reach the AI. A resent sample keeps its name if the new copy has none."""
        parsed = location.parse(samples)
        with self.db:
            self.db.executemany(
                "INSERT INTO places VALUES(?,?,?,?,?,?) ON CONFLICT(t) DO UPDATE SET "
                "name=coalesce(excluded.name, places.name), accuracy=excluded.accuracy",
                [(iso(p["t"]), p["lat"], p["lon"], p["accuracy"], p["name"], session) for p in parsed])
        return {"places": len(parsed)}

    def location_for(self, start, end):
        if not self.settings()["location_data"]:
            return []
        lo, hi = start - location.JOIN - location.BEFORE, end + location.AFTER
        rows = [{"t": datetime.fromisoformat(t), "lat": lat, "lon": lon, "accuracy": acc or 0, "name": location.place_name(name)}
                for t, lat, lon, acc, name in self.db.execute("SELECT t, lat, lon, accuracy, name FROM places")
                if lo <= datetime.fromisoformat(t) <= hi]
        if not rows:
            return []
        cuts = set()
        for (body,) in self.db.execute("SELECT body FROM assets"):
            asset = json.loads(body)
            begin = datetime.fromisoformat(asset["start"])
            if asset.get("duration") and start - timedelta(hours=1) <= begin < end:
                cuts |= {begin, begin + timedelta(seconds=asset["duration"])}
        return location.context(sorted(rows, key=lambda r: r["t"]), start, end, cuts)

    def list_models(self):
        s = self.settings()
        if s["provider"] == "none":
            return {"models": []}
        try:
            return {"models": llm.list_models(s["provider"], base_url=s["base_url"], api_key=s["api_key"])}
        except Exception as error:
            return {"models": [], "error": str(error)[:300]}

    def check_connection(self):
        """Auday's "Check Connection & Save": one tiny request to the configured AI."""
        provider = self.provider()
        if provider is None:
            return {"ok": False, "error": "AI is turned off. Choose an AI service in Settings."}
        try:
            # Auday's check. Any reply that mentions "ok" passes.
            reply = provider.complete('This is a connection check. Return only the JSON object {"ok":true}.',
                                      'Return {"ok":true}.')
            if '"ok"' not in str(reply).replace(" ", "") and "ok" not in str(reply).lower():
                return {"ok": False, "error": f"Unexpected reply from the AI: {str(reply)[:80]}"}
            return {"ok": True, "reply": str(reply)[:40]}
        except Exception as error:
            return {"ok": False, "error": str(error)[:300]}

    def run_transcribe(self, asset_id):
        asset = self.asset(asset_id)
        settings = self.settings()
        language_hint = asset.get("language") or settings["language"] or None
        if settings["whisper_model"] == "remote":
            language, segments = remote_asr.transcribe(
                self.audio_path(asset_id), kind=settings["asr_service"], base_url=settings["asr_base_url"],
                api_key=settings["asr_api_key"], model=settings["asr_model"], language=language_hint)
        else:
            language, segments = self._transcriber(
                self.audio_path(asset_id), model_name=settings["whisper_model"],
                download_root=MODELS_DIR, language=language_hint)
        timeline = asset.get("timeline")
        speaker = asset.get("speaker") or ("user" if settings["mic_is_me"] else "unknown")
        segments = [{**s, "speaker": speaker} for s in segments]
        voice = self.voiceprint()
        if voice is not None and segments:
            audio = transcribe.read_wav(self.audio_path(asset_id))
            for segment in segments:
                clip = audio[int(max(0, segment["start"] - 0.2) * transcribe.SR):int((segment["end"] + 0.2) * transcribe.SR)]
                segment["owner"] = voice.label(clip, settings["voice_labels"], self.voice_thresholds())
                segment["speaker"] = "user" if segment["owner"] == "Me" else "unknown"
        for segment in segments:               # stored-file times -> recording times
            segment["start"] = round(transcribe.recorded_time(timeline, segment["start"]), 2)
            segment["end"] = round(transcribe.recorded_time(timeline, segment["end"]), 2)
        asset["state"] = "transcribed" if segments else "silent"
        self.put_asset(asset)
        if segments:
            return self.add_transcript(asset["start"], segments, audio_id=asset_id, language=language)
        return None

    # ---------- voiceprint ----------
    def voiceprint(self):
        path = self.data / "voiceprint.npy"
        if not path.exists():
            return None
        return speaker.Voiceprint.load(speaker.ensure_model(MODELS_DIR), path)

    def enroll_voice(self, data, suffix=".webm"):
        """A short clean reading (Auday: three readings, about 45 s) becomes the owner's voiceprint."""
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as handle:
            handle.write(data)
            raw = Path(handle.name)
        wav = self.data / "voiceprint.wav"
        try:
            duration = transcribe.to_wav(raw, wav)
        finally:
            raw.unlink(missing_ok=True)
        voice = speaker.Voiceprint(speaker.ensure_model(MODELS_DIR))
        voice.enroll(transcribe.read_wav(wav))
        voice.save(self.data / "voiceprint.npy")
        return {"enrolled": True, "seconds": round(duration, 1)}

    def voice_thresholds(self):
        row = self.db.execute("SELECT value FROM metadata WHERE key='voice_thresholds'").fetchone()
        return json.loads(row[0]) if row else None

    def _snippet_clips(self):
        """(record, segment, clip) for every transcript snippet with stored audio."""
        for record in self.records("transcript"):
            asset = self.asset(record.get("audioAssetID", "")) if record.get("audioAssetID") else None
            path = self.audio_path(asset["id"]) if asset else None
            if not path or not path.exists():
                continue
            audio, timeline = transcribe.read_wav(path), asset.get("timeline")
            offset = (datetime.fromisoformat(record["start"]) - datetime.fromisoformat(asset["start"])).total_seconds()
            for segment in record.get("segments", []):
                a = transcribe.file_time(timeline, offset + segment["start"])
                b = transcribe.file_time(timeline, offset + segment["end"])
                yield record, segment, audio[int(max(0, a - 0.2) * transcribe.SR):int((b + 0.2) * transcribe.SR)]

    def relabel_voices(self):
        """After enrolling a voice: calibrate the thresholds on this owner's own recordings, then
        recompute Me / Me* everywhere without transcribing again. Returns how many snippets changed."""
        voice, mode, changed = self.voiceprint(), self.settings()["voice_labels"], 0
        if voice is None:
            raise ValueError("Enrol your voice first.")
        scores = [voice.score(clip) for _, _, clip in self._snippet_clips() if len(clip) >= speaker.MIN_SECONDS * transcribe.SR]
        thresholds = speaker.calibrate(scores, mode)
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO metadata VALUES('voice_thresholds', ?)", (json.dumps(thresholds),))
        touched = {}
        for record, segment, clip in self._snippet_clips():
            owner = voice.label(clip, mode, thresholds)
            if owner != segment.get("owner"):
                changed += 1
            segment["owner"], segment["speaker"] = owner, ("user" if owner == "Me" else "unknown")
            touched[record["id"]] = record
        for record in touched.values():
            record["revision"] = record.get("revision", 1) + 1
            self.put_record(record)
        return {"changed": changed, "thresholds": thresholds}

    # ---------- marks ----------
    def add_mark(self, start, note=""):
        """The phone retries a mark until it gets an answer, so the same moment arriving again is
        returned instead of stored twice."""
        if self.db.execute("SELECT 1 FROM marks WHERE start=? AND note=?", (start, note)).fetchone():
            return {"start": start, "note": note, "duplicate": True}
        with self.db:
            self.db.execute("INSERT INTO marks(start, note) VALUES(?,?)", (start, note))
        return {"start": start, "note": note}

    def marks(self, date, hour=None):
        rows = [{"id": r[0], "start": r[1], "note": r[2]} for r in
                self.db.execute("SELECT id, start, note FROM marks WHERE substr(start,1,10)=? ORDER BY start", (date,))]
        return [m for m in rows if hour is None or int(m["start"][11:13]) == hour]

    # ---------- hours ----------
    def touch_hour(self, date, hour):
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO hours VALUES(?,?,?,?,?,?)",
                            (date, hour, "pending", None, 0, iso(now_local())))
            self.db.execute("UPDATE hours SET state='pending' WHERE date=? AND hour=? AND state='done'",
                            (date, hour))

    def hour_states(self, date):
        return {r[0]: {"state": r[1], "error": r[2]} for r in
                self.db.execute("SELECT hour, state, error FROM hours WHERE date=?", (date,))}

    def due_hours(self):
        now = now_local()
        due = []
        for date, hour, attempts in self.db.execute(
                "SELECT date, hour, attempts FROM hours WHERE state IN ('pending','failed') AND attempts < 3"
                " ORDER BY date, hour"):
            end = datetime.fromisoformat(f"{date}T{hour:02d}:00:00").astimezone() + timedelta(hours=1)
            if end <= now:
                due.append((date, hour))
        return due

    def process_hour(self, date, hour):
        transcripts = self.records("transcript", date, hour)
        provider = self.provider()
        with self.db:  # claim the hour so the scheduler does not queue it again
            self.db.execute("UPDATE hours SET state='running' WHERE date=? AND hour=?", (date, hour))
        if not transcripts or provider is None:
            self._hour_state(date, hour, "skipped" if not transcripts else "pending", None)
            return {"skipped": True}
        settings = self.settings()
        if settings["pipeline"] == "auday":
            return self._process_hour_auday(date, hour, transcripts, provider, settings)
        errors, result = [], {}
        user_labels = ("user",)
        if settings["auto_hourly"]:
            try:
                summary, highlights, dropped = ai.hourly(provider, transcripts, self.marks(date, hour),
                                                         user_labels=user_labels, usage=self.usage)
                self._save_hour(date, hour, transcripts, summary, highlights)
                result.update(highlights=len(highlights), dropped=len(dropped))
            except Exception as error:  # model output unusable; keep transcripts, retry later
                errors.append(f"Hourly summary failed: {error}")
        if settings["auto_memory"]:
            engine = MemoryEngine(self.store, provider, user_labels=user_labels)
            report = engine.ingest_batch(transcripts)
            self.usage.calls += engine.usage.calls
            self.usage.input_tokens += engine.usage.input_tokens
            self.usage.output_tokens += engine.usage.output_tokens
            if report.error:
                errors.append(report.error)
            result["memory"] = [f"{d.operation} {d.memory_id}" for d in report.decisions]
        self._hour_state(date, hour, "failed" if errors else "done", "; ".join(errors) or None)
        return result

    def _auday_options(self, settings):
        return {"primary": settings["primary_language"] or "English",
                "secondary": settings["secondary_language"] or None}

    def _hour_inputs(self, date, hour, transcripts, settings):
        hour_start = datetime.fromisoformat(f"{date}T{hour:02d}:00:00").astimezone()
        ranges, marked, last_end, last_session = [], [], None, None
        for record in sorted(transcripts, key=lambda r: r["start"]):   # recorded seconds, from the audio assets
            asset = self.asset(record.get("audioAssetID", "")) if record.get("audioAssetID") else None
            begin = (datetime.fromisoformat(record["start"]) - hour_start).total_seconds()
            length = (asset or {}).get("duration") or max((s.get("end", 0) for s in record.get("segments", [])), default=0)
            ranges.append([max(0.0, begin), min(3600.0, begin + length)])
            # The watch names its sessions; otherwise a session is continuous audio, and a gap between
            # uploads (a call, a pause) starts a new one.
            session = (asset or {}).get("session")
            if session and last_session:
                new_session = session != last_session
            else:
                new_session = last_end is None or begin - last_end > SESSION_BREAK
            marked.append({**record, "newSession": new_session})
            last_end, last_session = begin + length, session
        snippets = auday_mode.snippets_from_transcripts(marked, settings["voice_labels"])
        scope = auday_mode.hour_scope(hour_start.isoformat(), self.time_zone(), sorted(ranges), snippets)
        marks = [{"date": m["start"], "note": m["note"]} for m in self.marks(date, hour)]
        fragments = []                     # Auday's health statistics follow its <=15 min audio fragments
        for a, b in sorted(ranges):
            if fragments and a - fragments[-1][1] <= SESSION_BREAK and b - fragments[-1][0] <= 900:
                fragments[-1][1] = b
            else:
                fragments.append([a, b])
        spans = [(hour_start + timedelta(seconds=a), hour_start + timedelta(seconds=b)) for a, b in fragments]
        body = self.body_for(hour_start, hour_start + timedelta(hours=1), spans)
        return snippets, scope, marks, body

    def _process_hour_auday(self, date, hour, transcripts, provider, settings):
        try:
            snippets, scope, marks, body = self._hour_inputs(date, hour, transcripts, settings)
            result = auday_mode.process_hour(provider, scope, snippets, profile=auday_mode.profile_from_store(self.store),
                                             marks=marks, mode=settings["voice_labels"], usage=self.usage,
                                             body=body, **self._auday_options(settings))
        except Exception as error:
            self._hour_state(date, hour, "failed", f"Auday-mode hour failed: {error}")
            return {"error": str(error)}
        tag = f"{date}T{hour:02d}"
        old = self.store.record(f"summary-{tag}")
        for record in self.records("highlight", date, hour):
            with self.db:
                self.db.execute("DELETE FROM records WHERE id=?", (record["id"],))
                self.db.execute("DELETE FROM chunks WHERE record_id=?", (record["id"],))
        summary = result["summary"]
        offset = transcripts[0]["start"][19:]
        self.put_record({"id": f"summary-{tag}", "kind": "summary", "title": summary["shortNote"],
                         "text": summary["summary"], "attentionPoints": summary["attentionPoints"],
                         "memoryPoints": summary["memoryPoints"], "informationDensity": summary["informationDensity"],
                         "start": f"{tag}:00:00{offset}", "timeZone": transcripts[0].get("timeZone"),
                         "status": "complete", "pipeline": "auday", "sourceIDs": [t["id"] for t in transcripts],
                         "revision": (old or {}).get("revision", 0) + 1})
        for n, item in enumerate(result["highlights"], 1):
            first, last = item["snippets"][0], item["snippets"][-1]
            self.put_record({"id": f"highlight-{tag}-{n}", "kind": "highlight", "title": item["title"],
                             "text": item.get("interpretation", ""), "reason": item["reason"],
                             "attentionPoints": item.get("attentionPoints", []), "start": first["date"],
                             "signals": auday_mode.signal_chips(item.get("signals", []))
                             + auday_mode.location_chips(body, first["date"], last["end"]),
                             "mayContinueBeyondScope": item.get("mayContinueBeyondScope", False),
                             "end": last["end"], "timeZone": transcripts[0].get("timeZone"), "status": "complete",
                             "pipeline": "auday", "sourceIDs": sorted({s["sourceID"] for s in item["snippets"]}),
                             "revision": 1})
        self._hour_state(date, hour, "done", None)
        return {"highlights": len(result["highlights"]), "memoryPoints": len(summary["memoryPoints"]),
                "informationDensity": summary["informationDensity"]}

    def process_day(self, now=None):
        """Auday's daily pass at the reflection time: overview, Reflection, memory review."""
        settings = self.settings()
        provider = self.provider()
        if provider is None:
            raise ValueError("Set up an AI service in Settings first.")
        start, end = auday_mode.day_window(settings["reflection_time"], now or now_local())
        summaries = [r for r in self.records("summary")
                     if r.get("pipeline") == "auday" and start <= datetime.fromisoformat(r["start"]) < end]
        highlights = [r for r in self.records("highlight")
                      if r.get("pipeline") == "auday" and start <= datetime.fromisoformat(r["start"]) < end]
        if not summaries:
            raise ValueError("This day has no hourly summaries in Auday mode yet.")
        hours = [{"hour": r["start"], "shortNote": r["title"], "summary": r["text"],
                  "memoryPoints": r.get("memoryPoints", [])} for r in summaries]
        covered = {datetime.fromisoformat(r["start"]).hour for r in summaries}
        missing = [h for h in range(24) if h not in covered]
        options, profile = self._auday_options(settings), auday_mode.profile_from_store(self.store)
        day_transcripts = [t for t in self.records("transcript")
                           if start <= datetime.fromisoformat(t["start"]) < end]
        snippets = auday_mode.snippets_from_transcripts(day_transcripts, settings["voice_labels"])
        for n, item in enumerate(snippets):           # day-wide source IDs, like Auday's session-snippet IDs
            item["snippetID"] = f"{item['sourceID']}-{n}"
        body = self.body_for(start, end)
        overview = auday_mode.daily_overview(provider, hours, highlights, missing, (start, end), profile=profile,
                                             usage=self.usage, snippets=snippets, body=body, **options)
        reflection = auday_mode.daily_reflection(provider, hours, highlights, missing, (start, end), overview,
                                                 profile=profile, usage=self.usage, snippets=snippets, body=body,
                                                 **options)
        selected, _ = auday_mode.daily_memory_review(provider, hours, overview["summary"], missing,
                                                     usage=self.usage, **options)
        by_hour = {r["start"]: [r["id"]] for r in summaries}
        added = auday_mode.add_review_candidates(self.store, selected, by_hour, iso(end), settings["voice_labels"])
        day = end.date().isoformat()
        record = {"id": f"reflection-{day}", "kind": "reflection", "title": overview["sentence"],
                  "text": reflection["reflection"], "summary": overview["summary"], "start": iso(end),
                  "windowStart": iso(start), "timeZone": self.time_zone(), "status": "complete", "pipeline": "auday",
                  "stats": {"recordedHours": len(summaries), "highlights": len(highlights), "memories": len(added)},
                  "missingHours": missing, "memories": [m.id for m in added],
                  "portrait": self._portrait(start, end, summaries, highlights, body),
                  "sourceIDs": [r["id"] for r in summaries], "updatedAt": iso(now_local()),
                  "revision": ((self.store.record(f"reflection-{day}") or {}).get("revision", 0) + 1)}
        self.put_record(record)
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO days VALUES(?,?,?)", (iso(end), "done", iso(now_local())))
        return {"reflection": record["id"], "memories": [m.id for m in added]}

    def _portrait(self, start, end, summaries, highlights, body):
        """Auday's Reflection 'portrait': one cell per hour of the window (summary, Highlights, marks,
        body states), plus a seed for the dithered cover artwork."""
        hours, at = [], start.replace(minute=0, second=0, microsecond=0)
        done = {datetime.fromisoformat(r["start"]).replace(minute=0): r for r in summaries}
        body_items = (body or {}).get("bodyContext", [])
        while at < end:
            nxt = at + timedelta(hours=1)
            inside = [b for b in body_items if b["start"] < nxt.isoformat() and b["end"] > at.isoformat()]
            hours.append({"hourStart": iso(at), "hasSummary": at in done,
                          "highlightCount": sum(1 for h in highlights if at <= datetime.fromisoformat(h["start"]) < nxt),
                          "markCount": len(self.marks(at.date().isoformat(), at.hour)),
                          "bodyContextKinds": sorted({b["kind"] for b in inside}),
                          "bodyContextLabels": sorted({b["label"] for b in inside})})
            at = nxt
        seed = int(hashlib.sha256(iso(end).encode()).hexdigest()[:15], 16)
        return {"hours": hours, "seed": seed, "artwork": {"style": "dither"}}

    def daily_due(self, now=None):
        """True once the reflection time has passed and that day has not been processed."""
        settings = self.settings()
        if settings["pipeline"] != "auday" or not settings["auto_daily"]:
            return False
        _, end = auday_mode.day_window(settings["reflection_time"], now or now_local())
        done = self.db.execute("SELECT 1 FROM days WHERE end_at=?", (iso(end),)).fetchone()
        has_hours = any(r.get("pipeline") == "auday" and datetime.fromisoformat(r["start"]) < end
                        and datetime.fromisoformat(r["start"]) >= end - timedelta(days=1)
                        for r in self.records("summary"))
        return not done and has_hours

    def notes(self, date, hour):
        """The hour exported in Auday's Notes layout."""
        tag = f"{date}T{hour:02d}"
        summary = self.store.record(f"summary-{tag}")
        if summary is None:
            raise KeyError(f"No summary for {tag}")
        transcripts = self.records("transcript", date, hour)
        snippets = auday_mode.snippets_from_transcripts(transcripts)
        highlights = []
        for record in self.records("highlight", date, hour):
            inside = [s for s in snippets if record["start"] <= s["date"] <= record.get("end", record["start"])]
            highlights.append({"title": record["title"], "reason": record.get("reason", ""),
                               "interpretation": record["text"], "attentionPoints": record.get("attentionPoints", []),
                               "snippets": inside or snippets[:1]})
        title = f"Auday Replica · {date} · {hour:02d}:00–{(hour + 1) % 24:02d}:00"
        return auday_mode.notes_markdown(title, {"summary": summary["text"],
                                                 "attentionPoints": summary.get("attentionPoints", [])},
                                         highlights, snippets, self.time_zone())

    def _hour_state(self, date, hour, state, error):
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO hours VALUES(?,?,?,?,?,?)",
                            (date, hour, state, error, 0, iso(now_local())))
            self.db.execute("UPDATE hours SET state=?, error=?, attempts=attempts+1, updated_at=? "
                            "WHERE date=? AND hour=?", (state, error, iso(now_local()), date, hour))

    def _save_hour(self, date, hour, transcripts, summary, highlights):
        tag = f"{date}T{hour:02d}"
        ids = [t["id"] for t in transcripts]
        old = self.store.record(f"summary-{tag}")
        for record in self.records("highlight", date, hour):
            with self.db:
                self.db.execute("DELETE FROM records WHERE id=?", (record["id"],))
                self.db.execute("DELETE FROM chunks WHERE record_id=?", (record["id"],))
        self.put_record({"id": f"summary-{tag}", "kind": "summary", "title": summary["title"],
                         "text": summary["text"], "start": f"{tag}:00:00{transcripts[0]['start'][19:]}",
                         "timeZone": transcripts[0].get("timeZone"), "status": "complete",
                         "sourceIDs": ids, "revision": (old or {}).get("revision", 0) + 1})
        by_id = {t["id"]: t for t in transcripts}
        for n, item in enumerate(highlights, 1):
            source = by_id[item["record_id"]]
            offset = next((s.get("start") for s in source.get("segments", [])
                           if ai.clean_quote(item["quote"])[:12] in ai.normalize(s["text"])), 0)
            record = {"id": f"highlight-{tag}-{n}", "kind": "highlight", "title": item["title"],
                      "text": item["quote"], "reason": item.get("reason"), "marked": bool(item.get("marked")),
                      "start": source["start"], "timeZone": source.get("timeZone"), "status": "complete",
                      "sourceIDs": [source["id"]], "revision": 1}
            if source.get("audioAssetID"):
                record.update(audioAssetID=source["audioAssetID"], audioOffset=offset or 0)
            self.put_record(record)

    def make_reflection(self, date):
        provider = self.provider()
        summaries = self.records("summary", date)
        if provider is None or not summaries:
            raise ValueError("The day needs hourly summaries and an AI service first.")
        output = ai.reflection(provider, summaries, self.records("highlight", date), usage=self.usage)
        old = self.store.record(f"reflection-{date}")
        record = {"id": f"reflection-{date}", "kind": "reflection", "title": output["title"],
                  "text": output["text"], "threads": output.get("threads", []), "quote": output.get("quote"),
                  "start": summaries[-1]["start"], "timeZone": summaries[0].get("timeZone"),
                  "status": "complete", "sourceIDs": [s["id"] for s in summaries],
                  "revision": (old or {}).get("revision", 0) + 1}
        self.put_record(record)
        return record

    # ---------- chat ----------
    def ask(self, question, history=(), conversation=None):
        """`conversation` groups questions like Auday's Conversations list; a new one starts when
        it is not given."""
        provider = self.provider()
        if provider is None:
            raise ValueError("Set up an AI service in Settings first.")
        settings = self.settings()
        if settings["pipeline"] == "auday":      # Auday's plan -> local tools -> answer -> verifier loop
            result = auday_chat.ask(self, provider, question, mode=settings["voice_labels"], history=history,
                                    usage=self.usage)
            cited = list(dict.fromkeys(c.split("#")[0] for c in result["cited"]))
            return self._save_chat(question, result["reply"], cited, conversation,
                                   {"claims": result["claims"], "insufficientEvidence": result["insufficientEvidence"],
                                    "rounds": result["rounds"]})
        today = now_local().date().isoformat()
        memories = retrieve(self.store, question, today=today, budget_tokens=500)
        date = self._date_hint(question)
        records = search.search(self.db, self.store.embedder, question, kinds=("transcript", "highlight", "summary"),
                                limit=8)
        if date:
            records = self.records("summary", date) + self.records("highlight", date) + records
        seen, unique = set(), []
        for item in records:
            record = item.get("record", item)
            if record["id"] not in seen:
                seen.add(record["id"])
                unique.append(record)
        answer, cited = ai.chat(provider, question, format_context(memories), unique[:14], history, usage=self.usage)
        conversation = conversation or f"c{now_local().strftime('%Y%m%d%H%M%S%f')}"
        with self.db:
            self.db.execute("INSERT INTO chats(ts, role, content, cited, conversation) VALUES(?,?,?,?,?)",
                            (iso(now_local()), "user", question, "[]", conversation))
            self.db.execute("INSERT INTO chats(ts, role, content, cited, conversation) VALUES(?,?,?,?,?)",
                            (iso(now_local()), "assistant", answer, json.dumps(cited), conversation))
        return {"answer": answer, "cited": cited, "conversation": conversation,
                "memories": [m.memory_id for m in memories], "records": [r["id"] for r in unique[:14]]}

    def _save_chat(self, question, answer, cited, conversation, extra):
        conversation = conversation or f"c{now_local().strftime('%Y%m%d%H%M%S%f')}"
        with self.db:
            self.db.execute("INSERT INTO chats(ts, role, content, cited, conversation) VALUES(?,?,?,?,?)",
                            (iso(now_local()), "user", question, "[]", conversation))
            self.db.execute("INSERT INTO chats(ts, role, content, cited, conversation) VALUES(?,?,?,?,?)",
                            (iso(now_local()), "assistant", answer, json.dumps(cited), conversation))
        return {"answer": answer, "cited": cited, "conversation": conversation, **extra}

    @staticmethod
    def _date_hint(question):
        today = now_local().date()
        if re.search(r"今天|today|今日", question, re.I):
            return today.isoformat()
        if re.search(r"昨天|yesterday|昨日", question, re.I):
            return (today - timedelta(days=1)).isoformat()
        found = re.search(r"(\d{4}-\d{2}-\d{2})", question)
        return found.group(1) if found else None

    # Chats from before conversations existed are grouped by day.
    _CONVERSATION = "COALESCE(conversation, 'day-' || substr(ts, 1, 10))"

    def chat_history(self, limit=60, conversation=None):
        where, args = (f" WHERE {self._CONVERSATION}=?", (conversation,)) if conversation else ("", ())
        rows = self.db.execute(f"SELECT ts, role, content, cited, {self._CONVERSATION} FROM chats{where}"
                               " ORDER BY id DESC LIMIT ?", (*args, limit))
        return [{"ts": r[0], "role": r[1], "content": r[2], "cited": json.loads(r[3]), "conversation": r[4]}
                for r in rows][::-1]

    def conversations(self):
        """Auday's Conversations sheet: each conversation's first question and when it was asked."""
        rows = self.db.execute(
            f"SELECT {self._CONVERSATION} AS c, MIN(id), MAX(ts), COUNT(*) FROM chats GROUP BY c ORDER BY MAX(ts) DESC, MAX(id) DESC")
        out = []
        for conversation, first, last, count in rows:
            question = self.db.execute(f"SELECT content, ts FROM chats WHERE {self._CONVERSATION}=? AND role='user'"
                                       " ORDER BY id LIMIT 1", (conversation,)).fetchone()
            out.append({"id": conversation, "question": question[0] if question else "", "ts": question[1] if question else last,
                        "updated": last, "messages": count})
        return out

    # ---------- memories ----------
    def memory_view(self, memory):
        return {"id": memory.id, "key": memory.key, "category": memory.category, "content": memory.content,
                "status": memory.status, "status_reason": memory.status_reason,
                "attribution": memory.attribution, "certainty": memory.certainty,
                "temporal": memory.temporal, "valid_until": memory.valid_until,
                "observed_at": memory.observed_at, "version": memory.version,
                "supersedes": memory.supersedes, "superseded_by": memory.superseded_by,
                "sourceIDs": memory.source_ids, "evidence": memory.evidence, "importance": memory.importance,
                "created_at": memory.created_at}

    def memories(self, statuses=None):
        """Each memory with the times Auday's memory screen shows: when it was first saved, when the
        user confirmed it, when it stopped being used, and whether the user edited it."""
        events = {}
        for event in self.store.events():
            if event["op"] == "STATUS":
                events.setdefault(event["memory_id"], []).append(event)
        out = []
        for memory in self.store.all(statuses):
            view = self.memory_view(memory)
            times = {}
            for event in events.get(memory.id, []):
                new = json.loads(event["payload"] or "{}").get("new")
                if new in ("confirmed", "saved"):
                    times.setdefault("savedAt", event["ts"])
                if new == "confirmed" and event["actor"] == "user":
                    times.setdefault("userConfirmedAt", event["ts"])
                if new in ("rejected", "inactive"):
                    times["inactivatedAt"] = event["ts"]
                elif new in ("confirmed", "saved"):
                    times.pop("inactivatedAt", None)
            view.update(times, edited=memory.version > 1)
            out.append(view)
        return out[::-1]

    def memory_action(self, memory_id, action, content=None):
        store = self.store
        if action == "edit":
            memory = store.edit(memory_id, content)
        else:
            memory = getattr(store, {"confirm": "confirm", "reject": "reject", "deactivate": "deactivate",
                                     "reactivate": "reactivate"}[action])(memory_id)
        with self.db:
            self.db.execute("UPDATE reviews SET state='resolved' WHERE memory_id=? AND state='open'", (memory_id,))
        return self.memory_view(memory)

    # ---------- day view / export ----------
    def day(self, date):
        hours = {}
        for record in self.records(date=date):
            if record["kind"] == "reflection":
                continue
            hour = int(record["start"][11:13])
            bucket = hours.setdefault(hour, {"hour": hour, "transcripts": [], "highlights": [], "summary": None})
            if record["kind"] == "summary":
                bucket["summary"] = record
            elif record["kind"] in ("transcript", "highlight"):
                bucket[record["kind"] + "s"].append(record)
        states = self.hour_states(date)
        for mark in self.marks(date):
            hour = int(mark["start"][11:13])
            hours.setdefault(hour, {"hour": hour, "transcripts": [], "highlights": [], "summary": None})
            hours[hour].setdefault("marks", []).append(mark)
        # Recorded time per hour, as on Auday's hour list ("50m", "4s"). An hour whose audio held
        # no speech has no transcript; Auday labels it QUIET.
        audio = {}
        for (body,) in self.db.execute("SELECT body FROM assets WHERE substr(json_extract(body, '$.start'), 1, 10)=?",
                                       (date,)):
            asset = json.loads(body)
            entry = audio.setdefault(int(asset["start"][11:13]), {"seconds": 0.0, "pending": 0, "silent": 0})
            entry["seconds"] += asset.get("duration") or 0
            entry["pending"] += asset.get("state") == "saved"
            entry["silent"] += asset.get("state") == "silent"
        for hour, entry in audio.items():
            hours.setdefault(hour, {"hour": hour, "transcripts": [], "highlights": [], "summary": None})
        for hour, bucket in hours.items():
            bucket.update(states.get(hour, {"state": None, "error": None}))
            bucket.setdefault("marks", [])
            entry = audio.get(hour, {"seconds": 0.0, "pending": 0, "silent": 0})
            unrecorded = sum(max((s.get("end") or s.get("start") or 0 for s in t.get("segments", [])), default=0)
                             for t in bucket["transcripts"] if not t.get("audioAssetID"))
            bucket["recordedSeconds"] = round(entry["seconds"] + unrecorded)
            bucket["pendingAudio"] = entry["pending"]
            bucket["quiet"] = not bucket["transcripts"] and not entry["pending"] and entry["silent"] > 0
        return {"date": date, "reflection": self.store.record(f"reflection-{date}"),
                "hours": [hours[h] for h in sorted(hours)]}

    def dates(self):
        rows = self.db.execute("SELECT DISTINCT date FROM records WHERE date != '' ORDER BY date DESC")
        return [r[0] for r in rows]

    def export_library(self):
        """The whole library in the Auday Skill's fixture format (its tests/make_fixture.py):
        schemaVersion, records (memories included) and audio assets."""
        records = [json.loads(r[0]) for r in self.db.execute("SELECT body FROM records")]
        for memory in self.store.all():
            records.append({"id": memory.id, "kind": "memory", "title": memory.key, "text": memory.content,
                            "start": memory.observed_at, "status": memory.status,
                            "sourceIDs": memory.source_ids, "revision": memory.version})
        assets = [json.loads(r[0]) for r in self.db.execute("SELECT body FROM assets")]
        return {"schemaVersion": 1, "sourceDeviceID": "auday-replica", "records": records, "assets": assets}

    # ---------- archive (Auday: Your archive) ----------
    def archive(self):
        """Days, audio stored and pending transcription, as on Auday's archive card."""
        audio = [json.loads(b) for (b,) in self.db.execute("SELECT body FROM assets").fetchall()]
        stored = sum((self.data / "audio" / a["path"]).stat().st_size for a in audio
                     if a.get("path") and (self.data / "audio" / a["path"]).exists())
        pending = [a for a in audio if a.get("state") == "saved" and a.get("path")]
        return {"days": len(self.dates()), "audioBytes": stored, "pendingAudio": len(pending),
                "pendingSeconds": round(sum(a.get("duration") or 0 for a in pending))}

    def transcribe_next(self, seconds=900):
        """Auday's Start transcription without automatic transcription: each tap transcribes the
        oldest pending audio, about 15 minutes of it."""
        pending = sorted((json.loads(b) for (b,) in self.db.execute("SELECT body FROM assets").fetchall()),
                         key=lambda a: a.get("start", ""))
        queued, total = [], 0.0
        for asset in pending:
            if asset.get("state") != "saved" or not asset.get("path"):
                continue
            if queued and total + (asset.get("duration") or 0) > seconds:
                break
            self.enqueue("transcribe", asset_id=asset["id"])
            queued.append(asset["id"])
            total += asset.get("duration") or 0
        return {"queued": len(queued), "seconds": round(total)}

    def batch_export(self, start_date, end_date):
        """A zip of each hour's Notes (Auday layout) and saved audio, named like Auday's exports."""
        buffer = io.BytesIO()
        offset = datetime.now().astimezone().strftime("%z")
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            for date in sorted(d for d in self.dates() if start_date <= d <= end_date):
                for hour in range(24):
                    a, b = f"{hour:02d}", f"{(hour + 1) % 24:02d}"
                    try:
                        archive.writestr(f"Auday_{date}_{a}00-{b}00_Notes.md", self.notes(date, hour))
                    except KeyError:
                        pass
                    audio = self.hour_audio(date, hour)
                    if audio:
                        archive.write(audio, f"Auday_{date}_{a}-00-00_to_{b}-00-00_UTC{offset}.wav")
        return buffer.getvalue()

    def status(self):
        counts = dict(self.db.execute("SELECT kind, COUNT(*) FROM records GROUP BY kind").fetchall())
        counts["memory"] = self.db.execute(
            "SELECT COUNT(*) FROM memories WHERE status IN ('saved','confirmed')").fetchone()[0]
        reviews = self.db.execute("SELECT COUNT(*) FROM reviews WHERE state='open'").fetchone()[0]
        return {"counts": counts, "openReviews": reviews, "queue": self.jobs.qsize(),
                "current": self.current, "activity": self.activity[-12:], "usage": self.usage.as_dict(),
                "provider": self.public_settings()["provider"], "pipeline": self.settings()["pipeline"],
                "voiceprint": (self.data / "voiceprint.npy").exists()}

    # ---------- background work ----------
    def enqueue(self, kind, **args):
        self.jobs.put((kind, args))

    def _log(self, text, ok=True):
        self.activity.append({"ts": iso(now_local())[11:19], "text": text, "ok": ok})
        del self.activity[:-50]

    def run_job(self, kind, args):
        self.current = f"{kind} {args}"
        try:
            if kind == "transcribe":
                record = self.run_transcribe(args["asset_id"])
                self._log(f"Transcribed {record['id']}" if record else f"No speech in {args['asset_id']}")
            elif kind == "hour":
                result = self.process_hour(args["date"], args["hour"])
                self._log(f"Processed hour {args['date']} {args['hour']:02d}:00: {result}")
            elif kind == "reflection":
                record = self.make_reflection(args["date"])
                self._log(f"Wrote reflection {record['id']}")
            elif kind == "daily":
                result = self.process_day()
                self._log(f"Daily review finished: {result}")
        except Exception as error:
            traceback.print_exc()
            self._log(f"{kind} failed: {error}", ok=False)
        finally:
            self.current = None

    def start_workers(self):
        def worker():
            while True:
                kind, args = self.jobs.get()
                self.run_job(kind, args)

        def scheduler():
            while True:
                try:
                    if self.provider() is not None:
                        queued = {(a.get("date"), a.get("hour")) for k, a in list(self.jobs.queue) if k == "hour"}
                        for date, hour in self.due_hours():
                            if (date, hour) not in queued:
                                self.enqueue("hour", date=date, hour=hour)
                        if self.daily_due() and not any(k == "daily" for k, _ in list(self.jobs.queue)):
                            self.enqueue("daily")
                    auday_mode.auto_save(self.store, datetime.now().astimezone())
                    self.prune_audio()
                except Exception:
                    traceback.print_exc()
                time.sleep(20)

        threading.Thread(target=worker, daemon=True, name="worker").start()
        threading.Thread(target=scheduler, daemon=True, name="scheduler").start()
