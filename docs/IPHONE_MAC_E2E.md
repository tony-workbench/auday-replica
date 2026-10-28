# iPhone companion ↔ Mac server: end-to-end test

Tests the iPhone app (`watch/AudayPhone`) against the Mac server (`app/server.py`) in the iOS Simulator,
with no Apple ID and no watch. The watch → iPhone hand-over (WatchConnectivity) is not covered.

## Standing in for the watch

Debug builds of the iPhone app read a folder, `Documents/DebugInbox` (`watch/AudayPhone/DebugInbox.swift`).
Each JSON file there goes to `PhoneLink.receive(...)`, the same function that handles a real hand-over from
the watch, so everything after the hand-over is real app code: outbox, background `URLSession` uploads,
retries, geocoding and HealthKit.
The app reads the folder at launch, when it comes to the foreground, and when it gets the system
notification `auday-replica.debug-inbox`. `watch/scripts/sim-inject.py` writes the files and sends the notification.

| JSON `kind` | Stands for |
|---|---|
| `fragment` (+ `<id>.caf`) | `Fragment.metadata` of a finished watch fragment, optionally with `places` |
| `mark` | `Mark.userInfo` |
| `health-seed` | Writes heart-rate and step samples to the simulator's Health, then runs `HealthSync` |

The Health app won't open in the iOS 27.1 simulator, so the app writes the samples itself. Writing to
Health needs `NSHealthUpdateUsageDescription`, added only to a copy of the built app (step 3); the
project never asks for write access.

## Running it

```bash
# 1. A throwaway server on a free port (never data/). Point the app at the Mac's LAN address:
#    requests from 127.0.0.1 skip the token check.
.venv/bin/python -m app.server --data /tmp/e2e-data --host 0.0.0.0 --port 60293 --token e2e-secret

# 2. Build for the simulator without an Apple ID (ad-hoc signing keeps the HealthKit entitlement).
#    Use -destination, not -sdk iphonesimulator: -sdk forces the embedded watch app onto the iOS SDK.
#    Install `xcodegen` as described in watch/README.md.
cd watch && xcodegen generate
xcodebuild -project AudayReplica.xcodeproj -scheme AudayPhone -destination 'generic/platform=iOS Simulator' \
  -configuration Debug -derivedDataPath /tmp/dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build

# 3. Health test only: a copy allowed to write sample data.
cp -R /tmp/dd/Build/Products/Debug-iphonesimulator/AudayPhone.app /tmp/AudayPhone.app
/usr/libexec/PlistBuddy -c "Add :NSHealthUpdateUsageDescription string 'Simulator test only'" /tmp/AudayPhone.app/Info.plist
codesign -f -s - --preserve-metadata=entitlements /tmp/AudayPhone.app

# 4. Install and launch, open Settings › Connect to your workflow › Enable access, then on the Mac run
#    `.venv/bin/python -m app.pair_iphone --port 60293` and type the password the iPhone shows.
#    Bundle id is <AUDAY_BUNDLE_PREFIX>.phone; below is the default prefix from Config/Base.xcconfig.
xcrun simctl install booted /tmp/AudayPhone.app && xcrun simctl launch booted io.github.tony-workbench.auday-replica.phone

# 5. Feed it. Real speech from `say` makes the transcription check meaningful.
say -o /tmp/s.aiff "Remember to buy milk tomorrow morning." && afconvert -f caff -d aac -b 32000 -c 1 /tmp/s.aiff /tmp/s.caf
watch/scripts/sim-inject.py fragment /tmp/s.caf --id FRAG-1 --session S-1
watch/scripts/sim-inject.py fragment /tmp/s.caf --id FRAG-1 --session S-1 --start <same start>   # retry
watch/scripts/sim-inject.py fragment /tmp/s.caf --places
watch/scripts/sim-inject.py mark
watch/scripts/sim-inject.py health
```

Check results in `/tmp/e2e-data/auday.sqlite` (`assets`, `records`, `marks`, `health_samples`, `places`)
and in the server log.

## Results (2026-10-26, Xcode 27.1, iOS 27.1 simulator "iPhone Duo")

The first two rows used the old manual address and token fields, since replaced by [Pairing](#pairing-connect-to-your-workflow-2026-10-27).

| Check | Result |
|---|---|
| Wrong token, "Save and check connection" | "Wrong or missing token"; `POST /api/audio` returned 401; the fragment stayed in the outbox and retried with backoff |
| Right token | "Connected to the replica"; the waiting fragment uploaded right after Save |
| Fragment stored | Asset with `start` in local offset (`2026-10-26T23:20:23-07:00`), `session`, `fragment`; CAF converted to WAV |
| Same fragment again | 200; still one asset, one WAV, one transcript (`duplicate`) |
| Transcription | Local SenseVoice transcript of the spoken sentence, linked to the asset |
| Mark | Stored at its watch time |
| Same mark again | **Was stored twice; fixed**: `add_mark` now returns the existing mark |
| Missing or wrong token (curl from the LAN address) | 401; right token 200 |
| Server down ~45 s | Fragment and mark waited in the outbox, uploaded on the next backoff after restart; outbox empty |
| HealthKit | Read permission sheet works with the entitlement; 10 seeded heart-rate and 2 step samples reached `health_samples` with offsets |
| Places | iPhone geocoder named a stay ("Apple Park · 1 Apple Park Way"), stored with its session |

Test-build only: granting write access to heart rate and steps made iOS ask for read access to them
again. Release builds never request write access.

## What only a real iPhone can show

- The Local Network prompt (`NSLocalNetworkUsageDescription`). The simulator uses the Mac's network
  stack and never asks. Check that it appears on the first upload and that "Don't Allow" fails with a
  readable message.
- Real Wi-Fi: the phone reaching the Mac's LAN IP, the Mac firewall letting Python accept incoming
  connections, and the address changing after a DHCP renewal or network switch.
- Uploads while the phone is locked or the app suspended: background `URLSession`,
  `handleEventsForBackgroundURLSession`, and Health reads (which fail while locked).
- The real WatchConnectivity hand-over from the watch (part of the watch-app work).
- Free Apple ID signing with the HealthKit capability, and re-signing every 7 days.

## Pairing: Connect to your workflow (2026-10-27)

Pairing follows Auday's "Connect to your workflow" roles: the phone creates the secret and advertises itself; the computer finds it and types the secret.

| Step | iPhone (`watch/AudayPhone/ConnectMac.swift`) | Mac (`app/pair_iphone.py`, `app/iphone_pair/`) |
|---|---|---|
| Secret | 16 characters from `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (80 bits), shown as `XXXX-XXXX-XXXX-XXXX`; case, spaces and hyphens ignored; "New password" makes a new one. Stored in the app's Keychain | Read from the terminal without echo (`getpass`); never in arguments or files |
| Discovery | Advertises `_audayreplica._tcp` (`NSBonjourServices`) while "Enable access" is on and the page is open | Browses for 3 s and lists results; asks which one if there are several |
| Channel | Accepts one TLS 1.2 connection, ECDHE-PSK-CHACHA20-POLY1305 only; key = HKDF-SHA256(password, salt and identity `auday-replica-pair-v1`) | Connects with the same key over IPv4. A wrong password fails the handshake |
| Request | — | One frame (4-byte big-endian length + JSON): `{"op":"pair","host","port","token","name"}`. `host` is the Mac's address as this connection sees it; `token` is `<data>/lan-token` (created on first use, mode 600) or `AUDAY_TOKEN` |
| Check | Calls `GET /api/status` at that address with that token; saves both only on 200 | Prints "Connected" or the reason (`mac_unreachable`, `token_refused`, `awaiting_phone_or_wrong_password`) |
| Afterwards | Shows "Connected to <Mac name>" and "Last read <time>". Scope "Text and audio" uploads recordings; "All text" sends only on-device transcripts (`POST /api/transcripts`) | A server started with `--host 0.0.0.0` uses the same `lan-token` |

Tests: `watch/scripts/test-kit.sh` (password rules, key derivation, frames), `tests/test_pair_iphone.py` (token file).
