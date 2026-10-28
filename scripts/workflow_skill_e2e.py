"""End-to-end check of "Connect to your workflow" against the real, installed Auday Skill.

Builds a synthetic replica library (macOS `say` speech, made-up text) in a temporary folder, turns
the link on with a throwaway communication password, and drives the Skill's own CLI against it:
discover → pair (password typed into the Skill's hidden prompt through a pseudo-terminal) → status
--live → sync → search → assets → audio, in both read-only scopes.

The Skill runs under a throwaway profile (`--profile replica-e2e-<random>`), so the user's real phone
pairing is untouched. The throwaway password exists only in the temporary replica settings and in
that profile's Keychain item; both are deleted at the end. Nothing secret is printed.

  .venv/bin/python scripts/workflow_skill_e2e.py [--skill ~/.claude/skills/auday] [--keep]
"""

import argparse
import hashlib
import json
import os
import pty
import secrets
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app import workflow_server as ws  # noqa: E402
from app.core import App  # noqa: E402

SKILL_HOME = Path.home() / "Library" / "Application Support" / "AudayWorkflow"
KEYCHAIN_SERVICE = "ai.auday.workflow-link.experimental"


def synthetic_library(folder):
    app = App(folder)
    app.update_settings({"auto_transcribe": False, "auto_hourly": False, "auto_daily": False,
                         "auto_memory": False, "pipeline": "auday", "time_zone": "America/Los_Angeles"})
    lines = [("2026-10-20T09:05:00-07:00", "Synthetic standup: the launch checklist needs one more review."),
             ("2026-10-20T09:20:00-07:00", "合成测试：周五之前把发布清单发给设计组。")]
    for start, text in lines:
        aiff, wav = folder / "say.aiff", folder / "say.wav"
        subprocess.run(["say", "-o", str(aiff), "Synthetic test recording for the workflow link."], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)],
                       check=True, capture_output=True)
        asset = app.save_audio(wav.read_bytes(), start, suffix=".wav", session="e2e-session")
        app.add_transcript(start, [{"text": text, "start": 0, "end": asset["duration"]}], audio_id=asset["id"])
    app.put_record({"id": "summary-e2e", "kind": "summary", "pipeline": "auday", "start": "2026-10-20T09:00:00-07:00",
                    "title": "Launch checklist review", "text": "The team reviewed the synthetic launch checklist.",
                    "sourceIDs": [], "updated_at": "2026-10-20T10:00:00-07:00"})
    app.put_record({"id": "highlight-e2e", "kind": "highlight", "pipeline": "auday", "start": "2026-10-20T09:05:00-07:00",
                    "end": "2026-10-20T09:06:00-07:00", "title": "Checklist owner", "text": "One more review is needed.",
                    "sourceIDs": [], "updated_at": "2026-10-20T10:00:00-07:00"})
    # A record over the inline limit, so the transfer exercises chunked records.
    app.add_transcript("2026-10-20T11:00:00-07:00", [{"text": "长文本" * 120_000, "start": 0, "end": 1}])
    return app


def skill(skill_root, profile, *args, timeout=300):
    process = subprocess.run(["/bin/sh", str(skill_root / "scripts" / "bootstrap.sh"), "--profile", profile, *args],
                             capture_output=True, text=True, timeout=timeout)
    lines = [line for line in process.stdout.splitlines() if line.strip()]
    try:
        return json.loads(lines[-1]) if lines else {"ok": False, "error": process.stderr[-300:]}
    except ValueError:
        return {"ok": False, "error": "unparsed output"}


def pair(skill_root, profile, password, service):
    """Type the password into the Skill's own hidden prompt (getpass on /dev/tty) via a pty."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execv("/bin/sh", ["/bin/sh", str(skill_root / "scripts" / "bootstrap.sh"), "--profile", profile,
                             "pair", "--service", service])
    output, sent, deadline = b"", False, time.monotonic() + 300
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 1)
        if ready:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            output += data
            if not sent and "通信密码".encode() in output:
                os.write(fd, password.encode() + b"\n")
                sent = True
        elif os.waitpid(pid, os.WNOHANG)[0]:
            break
    _, code = os.waitpid(pid, 0)
    os.close(fd)
    text = output.decode(errors="replace")
    result = next((json.loads(line) for line in reversed(text.splitlines()) if line.strip().startswith("{")), {})
    return code == 0 and result.get("ok") is True, result


def check(label, condition, detail=""):
    print(f"{'PASS' if condition else 'FAIL'}  {label}{('  — ' + detail) if detail else ''}", flush=True)
    return bool(condition)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skill", type=Path, default=Path.home() / ".claude" / "skills" / "auday")
    parser.add_argument("--keep", action="store_true", help="keep the temporary replica data and Skill profile")
    args = parser.parse_args()
    skill_root = args.skill.expanduser()
    folder = Path(tempfile.mkdtemp(prefix="auday-e2e-"))
    profile = "replica-e2e-" + secrets.token_hex(4)
    keychain_account = "profile-" + hashlib.sha256(str((SKILL_HOME / profile).resolve()).encode()).hexdigest()[:32]
    ok, link = True, None
    try:
        app = synthetic_library(folder / "data")
        password = ws.generate_password()           # throwaway; kept only in this temporary replica's settings
        app.update_settings({"workflow_password": password, "workflow_access": "text"})
        name = "Auday Replica e2e " + secrets.token_hex(2)
        link = ws.WorkflowLink(ws.AppLibrary(app), password, "text", name,
                               cache_dir=folder / "data" / "cache" / "workflow-audio").start()
        print(f"link on, port {link.port}, service {name!r}", flush=True)
        time.sleep(1.5)

        found = skill(skill_root, profile, "discover")
        ok &= check("discover finds the replica over Bonjour", name in found.get("services", []),
                    f"{len(found.get('services', []))} service(s)")
        paired, result = pair(skill_root, profile, password, name)
        ok &= check("pair through the Skill's hidden prompt", paired, result.get("error", ""))
        live = skill(skill_root, profile, "status", "--live").get("phone", {})
        ok &= check("status --live", live.get("ok") and live.get("access") == "text-only-read-only",
                    f"state={live.get('snapshotState')} tls={live.get('transport')}")

        synced = skill(skill_root, profile, "sync")
        ok &= check("sync, text only", synced.get("recordCount", 0) >= 5 and synced.get("assetCount") == 0,
                    f"records={synced.get('recordCount')} assets={synced.get('assetCount')} current={synced.get('sourceSnapshotCurrent')}")
        again = skill(skill_root, profile, "sync")
        ok &= check("second sync reuses the unchanged snapshot", again.get("changedRecords") == 0
                    and again.get("snapshot") == synced.get("snapshot"))
        found = skill(skill_root, profile, "search", "launch checklist", "--limit", "5")
        ok &= check("search", len(found.get("records", [])) >= 1, f"{len(found.get('records', []))} hit(s)")
        long = skill(skill_root, profile, "search", "长文本长文本", "--limit", "1")
        ok &= check("chunked large record arrived whole",
                    long.get("records") and len(long["records"][0]["text"]) == 3 * 120_000)
        memo = skill(skill_root, profile, "search", "--kind", "summary", "--limit", "10")
        ok &= check("summary records (saved + saved-overview)",
                    {r.get("state") for r in memo.get("records", [])} >= {"saved", "saved-overview"})

        link.service.set_access("text-and-audio")
        synced = skill(skill_root, profile, "sync")
        ok &= check("sync, text and audio", synced.get("assetCount") == 2, f"assets={synced.get('assetCount')}")
        catalog = skill(skill_root, profile, "assets", "--limit", "10").get("assets", [])
        ok &= check("audio catalogue shape", catalog and set(catalog[0]) >= {
            "id", "contentRevision", "duration", "fragmentID", "regionID", "sessionID", "start", "timeZone"})
        if catalog:
            audio = skill(skill_root, profile, "audio", catalog[0]["id"])
            path = Path(audio.get("path", "/nonexistent"))
            ok &= check("on-demand audio downloaded and verified", path.is_file() and path.read_bytes()[:4] == b"caff",
                        f"{audio.get('asset', {}).get('mime')} {audio.get('asset', {}).get('size')} bytes")
            transcript = skill(skill_root, profile, "search", "launch checklist", "--kind", "transcript", "--limit", "1")
            refs = transcript.get("records", [{}])[0].get("audioAssetIDs", [])
            ok &= check("transcripts point at catalogue audio", bool(refs) and refs[0] in {a["id"] for a in catalog})

        link.service.set_access("text")
        synced = skill(skill_root, profile, "sync")
        ok &= check("back to text only: audio requests refused", synced.get("assetCount") == 0)
        if catalog:
            denied = skill(skill_root, profile, "audio", catalog[-1]["id"])
            ok &= check("audio_access_denied in text scope", "audio_access_denied" in str(denied.get("error", "")))
    finally:
        if link:
            link.stop()
        subprocess.run(["security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", keychain_account],
                       capture_output=True)
        if not args.keep:
            shutil.rmtree(folder, ignore_errors=True)
            shutil.rmtree(SKILL_HOME / profile, ignore_errors=True)
    print("ALL PASSED" if ok else "SOME CHECKS FAILED", flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
