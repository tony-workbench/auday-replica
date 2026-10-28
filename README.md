# Auday Replica

A rebuild of [Auday – All-Day Watch Recorder](https://auday.ai/) from public information: a Mac web app that records all day, transcribes locally, summarizes each hour and keeps a long-term memory, with optional Apple Watch and iPhone apps. Unofficial; not affiliated with Auday and contains none of its code.

## What you need

- **A Mac with Apple Silicon** (M1 or newer) and at least 8 GB of memory.
- **Python 3.12**: download the macOS installer for 3.12 from [python.org](https://www.python.org/downloads/) and install it; `python3.12 --version` should print `Python 3.12.x`. The macOS `python3` (3.9) will not work.
- **Git**: run `xcode-select --install` (skip if already installed).
- About 6 GB of free disk space and an internet connection during setup.

You do not need Homebrew or a separate ffmpeg.

## Install

1. Download the code and go into its folder:

   ```bash
   git clone https://github.com/tony-workbench/auday-replica.git
   cd auday-replica
   ```

2. Install the dependencies and the transcription model (a few minutes). It worked when the last line starts with `Transcription model ready in`:

   ```bash
   ./scripts/setup.sh
   ```

3. Install the local AI model server (MLX) and download a model of about 1.7 GB:

   ```bash
   .venv/bin/pip install mlx-lm==0.32.2
   .venv/bin/hf download mlx-community/SmolLM3-3B-4bit
   ```

## Use

Use two Terminal windows, both in the `auday-replica` folder.

1. In the first window, start the local AI model. Wait for `Starting httpd at 127.0.0.1 on port 8089` and leave the window open:

   ```bash
   .venv/bin/mlx_lm.server --model mlx-community/SmolLM3-3B-4bit --port 8089
   ```

2. In the second window, start the app. Wait for `Auday Replica on http://127.0.0.1:8765` and leave the window open:

   ```bash
   ./scripts/start.sh
   ```

3. Open <http://127.0.0.1:8765>. Click the watch icon at the top right, then "Tap to start" to record with the Mac's microphone, and allow microphone access. To stop, hold the mouse down on the watch face for 1 second.

4. (Optional) Create two days of demo data. In a third window, run the command below (3 to 10 minutes), then reload the page:

   ```bash
   .venv/bin/python scripts/demo_day.py
   ```

To stop, press `Ctrl+C` in both windows. Data is stored in `auday-replica/data/`.

To use another AI model: in the web page open "…" › Settings › AI service, change "Address" and "Model", and click "Check Connection & Save". For example, with [Ollama](https://ollama.com/) set Address to `http://127.0.0.1:11434/v1` and Model to the name of a model you downloaded with `ollama pull`. For OpenAI, set Address to `https://api.openai.com/v1` and enter your API key. For Anthropic or Gemini, choose it under "Service" and enter your API key.

To record with an Apple Watch, see [watch/README.md](watch/README.md).

## Test

In the `auday-replica` folder; neither needs the app or AI model running. The first passes when its last line is `OK`; the second when every scenario line starts with `PASS`:

```bash
.venv/bin/python -m unittest discover -s tests
.venv/bin/python eval/run_eval.py
```

## More documentation

- [docs/MEMORY_ENGINE.md](docs/MEMORY_ENGINE.md): the memory algorithm
- [docs/RESULTS.md](docs/RESULTS.md): evaluation results
- [docs/AUDAY_UI.md](docs/AUDAY_UI.md): Auday's screens and interactions
- [docs/AUDAY_OBSERVATIONS.md](docs/AUDAY_OBSERVATIONS.md): how the real Auday behaves, measured on a device
- [docs/IPHONE_UI_CHECKLIST.md](docs/IPHONE_UI_CHECKLIST.md): the iPhone app compared with Auday, screen by screen
- [docs/RESEARCH.md](docs/RESEARCH.md): sources and how far to trust them
- [docs/SKILL_SYNC_PROTOCOL.md](docs/SKILL_SYNC_PROTOCOL.md): the protocol for syncing with the official Auday skill
- [docs/IPHONE_MAC_E2E.md](docs/IPHONE_MAC_E2E.md): end-to-end test of the iPhone app and the Mac in the simulator
- [watch/README.md](watch/README.md): the Apple Watch and iPhone apps
- [cloud/capture-worker/README.md](cloud/capture-worker/README.md): a cloud proxy that logs Auday's AI requests (for research; not needed to run the app)
