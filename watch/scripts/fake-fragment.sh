#!/bin/sh
# Sends one synthetic watch fragment (a 5-second tone, AAC mono 48 kHz ~32 kbps) to a running
# replica with the iPhone's upload request. It sends CAF, the format of older watch builds, which
# the server still accepts. Usage:
#   watch/scripts/fake-fragment.sh [http://127.0.0.1:8765] [token]
set -e
SERVER=${1:-http://127.0.0.1:8765}
TOKEN=$2
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
python3 - "$DIR/tone.wav" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
    w.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(i * 2 * math.pi * 440 / 48000))) for i in range(48000 * 5)))
PY
afconvert -f caff -d aac -b 32000 -c 1 "$DIR/tone.wav" "$DIR/tone.caf"
START=$(date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/' | sed 's/+/%2B/')
FRAGMENT=$(uuidgen)
curl -sS --fail-with-body -X POST -H "Content-Type: audio/x-caf" ${TOKEN:+-H "Authorization: Bearer $TOKEN"} \
  --data-binary @"$DIR/tone.caf" \
  "$SERVER/api/audio?start=$START&ext=caf&session=fake-session&fragment=$FRAGMENT"
echo
