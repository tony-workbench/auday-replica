#!/usr/bin/env bash
# Create the app's private environment and download the SenseVoice model (WHISPER_MODEL=small for Whisper).
set -euo pipefail
cd "$(dirname "$0")/.."
# Python 3.12 or newer. macOS's own python3 (Command Line Tools) is 3.9, so prefer python3.12.
PYTHON=${PYTHON:-$(command -v python3.12 || command -v python3 || true)}
if [ -z "$PYTHON" ] || ! "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 12))'; then
  echo "Python 3.12 is required. Install it from https://www.python.org/downloads/ and run this again." >&2
  exit 1
fi
"$PYTHON" -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt
PYTHONPATH=. .venv/bin/python - <<'PY'
import os
from pathlib import Path
root = Path(os.environ.get("AUDAY_MODELS", Path.home() / ".cache" / "auday-replica" / "models"))
if os.environ.get("WHISPER_MODEL"):
    from faster_whisper import WhisperModel
    WhisperModel(os.environ["WHISPER_MODEL"], device="cpu", compute_type="int8", download_root=str(root))
else:
    from app.transcribe import sensevoice_dir
    sensevoice_dir(root)
print("Transcription model ready in", root)
PY
# ffmpeg comes with the imageio-ffmpeg package in requirements.txt; a system ffmpeg is used if present.
