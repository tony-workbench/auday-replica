#!/usr/bin/env python3
"""Stands in for the watch in the iOS Simulator: drops a fragment, mark or Health samples into the
DEBUG build's Documents/DebugInbox (AudayPhone/DebugInbox.swift) and tells the app to read it.
See docs/IPHONE_MAC_E2E.md.

  sim-inject.py fragment FILE.caf [--id ID] [--session S] [--start EPOCH] [--places]
  sim-inject.py mark [--id ID] [--start EPOCH]
  sim-inject.py health [--start EPOCH]      # needs the test build with NSHealthUpdateUsageDescription
"""

import argparse
import json
import shutil
import subprocess
import time
import uuid
from pathlib import Path

BUNDLE = "io.github.tony-workbench.auday-replica.phone"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=["fragment", "mark", "health"])
    parser.add_argument("audio", nargs="?")
    parser.add_argument("--device", default="booted")
    parser.add_argument("--bundle", default=BUNDLE)
    parser.add_argument("--id", default=str(uuid.uuid4()).upper())
    parser.add_argument("--session", default="sim-session")
    parser.add_argument("--start", type=float, default=time.time() - 10)
    parser.add_argument("--places", action="store_true", help="three positions at one spot (a stay)")
    args = parser.parse_args()

    data = subprocess.check_output(["xcrun", "simctl", "get_app_container", args.device, args.bundle, "data"],
                                   text=True).strip()
    inbox = Path(data) / "Documents" / "DebugInbox"
    inbox.mkdir(parents=True, exist_ok=True)
    t = args.start
    if args.kind == "fragment":
        places = [[t + i * 40, 37.3349 + i * 0.00001, -122.0090, 10.0] for i in range(3)] if args.places else []
        item = {"kind": "fragment", "id": args.id, "session": args.session, "start": t, "duration": 5.0,
                "ext": "caf", "places": places}
        shutil.copy(args.audio, inbox / f"{args.id}.caf")
    elif args.kind == "mark":
        item = {"kind": "mark", "id": args.id, "start": t}
    else:
        item = {"kind": "health-seed",
                "hr": [[t + i * 60, t + i * 60 + 1, 62 + i] for i in range(-5, 5)],
                "steps": [[t - 600, t - 300, 420], [t - 300, t, 380]]}
    (inbox / f"{args.id}.json").write_text(json.dumps(item))
    subprocess.check_call(["xcrun", "simctl", "spawn", args.device, "notifyutil", "-p", "auday-replica.debug-inbox"])
    print(json.dumps(item))


if __name__ == "__main__":
    main()
