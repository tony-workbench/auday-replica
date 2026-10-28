"""HTTPS for every outbound call.

The python.org installer for macOS ships without CA certificates until its "Install
Certificates.command" is run, so a fresh Mac fails every download with CERTIFICATE_VERIFY_FAILED.
Verify against certifi's bundle instead.
"""

import shutil
import ssl
import urllib.request

import certifi

TLS = ssl.create_default_context(cafile=certifi.where())


def urlopen(request, timeout):
    return urllib.request.urlopen(request, timeout=timeout, context=TLS)


def download(url, path, timeout=600):
    """Save `url` to `path` (urlretrieve cannot take an SSL context)."""
    request = urllib.request.Request(url, headers={"User-Agent": "auday-replica"})
    with urlopen(request, timeout) as response, open(path, "wb") as out:
        shutil.copyfileobj(response, out)
