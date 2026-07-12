# ADB shell — situational operations

Loaded on demand from `adb-shell/SKILL.md`. The operating contract and safety gates in `android-common.md` still apply.

## Forwarding and connectivity

Inspect mappings before changing them; create only a named, validated mapping; remove only what this task created.

~~~text
adb -s SERIAL forward --list
adb -s SERIAL reverse --list
adb -s SERIAL forward tcp:LOCAL_PORT tcp:DEVICE_PORT
adb -s SERIAL reverse tcp:DEVICE_PORT tcp:HOST_PORT
adb -s SERIAL forward --remove tcp:LOCAL_PORT
adb -s SERIAL reverse --remove tcp:DEVICE_PORT
~~~

- Validate ports as integers 1–65535 and check for collisions.
- Confirm before wireless pairing, `adb tcpip`, connecting to a network endpoint, or any change that expands access.
- Do not modify firewalls, install certificates, set a proxy/VPN, or capture network traffic unless separately requested and authorized.

## Read and change settings or permissions

Read current state first:

~~~text
adb -s SERIAL shell settings --user USER_ID get NAMESPACE KEY
adb -s SERIAL shell dumpsys package PACKAGE
adb -s SERIAL shell appops get --user USER_ID PACKAGE
~~~

For every requested change: validate all inputs → record the previous state and a rollback command → explain the exact effect and confirm → make one change → verify independently → restore temporary changes at task end.

~~~text
adb -s SERIAL shell pm grant --user USER_ID PACKAGE PERMISSION
adb -s SERIAL shell pm revoke --user USER_ID PACKAGE PERMISSION
adb -s SERIAL shell appops set --user USER_ID PACKAGE OP MODE
adb -s SERIAL shell settings --user USER_ID put NAMESPACE KEY VALUE
adb -s SERIAL shell settings --user USER_ID delete NAMESPACE KEY
adb -s SERIAL shell wm size WIDTHxHEIGHT
adb -s SERIAL shell wm density DPI
~~~

- Grant only a permission declared by the package and supported as a runtime grant; do not use `appops` as a substitute for normal permission handling.
- Route accessibility, notification-listener, device-admin, VPN, and overlay access through normal user-facing Settings — never enable them silently.
- Never change provisioning, lock-screen, verification, unknown-sources, or security settings to bypass a control.
- Roll back display overrides with `wm size reset` and `wm density reset`.

## Troubleshooting by symptom

- `adb` missing: locate Platform Tools; do not download or alter `PATH` without request.
- duplicate/server-version mismatch: inspect `adb version` and all resolved binaries; use one Platform Tools install.
- `unauthorized`: ask the user to unlock and accept the RSA prompt.
- `offline`: reconnect the transport/emulator, then `adb reconnect offline`. Use `adb kill-server` only as a last resort (it disrupts all clients).
- multiple devices: require one exact serial; never guess.
- transport ready but commands fail: wait for bounded boot completion and recheck the current user.
- `INSTALL_FAILED_VERSION_DOWNGRADE`: obtain the correct build; do not add `-d` automatically.
- `INSTALL_FAILED_UPDATE_INCOMPATIBLE`: stop for a signature mismatch; do not uninstall and lose data.
- `INSTALL_FAILED_NO_MATCHING_ABIS`: compare APK ABIs with `ro.product.cpu.abilist`.
- `INSTALL_FAILED_MISSING_SPLIT`: obtain and install the complete compatible split set.
- insufficient storage: inspect exact free space; do not delete unrelated data.
- activity `Error type 3`: resolve the current exported launch activity instead of guessing the component.
- permission denied / read-only path: choose an allowed location or report the boundary; do not escalate.
- empty logs: check PID freshness, buffer, severity, time window, and whether release logging was stripped.
- corrupt screenshot on Windows: capture on-device plus `adb pull`, never PowerShell 5.1 byte redirection.
- command/flag missing: consult the device's own help and choose a compatible non-privileged alternative.
