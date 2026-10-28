"""Connect the iPhone companion to this Mac, the way Auday pairs a computer with the phone.

  .venv/bin/python -m app.pair_iphone [--port 8765] [--data data]

On the iPhone: Auday Replica › Connect to your workflow › Enable access. This command finds the iPhone
on the Wi-Fi, asks for the communication password shown there (typed, not echoed), and sends the
iPhone this Mac's address and the upload token over TLS-PSK keyed by that password. The iPhone
checks it can reach the server before it answers. See the Pairing section of docs/IPHONE_MAC_E2E.md.
"""

import argparse
import getpass
import json
import os
import secrets
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "app" / "iphone_pair"
KIT = ROOT / "watch" / "AudayKit" / "Sources" / "AudayKit" / "Pairing.swift"
ERRORS = {
    "awaiting_phone_or_wrong_password": "The iPhone did not answer. Check the password, and keep "
                                        "Connect to your workflow open with access enabled.",
    "use_generated_16_character_communication_password": "That is not a 16-character communication password.",
    "mac_unreachable": "The iPhone could not reach this Mac. Start the server with --host 0.0.0.0, "
                       "and keep both on the same Wi-Fi.",
    "token_refused": "The server refused the token. Start it without --token, or with the same "
                     "AUDAY_TOKEN as this command.",
}


def load_token(data_dir):
    """The token the iPhone uploads with, kept in `<data>/lan-token` (owner-only), made on first use."""
    path = Path(data_dir) / "lan-token"
    if path.exists() and path.read_text().strip():
        return path.read_text().strip()
    path.parent.mkdir(parents=True, exist_ok=True)
    token = secrets.token_hex(16)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(token + "\n")
    return token


def helper(request):
    from app.workflow_server import build_helper
    binary = build_helper(HELPER, "auday-replica-pair", [KIT])
    out = subprocess.run([str(binary)], input=json.dumps(request) + "\n", capture_output=True, text=True,
                         timeout=60).stdout
    return json.loads(out.strip().splitlines()[-1]) if out.strip() else {"ok": False, "error": "helper_failed"}


def server_running(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/status", timeout=2):
            return True
    except OSError:
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--data", default=str(ROOT / "data"))
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not server_running(args.port):
        print(f"Auday Replica is not running on port {args.port}. Start it first with --host 0.0.0.0.")
        return 1
    print("Looking for the iPhone…")
    services = helper({"op": "discover"}).get("services") or []
    if not services:
        print("No iPhone found. On the iPhone open Auday Replica › Connect to your workflow and tap Enable access.")
        return 1
    service = services[0]
    if len(services) > 1:
        for n, name in enumerate(services, 1):
            print(f"  {n}. {name}")
        choice = input("Which one? ").strip()
        if not choice.isdigit() or not 1 <= int(choice) <= len(services):
            return 1
        service = services[int(choice) - 1]
    print(f"Found {service}.")
    password = getpass.getpass("Communication password (shown on the iPhone): ")
    token = os.environ.get("AUDAY_TOKEN") or load_token(args.data)
    reply = helper({"op": "pair", "service": service, "password": password, "port": args.port, "token": token})
    if reply.get("ok"):
        print(f"Connected. {reply.get('device') or service} now uploads to http://{reply['host']}:{args.port}.")
        return 0
    print(ERRORS.get(reply.get("error"), f"Pairing failed: {reply.get('error')}"))
    return 1


if __name__ == "__main__":
    sys.path.insert(0, str(ROOT))
    sys.exit(main())
