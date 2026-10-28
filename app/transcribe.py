"""On-device transcription: ffmpeg (or afconvert) -> 16 kHz mono WAV -> SenseVoice or Whisper.

Auday transcribes on the iPhone. Its synced transcripts carry SenseVoice's emotion and audio-event
tags (<|NEUTRAL|>, <|Speech|>, <|BGM|> ...), so the default here is SenseVoice Small (int8, run by
sherpa-onnx), which returns the same tags. faster-whisper is the alternative. Nothing leaves the machine.
"""

import hashlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import threading
import wave
from pathlib import Path

import numpy as np

from memengine import net

_lock = threading.Lock()
_models = {}


def ffmpeg_path():
    """ffmpeg on PATH, else the binary shipped with the imageio-ffmpeg package (requirements.txt)."""
    found = shutil.which("ffmpeg")
    if found:
        return found
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except (ImportError, RuntimeError):
        return None


class Undecodable(Exception):
    """The audio itself cannot be read (for example a CAF the recorder never closed): sending it
    again will not help, so the server answers 422 and the phone stops retrying."""


def to_wav(source, target):
    """Any audio/video -> 16 kHz mono WAV; returns duration in seconds. ffmpeg if available,
    otherwise macOS's built-in afconvert."""
    ffmpeg = ffmpeg_path()
    if ffmpeg:
        command = [ffmpeg, "-nostdin", "-y", "-loglevel", "error", "-i", str(source),
                   "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(target)]
    elif shutil.which("afconvert"):
        command = ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(source), str(target)]
    else:
        raise RuntimeError("Reading audio needs ffmpeg (or macOS afconvert).")
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        Path(target).unlink(missing_ok=True)
        reason = (result.stderr.strip().splitlines() or ["unreadable audio"])[-1]
        raise Undecodable(reason)
    with wave.open(str(target), "rb") as handle:
        return handle.getnframes() / handle.getframerate()


# Auday's FAQ: intervals it confidently identifies as extremely quiet keep their place in the
# timeline but no stored sound (they play back as silence); uncertain stretches and the moments
# around Marks are kept. Its audio metadata carries the mapping as `timeline`.
QUIET_RMS = 0.001          # about -60 dBFS
QUIET_MIN = 4.0            # seconds of continuous quiet before anything is dropped
QUIET_MARGIN = 0.5         # seconds kept on each side of a dropped stretch


def quiet_spans(audio, protect=()):
    """[(start_s, end_s)] of droppable quiet, outside the protected [(start_s, end_s)] ranges."""
    hop = SR // 10
    quiet, spans, run = [], [], None
    for i in range(0, len(audio) - hop + 1, hop):
        quiet.append(float(np.sqrt(np.mean(audio[i:i + hop] ** 2))) < QUIET_RMS)
    for n, q in enumerate(quiet + [False]):
        if q and run is None:
            run = n
        elif not q and run is not None:
            a, b = run / 10 + QUIET_MARGIN, n / 10 - QUIET_MARGIN
            if n / 10 - run / 10 >= QUIET_MIN and b > a:
                spans.append((a, b))
            run = None
    out = []
    for a, b in spans:                       # cut protected ranges out of each span
        pieces = [(a, b)]
        for pa, pb in protect:
            pieces = [p for x, y in pieces for p in ((x, min(y, pa)), (max(x, pb), y)) if p[1] - p[0] >= QUIET_MIN / 2]
        out += pieces
    return out


def compact(path, protect=()):
    """Drop quiet stretches from a 16 kHz WAV in place. Returns the timeline
    [{"fileStart", "fileEnd", "recordedOffset"}] (seconds) or None when nothing was dropped."""
    audio = read_wav(path)
    spans = quiet_spans(audio, protect)
    if not spans:
        return None
    keep, timeline, cursor, file_pos = [], [], 0.0, 0.0
    for a, b in spans + [(len(audio) / SR, None)]:
        if a > cursor:
            keep.append(audio[int(cursor * SR):int(a * SR)])
            timeline.append({"fileStart": round(file_pos, 3), "fileEnd": round(file_pos + a - cursor, 3),
                             "recordedOffset": round(cursor, 3)})
            file_pos += a - cursor
        cursor = b if b is not None else cursor
    joined = np.concatenate(keep) if keep else np.zeros(0, dtype=np.float32)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1); out.setsampwidth(2); out.setframerate(SR)
        out.writeframes((np.clip(joined, -1, 1) * 32767).astype(np.int16).tobytes())
    return timeline


def recorded_time(timeline, t):
    """File seconds -> seconds since the recording started, through a compact() timeline."""
    if not timeline:
        return t
    for piece in timeline:
        if t <= piece["fileEnd"] + 1e-6:
            return piece["recordedOffset"] + max(0.0, t - piece["fileStart"])
    last = timeline[-1]
    return last["recordedOffset"] + (t - last["fileStart"])


def file_time(timeline, t):
    """Seconds since the recording started -> seconds in the stored (compacted) file."""
    if not timeline:
        return t
    for piece in timeline:
        length = piece["fileEnd"] - piece["fileStart"]
        if t <= piece["recordedOffset"] + length + 1e-6:
            return piece["fileStart"] + max(0.0, t - piece["recordedOffset"])
    return timeline[-1]["fileEnd"]


def read_wav(path):
    """16 kHz mono PCM WAV -> float32 array (avoids PyAV version issues)."""
    with wave.open(str(path), "rb") as handle:
        frames = handle.readframes(handle.getnframes())
    return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0


def model(name, download_root):
    with _lock:
        if name not in _models:
            from faster_whisper import WhisperModel
            _models[name] = WhisperModel(name, device="cpu", compute_type="int8",
                                         download_root=str(download_root))
        return _models[name]


SENSEVOICE = "sensevoice"
SENSEVOICE_NAME = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
SENSEVOICE_URL = f"https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{SENSEVOICE_NAME}.tar.bz2"
SENSEVOICE_SHA256 = "7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e"


def sensevoice_dir(download_root):
    """Download (once) and verify the SenseVoice model; returns its directory."""
    root = Path(download_root)
    target = root / SENSEVOICE_NAME
    if (target / "model.int8.onnx").exists():
        return target
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=root) as tmp:
        archive = Path(tmp) / "model.tar.bz2"
        net.download(SENSEVOICE_URL, archive)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != SENSEVOICE_SHA256:
            raise RuntimeError(f"The downloaded SenseVoice model failed its checksum (got {digest}).")
        with tarfile.open(archive) as tar:
            tar.extractall(tmp, filter="data")
        Path(tmp, SENSEVOICE_NAME).rename(target)
    return target


# Auday's Local efficient mode lists exactly SenseVoice's languages; so does the replica.
LANGUAGES = {"zh": "Mandarin", "yue": "Cantonese", "en": "English", "ja": "Japanese", "ko": "Korean"}


def sensevoice(download_root, language=None):
    language = language if language in LANGUAGES else "auto"
    with _lock:
        key = (SENSEVOICE, language)
        if key not in _models:
            import sherpa_onnx
            folder = sensevoice_dir(download_root)
            _models[key] = sherpa_onnx.OfflineRecognizer.from_sense_voice(
                model=str(folder / "model.int8.onnx"), tokens=str(folder / "tokens.txt"), use_itn=True,
                language=language, num_threads=4)
        return _models[key]


# Like Auday, transcribe short snippets (1-15 s) on their own: VAD finds speech, nearby pieces
# are merged up to MAX_SNIPPET, and every snippet is
# decoded on its own. Decoding several VAD pieces inside one 30 s Whisper window loses quiet
# speech that sits next to louder speech.
VAD = {"threshold": 0.35, "min_silence_duration_ms": 500, "speech_pad_ms": 200}
MAX_SNIPPET = 15.0   # seconds
VAD_WINDOW = 30      # seconds; Silero run over a whole hour adapts to steady noise and misses quiet speech
# Phrases Whisper invents on noise (video-subtitle credits it saw in training).
HALLUCINATIONS = ("请不吝点赞", "订阅 转发", "打赏支持", "明镜与点点", "字幕由", "谢谢观看", "Thanks for watching")
MERGE_GAP = 2.0      # pauses between read-aloud sentences are 1-2.5 s; Auday joins across them
SR = 16000


def snippets(audio):
    """VAD speech pieces -> [(start_sample, end_sample)] of at most MAX_SNIPPET seconds."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps
    pieces, step = [], VAD_WINDOW * SR
    for offset in range(0, len(audio), step):
        pieces += [(p["start"] + offset, p["end"] + offset)
                   for p in get_speech_timestamps(audio[offset:offset + step], VadOptions(**VAD))]
    out = []
    for start, end in pieces:
        while end - start > MAX_SNIPPET * SR:          # split overly long speech
            out.append([start, start + int(MAX_SNIPPET * SR)])
            start += int(MAX_SNIPPET * SR)
        if out and start - out[-1][1] <= MERGE_GAP * SR and end - out[-1][0] <= MAX_SNIPPET * SR:
            out[-1][1] = end
        else:
            out.append([start, end])
    return out


def _echoes(text, prompt):
    """True when `text` mostly reuses the prompt's characters: on short or unclear audio Whisper
    repeats a paraphrase of its prompt."""
    chars = {c for c in text if c.isalnum()}
    return len(chars) >= 4 and len(chars & set(prompt)) / len(chars) >= 0.5


def _clean(segments, prompt):
    """Whisper hallucination guards: silence-like low-confidence output, echoed prompt, loops."""
    lines = []
    for s in segments:
        text = s.text.strip()
        if not text or (s.no_speech_prob > 0.6 and s.avg_logprob < -1.0) or s.compression_ratio > 2.4:
            continue
        if (prompt and _echoes(text, prompt)) or any(h in text for h in HALLUCINATIONS):
            continue
        if lines and text == lines[-1]:
            continue
        lines.append(text)
    return "".join(lines) if prompt else " ".join(lines)


def transcribe(wav_path, *, model_name=SENSEVOICE, download_root, language=None):
    """Returns (language, [{"start": s, "end": s, "text": str}]), one entry per snippet. SenseVoice
    entries also carry "emotion" and "event", the tags Auday stores on each snippet."""
    if model_name == SENSEVOICE:
        return _transcribe_sensevoice(wav_path, download_root, language)
    whisper = model(model_name, download_root)
    prompt = "以下是普通话的句子，使用简体中文。" if language == "zh" else None
    audio = read_wav(wav_path)
    out, languages = [], {}
    for start, end in snippets(audio):
        segments, info = whisper.transcribe(audio[start:end], language=language or None, vad_filter=False,
                                            beam_size=5, initial_prompt=prompt,
                                            condition_on_previous_text=False, without_timestamps=True)
        text = _clean(list(segments), prompt)
        if text:
            out.append({"start": round(start / SR, 2), "end": round(end / SR, 2), "text": text})
            languages[info.language] = languages.get(info.language, 0) + 1
    return (max(languages, key=languages.get) if languages else (language or "unknown")), out


# SenseVoice path. Auday cuts long speech into 15 s snippets without regard to words; cutting the
# audio there drops the word under the cut. So each speech region is decoded whole (in parts of at
# most DECODE_MAX s) and its tokens are split into <=15 s snippets at word boundaries, using the
# token timestamps. The VAD settings below matched Auday's snippet boundaries best on a captured hour.
SV_VAD = {"threshold": 0.35, "min_silence_duration_ms": 1000, "speech_pad_ms": 400}
SV_MERGE_GAP = 3.0
DECODE_MAX = 30.0


def regions(audio, vad=SV_VAD, gap=SV_MERGE_GAP):
    """Speech regions to decode together, each a list of Auday-like snippet spans.

    VAD pieces are merged like Auday's snippets (joined while the result stays within MAX_SNIPPET).
    Silero runs in VAD_WINDOW windows, so speech crossing a window edge comes out as two pieces cut
    mid-word; such neighbours share one region: decoded together, then split near the edge on a
    word boundary. Returns [[(start, end), ...], ...] in samples."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps
    pieces, step = [], VAD_WINDOW * SR
    for offset in range(0, len(audio), step):
        pieces += [(p["start"] + offset, p["end"] + offset)
                   for p in get_speech_timestamps(audio[offset:offset + step], VadOptions(**vad))]
    spans = []
    for start, end in pieces:
        if spans and start - spans[-1][1] <= gap * SR and end - spans[-1][0] <= MAX_SNIPPET * SR:
            spans[-1][1] = end
        else:
            spans.append([start, end])
    out = []
    for span in spans:
        touching = out and span[0] - out[-1][-1][1] <= 0.05 * SR and span[0] % step < 0.05 * SR
        if touching:
            out[-1].append(tuple(span))
        else:
            out.append([tuple(span)])
    return out


def _word_start(token):
    """A cut may go before this token: English words start with a space; CJK characters stand alone."""
    return token[:1] in (" ", "▁") or not token[:1].isascii()


def _join(tokens):
    return "".join(tokens).replace("▁", " ").strip()


def _quiet_point(audio, lo, hi):
    """Sample index of the quietest 100 ms between lo and hi (samples)."""
    hop = SR // 10
    seg = audio[lo:hi]
    if len(seg) <= hop:
        return hi
    rms = [float(np.sqrt(np.mean(seg[i:i + hop] ** 2))) for i in range(0, len(seg) - hop, hop // 2)]
    return lo + int(np.argmin(rms)) * (hop // 2) + hop // 2


def _decode(recognizer, audio):
    stream = recognizer.create_stream()
    stream.accept_waveform(SR, audio)
    recognizer.decode_stream(stream)
    return stream.result


_WORDS = None


def _is_word(word):
    """English dictionary check (the system word list on macOS); without one, nothing is repaired."""
    global _WORDS
    if _WORDS is None:
        try:
            _WORDS = {w.strip().lower() for w in open("/usr/share/dict/words", encoding="utf-8")}
        except OSError:
            _WORDS = set()
    return word in _WORDS


def unstutter(text, is_word=_is_word):
    """Repairs an English word the model decoded with a piece twice ("transranscription",
    "transscription" for "transcription"), as watch/AudayKit Stutter does on the iPhone. A word is
    changed only when it is not in the dictionary and dropping one piece that repeats the piece
    before it gives a dictionary word."""
    def repair(match):
        word = match.group(0)
        lower = word.lower()
        if is_word(lower):
            return word
        for n in range(1, 7):
            for i in range(n, len(lower) - n + 1):
                if 2 * n < len(lower) and lower[i - n:i] == lower[i:i + n] and is_word(lower[:i] + lower[i + n:]):
                    fixed = lower[:i] + lower[i + n:]
                    return fixed[:1].upper() + fixed[1:] if word[:1].isupper() else fixed
        return word
    return re.sub(r"[A-Za-z]{5,}", repair, text)


def _transcribe_sensevoice(wav_path, download_root, language=None):
    recognizer = sensevoice(download_root, language)
    audio = read_wav(wav_path)
    out, languages = [], {}
    for spans in regions(audio):
        start, end = spans[0][0], spans[-1][1]
        if len(spans) == 1 and end - start <= MAX_SNIPPET * SR:      # the common case: one snippet
            result = _decode(recognizer, audio[start:end])
            pieces = [(start / SR, end / SR, result.text.strip())]
        else:
            result, pieces = _decode_region(recognizer, audio, spans)
        for s0, s1, text in pieces:
            if text and not all(ch in "。，,.?？!！ " for ch in text):
                out.append({"start": round(s0, 2), "end": round(s1, 2), "text": unstutter(text),
                            "emotion": result.emotion, "event": result.event})
        lang = result.lang.strip("<|>")
        languages[lang] = languages.get(lang, 0) + 1
    return (max(languages, key=languages.get) if languages else "unknown"), out


def _decode_region(recognizer, audio, spans):
    """Decode a region whole (parts of at most DECODE_MAX s, cut at quiet moments), then cut its
    tokens into snippets: near each span edge and every MAX_SNIPPET s, always before a word."""
    start, end = spans[0][0], spans[-1][1]
    tokens, times, first, a = [], [], None, start
    while a < end:
        b = end if end - a <= DECODE_MAX * SR else _quiet_point(audio, a + int((DECODE_MAX - 5) * SR),
                                                                a + int(DECODE_MAX * SR))
        result = _decode(recognizer, audio[a:b])
        first = first or result
        tokens += list(result.tokens)
        times += [a / SR + t for t in result.timestamps]
        a = b
    starts = [i for i in range(1, len(tokens)) if _word_start(tokens[i])]
    cuts = set()
    for edge in (s[0] / SR for s in spans[1:]):                     # word start nearest each span edge
        if starts:
            cuts.add(min(starts, key=lambda i: abs(times[i] - edge)))
    pieces, edges = [], [0] + sorted(cuts) + [len(tokens)]
    for i, j in zip(edges, edges[1:]):                               # then at most 15 s per snippet
        limit, k = (times[i] if i < len(times) else 0) + MAX_SNIPPET, i
        for m in range(i + 1, j):
            if times[m] >= limit and (_word_start(tokens[m]) or times[m] >= limit + 3):
                pieces.append((k, m))
                k, limit = m, times[m] + MAX_SNIPPET
        pieces.append((k, j))
    out = []
    for n, (i, j) in enumerate(pieces):
        if i >= j:
            continue
        s0 = start / SR if i == 0 else times[i]
        s1 = end / SR if j == len(tokens) else times[j]
        out.append((s0, s1, _join(tokens[i:j])))
    return first, out
