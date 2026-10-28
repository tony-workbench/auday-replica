"""Re-send one captured Auday request N times to measure how stable the model's answer is.

  python scripts/replay_capture.py <captured-entry.json> [--key-env <file.env>] -n 10 --out <private-dir>

The request body is sent unchanged (same model, messages, response_format, no temperature),
straight to Gemini's OpenAI-compatible endpoint. The API key is GEMINI_API_KEY from --key-env,
or else from the private keys file (memengine/secrets.py); it is never printed or written.
Answers are saved only in --out, because captured data is private.
"""

import argparse
import json
import statistics
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from memengine import net, secrets  # noqa: E402

ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
TLS = net.TLS   # certifi's CA bundle; python.org builds ship without one


def read_key(path):
    key = secrets.read_env_file(path).get("GEMINI_API_KEY") if path else secrets.get("GEMINI_API_KEY")
    if not key:
        sys.exit("GEMINI_API_KEY not found in " + str(path or secrets.env_file()))
    return key


def send(body, key):
    request = urllib.request.Request(ENDPOINT, json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json",
                                              "Authorization": "Bearer " + key})
    with urllib.request.urlopen(request, timeout=300, context=TLS) as response:
        data = json.load(response)
    return json.loads(data["choices"][0]["message"]["content"])


def describe(output):
    """Content-free shape of one answer: lists and strings become their lengths, other values stay."""
    shape = {}
    for name, value in output.items():
        shape[name] = len(value) if isinstance(value, (list, str)) else value
    return shape


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("entry")
    parser.add_argument("--key-env")
    parser.add_argument("-n", type=int, default=10)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    entry = json.loads(Path(args.entry).read_text())
    body = json.loads(entry["body"])
    key = read_key(args.key_env)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    runs = []
    for i in range(args.n):
        try:
            result = send(body, key)
        except (urllib.error.HTTPError, urllib.error.URLError, KeyError, ValueError) as error:
            print(f"run {i + 1}: failed ({type(error).__name__}: {getattr(error, 'code', '')})", file=sys.stderr)
            continue
        runs.append(result)
        print(f"run {i + 1}: {describe(result)}", file=sys.stderr)
        time.sleep(1)
    (out / (Path(args.entry).stem + ".replays.json")).write_text(json.dumps(runs, ensure_ascii=False, indent=1))

    numeric = {k for r in runs for k, v in r.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}
    counts = {k for r in runs for k, v in r.items() if isinstance(v, list)}
    summary = {"runs": len(runs)}
    for k in sorted(numeric | counts):
        values = [len(r[k]) if k in counts else r[k] for r in runs if k in r]
        summary[k + (" (count)" if k in counts else "")] = {
            "min": min(values), "max": max(values), "mean": round(statistics.mean(values), 2)}
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
