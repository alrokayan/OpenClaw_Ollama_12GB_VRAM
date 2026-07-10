# Android Debug Bridge (ADB) Developer Guide

> **Document ID:** `adb-developer-guide`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** Context7 `/websites/developer_android_tools` and official Android Developer Tools documentation

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Architecture

ADB uses a three-part architecture:

```text
adb client command
       │
       ▼
adb server on host, normally TCP 5037
       │
       ▼
adbd daemon on Android device or emulator
```

The client asks the host server to select a transport. The server communicates with `adbd` over USB, emulator transport, or TCP. The Android shell identity is privileged for debugging but is not normally root.

## 2. Installation

ADB is distributed in Android SDK Platform-Tools. Prefer the Platform-Tools package managed by Android Studio or `sdkmanager`.

```powershell
adb version
adb start-server
adb devices -l
```

Use one known ADB binary. Multiple SDK installations can produce client/server version conflicts.

```powershell
Get-Command adb -All
where.exe adb
```

## 3. Device states

`adb devices -l` may report:

- `device` — ready;
- `offline` — transport exists but is not responding;
- `unauthorized` — host RSA key not approved;
- `no permissions` — host USB permissions or driver problem;
- `bootloader`, `recovery`, or sideload modes in specialized workflows.

Do not begin automation until the selected serial reports `device` and the boot process is complete.

```powershell
adb -s emulator-5554 wait-for-device
adb -s emulator-5554 shell getprop sys.boot_completed
```

## 4. Device selection

```powershell
adb -s SERIAL shell getprop ro.product.model
adb -d shell id      # single USB device
adb -e shell id      # single emulator
```

For scripts, always pass `-s SERIAL` or set `ANDROID_SERIAL`. Never rely on implicit selection when more than one transport may exist.

## 5. Shell execution

```powershell
adb -s $serial shell id
adb -s $serial shell getprop ro.build.version.release
adb -s $serial shell 'ls -la /sdcard/'
```

Quoting crosses two parsers: the host shell and Android shell. For complex commands, place a script on the device or invoke a simple command with explicit arguments rather than nesting quotations.

## 6. Files

```powershell
adb -s $serial push .\app.apk /data/local/tmp/app.apk
adb -s $serial pull /sdcard/Download/report.json .\artifacts\
adb -s $serial shell rm /data/local/tmp/app.apk
```

Use `/data/local/tmp` for temporary shell-accessible files. Validate host and device paths before deletion.

## 7. Package management

```powershell
adb -s $serial install -r .\app-debug.apk
adb -s $serial install -r -t .\app-debug.apk
adb -s $serial install-multiple .\base.apk .\split_config.arm64_v8a.apk
adb -s $serial uninstall com.example.app
adb -s $serial shell pm list packages -3
adb -s $serial shell pm path com.example.app
adb -s $serial shell dumpsys package com.example.app
```

Useful flags vary by Platform-Tools and Android version. Read `adb install --help` from the installed version.

## 8. Activity and intent manager

```powershell
adb -s $serial shell am start -W -n com.example.app/.MainActivity
adb -s $serial shell am force-stop com.example.app
adb -s $serial shell monkey -p com.example.app 1
adb -s $serial shell am broadcast -a com.example.ACTION
```

Prefer explicit component names in deterministic tests. `monkey -p PACKAGE 1` is a convenient launcher fallback, not a general test strategy.

## 9. Input injection

```powershell
adb -s $serial shell input tap 500 900
adb -s $serial shell input swipe 500 1500 500 400 500
adb -s $serial shell input keyevent KEYCODE_HOME
adb -s $serial shell input text 'hello%sworld'
```

Coordinate input is resolution-dependent and fragile. Prefer semantic UI automation when accessibility nodes are available. Use scrcpy input for lower latency and better clipboard behavior when appropriate.

## 10. Screenshots and recording

```powershell
adb -s $serial exec-out screencap -p > screen.png
adb -s $serial shell screenrecord /sdcard/demo.mp4
adb -s $serial pull /sdcard/demo.mp4
```

In PowerShell, direct binary redirection behavior varies by version. For production capture, use a binary-safe process API or scrcpy's screenshot/stream path.

## 11. Display and density

```powershell
adb -s $serial shell wm size
adb -s $serial shell wm density
adb -s $serial shell dumpsys display
```

Temporary overrides:

```powershell
adb -s $serial shell wm size 1080x1920
adb -s $serial shell wm size reset
adb -s $serial shell wm density 420
adb -s $serial shell wm density reset
```

Always restore overrides in test teardown.

## 12. Logs and diagnostics

```powershell
adb -s $serial logcat -c
adb -s $serial logcat -v threadtime
adb -s $serial logcat --pid=$(adb -s $serial shell pidof com.example.app)
adb -s $serial bugreport .\bugreports\
```

PowerShell-friendly PID retrieval:

```powershell
$pidValue = (adb -s $serial shell pidof com.example.app).Trim()
adb -s $serial logcat --pid=$pidValue
```

Important `dumpsys` services include `activity`, `window`, `package`, `input`, `display`, `battery`, `meminfo`, `gfxinfo`, `cpuinfo`, and `wifi`.

## 13. UI hierarchy

Android's platform UI Automator command can dump the accessibility hierarchy:

```powershell
adb -s $serial shell uiautomator dump /sdcard/window.xml
adb -s $serial pull /sdcard/window.xml .\artifacts\window.xml
```

Some Flutter, game, canvas, and WebView content may expose sparse or empty trees. Use visual perception as a fallback, not as an excuse to skip safety checks.

## 14. Port forwarding

```powershell
adb -s $serial forward tcp:8080 tcp:8080
adb -s $serial forward --list
adb -s $serial reverse tcp:3000 tcp:3000
adb -s $serial reverse --list
```

`forward` exposes a device-side endpoint through the host. `reverse` lets the device reach a host endpoint through ADB.

## 15. Wireless debugging

Modern Android versions support pairing-based wireless debugging:

```powershell
adb pair DEVICE_IP:PAIR_PORT
adb connect DEVICE_IP:ADB_PORT
adb devices -l
```

The pairing and connection ports may differ. Networks can change addresses and invalidate sessions. Do not expose legacy `adb tcpip 5555` on hostile networks.

## 16. Emulator controls

Emulators appear as serials such as `emulator-5554`. The console port is the serial's numeric suffix. Use `adb emu` for supported emulator console commands:

```powershell
adb -s emulator-5554 emu kill
```

## 17. Robust scripting pattern

```powershell
function Wait-AndroidReady {
    param([string]$Serial, [int]$TimeoutSeconds = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    adb -s $Serial wait-for-device
    while ((Get-Date) -lt $deadline) {
        $boot = (adb -s $Serial shell getprop sys.boot_completed 2>$null).Trim()
        $anim = (adb -s $Serial shell getprop init.svc.bootanim 2>$null).Trim()
        if ($boot -eq '1' -and $anim -eq 'stopped') { return }
        Start-Sleep -Seconds 2
    }
    throw "Android did not become ready: $Serial"
}
```

Serialize actions per device, attach timeouts, capture stderr, and record each command with its exit code.

## 18. Security

- Revoke unknown debugging authorizations on devices.
- Use dedicated test devices or AVDs.
- Never run model-generated `adb shell` commands without an allowlist.
- Block access to account settings, payment apps, password managers, and personal data unless explicitly authorized.
- Treat screenshots, XML dumps, clipboard data, and logs as sensitive.
- Disable USB debugging on production devices when not needed.

## 19. Troubleshooting

### Unauthorized

Unlock the device, accept the RSA prompt, or revoke USB debugging authorizations and reconnect.

### Offline

```powershell
adb kill-server
adb start-server
adb reconnect
```

Also check cable quality, USB mode, drivers, and duplicate ADB binaries.

### Emulator not listed

Verify the emulator process, Platform-Tools version, local firewall, and that the emulator uses the same SDK installation as the selected ADB.

### More than one device

Pass `-s SERIAL` everywhere.

### Context7 snapshot

See `context7-raw/android-tools-context7-snapshot.md`.
