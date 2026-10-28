# Auday Replica for Apple Watch and iPhone

An Apple Watch recorder and its iPhone app. The watch records all day; the iPhone transcribes on the device, writes hourly summaries, Highlights and the daily reflection with your AI provider (which receives only text), and can copy recordings to Auday Replica on your Mac.

## What you need

- **Full Xcode**, from the App Store. When you first open it, it offers to download platforms: choose iOS and watchOS. The Command Line Tools alone are not enough.
- **XcodeGen**, either:
  - with Homebrew: `brew install xcodegen`, then use `xcodegen` in the commands below; or
  - without Homebrew: download the latest `xcodegen.zip` from the [XcodeGen releases page](https://github.com/yonaskolb/XcodeGen/releases) and unzip it in Downloads. Then write `~/Downloads/xcodegen/bin/xcodegen` wherever the commands below say `xcodegen`.
- **An Apple ID**; a free one works.
- An iPhone (iOS 17 or newer) and its paired Apple Watch (watchOS 10 or newer).
- A cable to connect the iPhone to the Mac.
- Only if you want a copy on the Mac: Auday Replica set up and running there as in the [main README](../README.md), on the same Wi-Fi as the iPhone.

## Build and install

Run the commands in Terminal, starting in the `auday-replica` folder.

1. Choose your own app identifier (each Apple ID needs its own, or signing fails). Replace `yourname` with any letters:

   ```bash
   echo 'AUDAY_BUNDLE_PREFIX = com.yourname.auday-replica' > watch/Config/Local.xcconfig
   ```

2. Create the Xcode project and open it:

   ```bash
   cd watch
   xcodegen generate
   open AudayReplica.xcodeproj
   ```

3. In Xcode › Settings › Accounts, click "+" at the bottom left and sign in with your Apple ID.

4. In Xcode, click the blue `AudayReplica` project at the top of the left sidebar. Under TARGETS select `AudayPhone`, open Signing & Capabilities and set Team to "Your Name (Personal Team)". Do the same for `AudayWatch`.

5. Save your team ID so regenerating the project keeps it. Still in the `watch` folder, run:

   ```bash
   grep -m1 -o 'DEVELOPMENT_TEAM = [A-Z0-9]*' AudayReplica.xcodeproj/project.pbxproj >> Config/Local.xcconfig
   cat Config/Local.xcconfig
   ```

   You should see two lines: `AUDAY_BUNDLE_PREFIX = ...` and `DEVELOPMENT_TEAM = ` followed by 10 letters and digits. If the second line is missing, press `Cmd+S` in Xcode and run the commands again.

6. Connect the iPhone to the Mac with the cable and tap "Trust This Computer" on the iPhone. Turn on Developer Mode on both the iPhone and the watch (Settings › Privacy & Security › Developer Mode; the device restarts).

7. At the top of Xcode, choose the `AudayPhone` scheme and your iPhone as the run destination, then click ▶ at the top left. This also installs the watch app; the first time can take a few minutes.

8. The first time, the iPhone says the developer is not trusted: open Settings › General › VPN & Device Management on the iPhone, trust your Apple ID, then click ▶ again.

9. The first time you open the iPhone app, allow access to Health data. The first time the watch records, allow the microphone and location.

If signing fails with a message about HealthKit, check that HealthKit is listed under Signing & Capabilities and that the identifier from step 1 is not one someone else already uses.

Apps signed with a free Apple ID expire after 7 days. When that happens, connect the iPhone and click ▶ in Xcode again.

## Set up the iPhone app

1. Open the app, tap "…" at the top right and open Settings.
2. **AI settings**: choose your provider, pick a model, paste your API key and save.
3. **Transcription**: "Local efficient" (SenseVoice, about 240 MB, downloaded once over Wi-Fi) or "Local accurate" (Whisper, about 216 MB). Both run on the iPhone.
4. **My voice recognition** (optional): read the short passages aloud so your own words are marked "Me" in transcripts.

## Connect to the Mac (optional)

1. Put the iPhone and the Mac on the same Wi-Fi.
2. On the iPhone, open Settings › Connect to your workflow. Choose what the Mac may read (All text, or Text and audio), tap "Enable access" at the bottom and keep this page open. Allow Local Network access when asked.
3. On the Mac, in the `auday-replica` folder, start the app (stop any running copy with `Ctrl+C` first):

   ```bash
   ./scripts/start.sh --host 0.0.0.0
   ```

   If macOS asks whether Python may accept incoming network connections, allow it.

4. In a second Terminal window, also in `auday-replica`, run:

   ```bash
   .venv/bin/python -m app.pair_iphone
   ```

   The first run takes a minute to build a helper. When asked, type the communication password shown on the iPhone page (tap the eye icon); nothing appears while you type. Press Return.
5. When the iPhone page says "Connected to" your Mac's name, recordings reach the Mac automatically.

If it cannot connect: make sure both devices are on the same Wi-Fi (guest networks often keep devices from seeing each other), turn on Auday Replica under Settings › Privacy & Security › Local Network on the iPhone, and keep the iPhone page open while pairing.

## Use the watch

1. Tap "Tap to start" to record.
2. Tap the screen to mark a moment ("Marked"); marked moments are favoured for Highlights.
3. Hold the screen for 1 second to stop.
4. Swipe down for the sync page. "TODAY, TOGETHER" is today's recorded time; "Awaiting sync" is audio not yet on the iPhone. The watch sends a piece when it ends (at most 15 minutes, and at every full hour); "Sync now" also sends the current piece.

No watch? With the Mac app running, this uploads a 5-second test tone as the iPhone would:

```bash
watch/scripts/fake-fragment.sh http://127.0.0.1:8765
```

## Test

In the `auday-replica` folder. Both pass when they end without errors (the second ends with `OK`); the first needs only the Command Line Tools:

```bash
watch/scripts/test-kit.sh
.venv/bin/python -m unittest discover -s tests -p test_watch_upload.py
```

## More documentation

- [docs/IPHONE_UI_CHECKLIST.md](../docs/IPHONE_UI_CHECKLIST.md): the iPhone app compared with Auday, screen by screen
- [docs/IPHONE_MAC_E2E.md](../docs/IPHONE_MAC_E2E.md): test uploads between the iPhone and the Mac in the iOS simulator, without an Apple ID
