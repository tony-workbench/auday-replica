#!/usr/bin/env bash
# Start the app. If you use a local model, start it separately first, e.g. with MLX:
#   mlx_lm.server --model <model-dir> --host 127.0.0.1 --port 8089
set -euo pipefail
cd "$(dirname "$0")/.."
exec .venv/bin/python -m app.server --data "${AUDAY_DATA:-data}" --port "${PORT:-8765}" "$@"
