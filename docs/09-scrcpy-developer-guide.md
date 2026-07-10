# scrcpy Developer Guide

> **Document ID:** `scrcpy-developer-guide`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** Context7 `/genymobile/scrcpy` and official Genymobile repository

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Architecture

scrcpy mirrors and controls Android devices without installing a permanent app. At startup, the desktop client uses ADB to push a version-matched server JAR to a temporary location and launches it with Android's `app_process`.

```text
scrcpy desktop client
  ├─ ADB bootstrap and tunnel
  ├─ video/audio decoding
  ├─ input/clipboard control
  └─ window/recording/output handling
             │
             ▼
temporary scrcpy server on Android
  ├─ display or camera capture
  ├─ media encoding
  └─ control-message execution
```

Client and server versions must match.

## 2. Installation on Windows

Recommended package-manager installation:

```powershell
winget install --exact Genymobile.scrcpy
```

Alternatives include Scoop, Chocolatey, or official release archives. Verify:

```powershell
scrcpy --version
adb version
adb devices -l
```

## 3. Basic operation

```powershell
scrcpy
scrcpy -s emulator-5554
scrcpy --select-usb
scrcpy --select-tcpip
```

Always select a serial explicitly in automation.

## 4. Video configuration

```powershell
scrcpy --video-codec=h265 --max-size=1920 --max-fps=60
scrcpy -m1600 --max-fps=30 --video-bit-rate=8M
scrcpy --no-video
```

Codec support depends on the Android device encoder and host decoder. When capture fails, list encoders and try another codec or encoder.

## 5. Audio

Audio forwarding support depends on Android version and device behavior.

```powershell
scrcpy --no-audio
scrcpy --audio-source=output
scrcpy --audio-source=mic
scrcpy --audio-codec=opus
```

Buffers trade latency for smoothness:

```powershell
scrcpy --video-buffer=50 --audio-buffer=200
```

## 6. Input modes

scrcpy supports multiple keyboard, mouse, gamepad, and control modes depending on platform and version. UHID emulates physical input devices and may behave more naturally for some apps.

```powershell
scrcpy --keyboard=uhid
scrcpy --mouse=uhid
scrcpy --gamepad=uhid
```

For an AI agent, use the control protocol or an MCP wrapper instead of driving the desktop window with host mouse automation.

## 7. Clipboard

scrcpy provides clipboard synchronization/control that works around restrictions affecting simple ADB clipboard techniques on modern Android versions. Treat clipboard contents as sensitive and clear them when tests finish.

## 8. Device power and display

```powershell
scrcpy --turn-screen-off --stay-awake
scrcpy -Sw
scrcpy --no-power-on
scrcpy --show-touches
```

The original device setting for show-touches is restored on normal exit, but forced termination may require manual cleanup.

## 9. Window control

```powershell
scrcpy --fullscreen
scrcpy --window-title='Test Device'
scrcpy --always-on-top
```

Window options affect the host UI, not Android display metrics.

## 10. Recording

```powershell
scrcpy --record=run.mp4
scrcpy --record=run.mkv
scrcpy --no-playback --record=run.mp4
```

Recording may continue without a visible window. Include timestamps and device serials in artifact filenames.

## 11. Start an app

```powershell
scrcpy --start-app=org.mozilla.firefox
scrcpy --start-app=+org.mozilla.firefox
scrcpy --start-app=?firefox
```

Prefixes can request force-stop or name search. Use package IDs for deterministic automation.

## 12. Virtual displays

scrcpy can create a new Android virtual display:

```powershell
scrcpy --new-display=1920x1080 --start-app=org.videolan.vlc
scrcpy --new-display=1920x1080/420 --start-app=com.android.settings
scrcpy --new-display --flex-display --keep-active
```

Virtual-display behavior depends on Android version and app support. Some apps assume the default display and may not launch correctly.

## 13. Camera mode

```powershell
scrcpy --list-cameras
scrcpy --video-source=camera --camera-facing=front
scrcpy --video-source=camera --camera-size=1920x1080 --camera-fps=30
```

Camera mode exposes the device camera stream; it is privacy-sensitive and may show indicators on the device.

## 14. Network connection

Typical USB-to-TCP workflow:

```powershell
adb -s $serial shell ip route
adb -s $serial tcpip 5555
adb connect DEVICE_IP:5555
scrcpy -s DEVICE_IP:5555
```

Prefer pairing-based wireless debugging on modern Android. Legacy port 5555 is unencrypted and should not be exposed on untrusted networks.

## 15. SSH tunneling

scrcpy documentation includes SSH tunnel patterns for remote ADB. ADB traffic itself is not designed as an internet-facing secure protocol. Place it inside an authenticated, encrypted tunnel and restrict the remote server.

## 16. OTG mode

```powershell
scrcpy --otg
```

OTG mode can provide keyboard/mouse control without USB debugging, but does not provide normal screen mirroring. Device and host USB support varies.

## 17. Raw server development

Developers can manually push and execute the server for protocol testing:

```powershell
adb push scrcpy-server /data/local/tmp/scrcpy-server.jar
adb forward tcp:27183 localabstract:scrcpy
adb shell CLASSPATH=/data/local/tmp/scrcpy-server.jar `
  app_process / com.genymobile.scrcpy.Server VERSION
```

The production command contains additional options and protocol setup. Pin the server version and remove stale directories at `/data/local/tmp/scrcpy-server.jar` if a previous bad push created a directory.

## 18. Multi-device orchestration

Run one session per serial and allocate unique output paths. Serialize operations per device, but different devices may be controlled concurrently.

```powershell
scrcpy -s emulator-5554 --window-title='AVD-1'
scrcpy -s emulator-5556 --window-title='AVD-2'
```

## 19. Troubleshooting

### Device not found

Run `adb devices -l`, verify authorization, cable/driver state, and selected serial.

### Black screen or encoder error

Try another codec, encoder, max size, or frame rate. Inspect scrcpy console output and Android logcat.

### Clipboard fails

Ensure a normal scrcpy control session is active and versions match.

### Screenshots or input are slow in an MCP wrapper

Start the wrapper's scrcpy session so it uses the fast protocol rather than ADB fallback.

### Version mismatch

Replace the client and server as a pair. Remove stale server files and avoid mixing package-manager and manual installations.

## 20. Security

- scrcpy provides powerful device control.
- Use only devices you own or are authorized to test.
- Do not expose ADB or scrcpy tunnels directly to public networks.
- Protect recordings and clipboard data.
- Disable or constrain shell functionality in agent wrappers.
- Require approval for messaging, purchases, account changes, deletion, or credential entry.

## 21. Context7 snapshot

See `context7-raw/scrcpy-context7-snapshot.md` for the retrieved installation, recording, virtual display, camera, networking, build, and server examples.
