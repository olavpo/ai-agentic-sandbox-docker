# Testing the DHIS2 Android app from the sandbox

How a sandboxed agent tests the DHIS2 Android (Capture) app against a
broker-created DHIS2 instance. The emulator cannot run inside the sandbox
(no nested virtualization in Docker's Linux VM on macOS), so it runs on the
**host** and the agent drives it remotely over adb — the same
single-host-port pattern as d2-broker.

```
 Host (macOS)
 ┌──────────────────────────────────────────────────────────────┐
 │  Android emulator (AVD)                                      │
 │      ▲ adb protocol                  app traffic ▼           │
 │  adb server :5037 (loopback)      10.0.2.2:<http_port>       │
 │      ▲                                   │                   │
 │      │ host.docker.internal:5037         ▼                   │
 │  ┌───┴──────────┐   dev-net   ┌──────────────────────┐       │
 │  │ sandbox      │◄───────────►│ dhis2-agent-* :8080  │       │
 │  │ (adb client) │             │ (published :http_port)│      │
 │  └──────────────┘             └──────────────────────┘       │
 └──────────────────────────────────────────────────────────────┘
```

Two URLs for the same DHIS2 instance, depending on who's asking:

- **Agent in the sandbox** → `http://dhis2-<name>:8080` (dev-net)
- **App on the emulator** → `http://10.0.2.2:<http_port>` (the host-published
  port; `10.0.2.2` is the emulator's alias for the host's loopback).
  `http_port` is in the broker's `GET /instances` response.

The sandbox wiring (adb client in the image, `ADB_SERVER_SOCKET` env,
firewall exemption) is automatic: if an adb server is listening on the host
when you run `agent-sandbox start`, the sandbox is connected. Everything
below is the **one-time host setup**.

## 1. Install the emulator and a system image

`sdkmanager`/`avdmanager` are already installed via Homebrew
(`android-commandlinetools`), with the SDK root at
`/opt/homebrew/share/android-commandlinetools`. Platform-tools (adb) and
build-tools are already there too; what's missing is the emulator and a
system image (~2–3 GB download):

```bash
sdkmanager --licenses     # accept once
sdkmanager "emulator" "system-images;android-34;google_apis;arm64-v8a"
```

Use an `arm64-v8a` image — on Apple Silicon it runs near-native speed;
x86_64 images won't run at all.

Add the SDK to your shell profile (`~/.zshrc`) so `adb` and `emulator` are
on PATH:

```bash
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
```

## 2. Create the AVD

```bash
avdmanager create avd -n dhis2-test \
  -k "system-images;android-34;google_apis;arm64-v8a" \
  -d pixel_7
```

**Then fix the hardware config** — `avdmanager` writes an AVD with GPU
rendering *disabled*, and software rendering makes Android 14 unusably slow
(constant "Process system isn't responding" ANRs). Enable the host GPU and
the hardware keyboard (more reliable `adb shell input text`):

```bash
CFG=~/.android/avd/dhis2-test.avd/config.ini
sed -i '' -e 's/^hw.gpu.enabled=no/hw.gpu.enabled=yes/' \
          -e 's/^hw.gpu.mode=auto/hw.gpu.mode=host/' \
          -e 's/^hw.keyboard=no/hw.keyboard=yes/' "$CFG"
```

One AVD is enough; agents reset app state with
`adb shell pm clear com.dhis2`, and you can always wipe the device with
`emulator -avd dhis2-test -wipe-data`.

## 3. Run the adb server as a launchd service

The sandbox connects to the host's adb server on port 5037. The default
**loopback** bind is sufficient — Docker Desktop forwards
`host.docker.internal` traffic from the host's loopback, so nothing is
exposed to your LAN (verified on this setup; do **not** use `adb -a`).

Any `adb` command auto-starts a server, but a launchd service keeps it alive
across reboots and accidental `adb kill-server`s:

```bash
cat > ~/Library/LaunchAgents/local.adb-server.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.adb-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/share/android-commandlinetools/platform-tools/adb</string>
        <string>-P</string>
        <string>5037</string>
        <string>server</string>
        <string>nodaemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/adb-server.log</string>
</dict>
</plist>
EOF
launchctl load -w ~/Library/LaunchAgents/local.adb-server.plist
adb devices    # should print an (empty) device list without errors
```

## 4. Get the APK

Download the official release from GitHub (each release ships a regular and
a `training` APK — use the regular one) into a directory you'll mount into
the sandbox, e.g. the project dir:

```bash
gh release download -R dhis2/dhis2-android-capture-app \
  --pattern 'dhis2-v*.apk' -D ~/Repos/my-project/apk/
```

**Version pairing:** each app release supports roughly the three most recent
DHIS2 server versions — check the release notes on the GitHub release page
and make sure your broker seeds include a supported server version.

Downloading on the host is the dependable path; the agent can also try
`gh release download` from inside the sandbox (GitHub is allowlisted), but
the release-asset CDN may fall outside the allowlisted IP ranges.

## 5. Daily flow

```bash
# 1. Boot the emulator (headless; drop -no-window to watch it yourself)
emulator -avd dhis2-test -no-window -no-audio -no-boot-anim &
adb wait-for-device shell \
  'while [ -z "$(getprop sys.boot_completed)" ]; do sleep 1; done'

# 2. Start the sandbox (adb wiring is picked up automatically)
agent-sandbox start ~/Repos/my-project
```

The `agent-sandbox start` output should include a line like
`Android adb: tcp:host.docker.internal:5037`. First boot of a fresh AVD
takes a couple of minutes; later boots resume from a snapshot.

To watch what the agent is doing on the (headless) emulator:

```bash
brew install scrcpy && scrcpy   # live mirror of the emulator screen
```

A prompt that gives the agent everything it needs:

> The DHIS2 Android app APK is in `apk/`. Create a DHIS2 instance via the
> broker, install the APK on the emulator (`adb devices` — it's already
> wired up), log in to the instance at `http://10.0.2.2:<http_port>` as
> admin/district, and test X.

## 6. Verify the chain

From the sandbox shell (`agent-sandbox shell`):

```bash
echo "$ADB_SERVER_SOCKET"            # tcp:host.docker.internal:5037
adb devices                          # emulator-5554   device
adb install /my-project/apk/dhis2-v*.apk
adb exec-out screencap -p > /tmp/screen.png   # readable screenshot
```

## Troubleshooting

- **`ADB_SERVER_SOCKET` not set in the sandbox** — nothing was listening on
  port 5037 when the sandbox *started*. Start the adb server (step 3), then
  recreate the sandbox (`agent-sandbox remove <name>` + `start`; a plain
  resume re-runs the firewall but the env var is fixed at creation).
- **`adb server version (...) doesn't match this client`** — the container's
  adb (Ubuntu's `android-tools`) and the host's platform-tools have drifted
  to different protocol versions (both speak 1.0.41 today, so this is
  unlikely). Fix by updating whichever side is older
  (`sdkmanager platform-tools` on the host / rebuild the sandbox image);
  don't let the client "kill and restart" the server.
- **Device shows `offline`** — the emulator is still booting; wait for
  `sys.boot_completed` (see step 5).
- **"Process system isn't responding" / constant ANRs** — the AVD is using
  software rendering. Check `hw.gpu.enabled=yes` + `hw.gpu.mode=host` in
  `~/.android/avd/<name>.avd/config.ini` (see step 2), then restart the
  emulator. With host GPU, boots take ~20 s; with software rendering,
  minutes and ANRs.
- **Screenshots are empty (0 bytes) once the app is logged in** — the DHIS2
  app sets `FLAG_SECURE` on its windows, which on the emulator yields an
  empty screencap file (the launcher still captures fine). Server-side fix:
  POST `{"allowScreenCapture": true, "encryptDB": false, "reservedValues": 100}`
  to the **`ANDROID_SETTING_APP/general_settings`** datastore key (namespace
  is *singular*), then log the app in fresh (`adb shell pm clear com.dhis2`
  first). Needs the `M_androidsettingsapp` authority on the admin user
  (install the Android Settings app from App Hub). Do not hand-write the
  plural `ANDROID_SETTINGS_APP` namespace's `info` key — a wrong version
  there aborts metadata sync. `uiautomator dump` works regardless, so the
  agent can always drive the app even without this fix. Full detail is in
  the `dhis2-android-testing` skill.
- **App can't reach the DHIS2 instance** — confirm the instance's
  `http_port` from the broker (`GET /instances`) and that
  `curl http://localhost:<http_port>/api/system/info.json` works on the
  host. From the emulator side, open `http://10.0.2.2:<http_port>` in the
  emulator's browser. The app accepts plain `http://` URLs, so no TLS setup
  is needed.
- **Multiple emulators** — each gets its own serial (`emulator-5554`,
  `emulator-5556`, ...); agents must pass `-s <serial>` to adb. One emulator
  at a time keeps things simple.
