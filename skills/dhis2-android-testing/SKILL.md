---
name: dhis2-android-testing
description: Drive the Android emulator on the host machine over adb — install APKs, take screenshots, inspect the UI hierarchy, tap/swipe/type — to test Android apps, in particular the DHIS2 Android Capture app against a DHIS2 test instance. Use whenever a task involves testing on Android, the DHIS2 Android app, an emulator, an APK, or verifying mobile sync/login behavior. Triggers on phrases like "test this on Android", "install the APK", "does login work in the app", "check what the Capture app shows". Only works when ADB_SERVER_SOCKET is set (typically inside an agent sandbox); if it is unset, this capability is unavailable — ask the user instead.
---

# Android emulator testing via the host's adb server

The emulator runs on the **host machine**; this sandbox's `adb` client is
pointed at the host's adb server through `ADB_SERVER_SOCKET` (set
automatically). No setup needed — start with:

```bash
adb devices    # expect: emulator-5554   device
```

If `ADB_SERVER_SOCKET` is unset, stop and ask the user (host setup is
`android-testing.md` in the ai-agentic-sandbox repo). If `adb devices` lists
nothing, the emulator isn't booted — ask the user to start it; you cannot
start it from in here.

**Never run `adb kill-server`.** The server belongs to the host; killing it
breaks the connection for every sandbox and you cannot restart it. If adb
complains about a client/server version mismatch, report it to the user
instead of letting adb "kill and restart" the server.

## Core loop: look → act → look

You can't see the emulator window; screenshots are your eyes:

```bash
adb exec-out screencap -p > /tmp/screen.png     # then Read the PNG
```

To find what to tap, prefer the UI hierarchy over guessing pixels — each
node has a `bounds="[x1,y1][x2,y2]"` attribute (tap the center):

```bash
adb shell uiautomator dump /sdcard/ui.xml && adb shell cat /sdcard/ui.xml
```

Interact:

```bash
adb shell input tap 540 1200
adb shell input swipe 540 1600 540 400 300      # x1 y1 x2 y2 [ms] — scroll down
adb shell input text 'district'                  # no focus handling: tap the field first
adb shell input keyevent 66                      # ENTER (4=BACK, 111=ESC, 67=DEL)
```

`input text` quirks: escape spaces as `%s`, and quote the string — special
characters otherwise get eaten by the shell. For long/awkward strings, set
the field via the clipboard only if the app supports it; usually tap + type
is fine.

After every action that triggers loading (login, sync, screen change), take
a fresh screenshot before deciding the next step. Sync in the DHIS2 app can
take a minute or more — poll with screenshots, don't conclude failure early.

## APKs

```bash
adb install -r /path/to/app.apk        # -r = reinstall, keeps app data
adb uninstall com.dhis2
```

The DHIS2 Capture app APK is usually provided in the project directory. If
not, it can be downloaded from GitHub releases
(`gh release download -R dhis2/dhis2-android-capture-app --pattern 'dhis2-v*.apk'`)
— use the regular APK, not the `training` one. If the release-asset CDN is
blocked by the egress firewall, ask the user to download it on the host into
the project dir.

## Pointing the app at a DHIS2 instance

The emulator is on the host, **not** on dev-net. Inside the app, the host's
loopback is `10.0.2.2`:

| Who | URL for the same instance |
|---|---|
| You (sandbox) | `http://dhis2-<name>:8080` |
| App (emulator) | `http://10.0.2.2:<http_port>` |

Get `http_port` from the broker: `GET $DHIS2_BROKER_URL/instances` (see the
`dhis2-instances` skill). The app accepts plain `http://` URLs. Credentials
for broker instances are usually `admin`/`district`.

Sanity-check the instance is up before blaming the app:

```bash
curl -s http://dhis2-<name>:8080/api/system/info.json | head -c 200
```

## DHIS2 Capture app specifics

- **Screenshots return 0 bytes once logged in** (an emulator quirk: a window
  with `FLAG_SECURE` yields an empty file, not a black image; the launcher
  still captures fine). The app sets `FLAG_SECURE` unless the Android
  Settings config allows screen capture. Verify with
  `adb shell dumpsys window windows | grep -A9 "com.dhis2/.*MainActivity" | grep SECURE`.
  Fix on the server, then log in fresh (`pm clear com.dhis2` first — the app
  reads this only at login/config sync):

  ```bash
  # The app reads the LEGACY namespace ANDROID_SETTING_APP (singular!),
  # key general_settings. This is the reliable path.
  curl -u admin:district -X POST -H "Content-Type: application/json" \
    -d '{"allowScreenCapture": true, "encryptDB": false, "reservedValues": 100}' \
    "$B/api/dataStore/ANDROID_SETTING_APP/general_settings"
  ```

  Pitfalls learned the hard way:
  - The namespace is `ANDROID_SETTING_APP` (**singular**), NOT
    `ANDROID_SETTINGS_APP` (plural). The plural namespace is the *new*
    Settings-app v2 format; do not hand-write its `info` key — a wrong
    `dataStoreVersion` there makes the app throw
    `IllegalArgumentException: Invalid version` and **abort metadata sync**
    (symptom: "Something went wrong" on the sync screen). If you created bad
    plural-namespace keys, delete them so the app falls back to the legacy
    namespace.
  - Writing this datastore namespace via the API needs the admin to hold the
    `M_androidsettingsapp` authority (install the Android Settings app from
    App Hub, or grant the authority). Otherwise the namespace is "protected,
    access denied".
  - `uiautomator dump` works regardless of FLAG_SECURE — it is never blocked,
    so it is always available as your eyes even without this fix.
- Package name: `com.dhis2`. Reset to a clean first-run state with
  `adb shell pm clear com.dhis2` (faster than reinstalling).
- Login screen: server URL field first, then username/password. Tap each
  field before `input text`.
- After login the app runs an initial metadata + data sync (progress
  screen). Wait for it — screenshot-poll every ~10 s.
- Force-stop without clearing data: `adb shell am force-stop com.dhis2`.
- Launch: `adb shell monkey -p com.dhis2 1` (or find the activity via
  `adb shell cmd package resolve-activity --brief com.dhis2`).

## Debugging

```bash
adb logcat -d -t 200                   # recent log, don't stream forever
adb logcat -d | grep -i com.dhis2      # app-related lines
adb shell dumpsys window | grep mCurrentFocus    # which activity is foreground
```

If multiple devices are listed, pass `-s <serial>` (e.g. `-s emulator-5554`)
to every adb command.
