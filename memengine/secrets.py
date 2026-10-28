"""API keys from a private env file, so they never need to be exported to every program.

Order: the process environment (for CI or a one-off run), then the file named by
AUDAY_SECRETS, then ~/.config/secrets/keys.env. The file holds NAME=value lines and
should be readable only by its owner (chmod 600).
"""

import os
from pathlib import Path


def env_file():
    return Path(os.environ.get("AUDAY_SECRETS") or Path.home() / ".config" / "secrets" / "keys.env")


def read_env_file(path):
    values = {}
    try:
        text = Path(path).read_text()
    except OSError:
        return values
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("export "):
            line = line[7:]
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        values[name.strip()] = value.split(" #")[0].strip().strip("\"'")
    return values


def get(name):
    """The key's value, or None. Never logged."""
    return os.environ.get(name) or read_env_file(env_file()).get(name) or None
