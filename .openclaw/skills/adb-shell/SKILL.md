---
name: adb-shell
description: "Control an already-booted Android device or emulator (AVD) over ADB: install/manage apps, drive the UI (tap/type/swipe), transfer files, capture screenshots, read logs. Use for work inside a running guest, not for AVD lifecycle (create/launch/delete)."
---

# ADB shell

Run Android Platform Tools `adb` against a booted device or emulator to do deterministic shell work, transfers, diagnostics, and UI control. Prefer a structured mobile-control tool for semantic element selection when one is available; use ADB for the gaps. For host-side AVD lifecycle (SDK/image install, create/launch/snapshot/delete), use the `avd-management` skill instead.

**Before any operation, read `{baseDir}/references/android-common.md`** — it defines the operating contract, safety gates, Windows-safe PowerShell rules, device selection/readiness polling, and reporting. This file covers only ADB-specific commands.

## Core loop

Restate the outcome and its risk tier → select one ready serial (see android-common) → inspect current state → confirm if the action is destructive/persistent/consequential → run one narrowly scoped, time-bounded action → verify through a separate query, screenshot, or state check → clean up task artifacts → report.

## Resolve ADB and identify the target

1. `adb version` — if missing, report that Platform Tools is unavailable. On Windows inspect `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe` and `Get-Command adb -All`. Do not install or change `PATH` unless requested.
2. `adb start-server`, then `adb devices -l`; select one exact serial and confirm readiness per android-common.
3. Record minimal identity once, and note emulator vs physical:

   ~~~text
   adb -s SERIAL shell getprop ro.product.manufacturer
   adb -s SERIAL shell getprop ro.product.model
   adb -s SERIAL shell getprop ro.build.version.release
   adb -s SERIAL shell getprop ro.build.version.sdk
   adb -s SERIAL shell getprop ro.product.cpu.abilist
   adb -s SERIAL shell getprop ro.kernel.qemu
   adb -s SERIAL shell am get-current-user
   ~~~

## Build commands safely (ADB specifics)

Two shells parse each remote command — the host shell first, then Android's. Prefer fixed syntax with one validated value per argument; run filtering/pipelines on the host after capturing output. Validate before use:

- package: `^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$`
- user id / PID / coordinate / duration / port: bounded decimal integers
- component: an exact value returned by the package manager, with a validated package prefix
- remote temp path: absolute, task-generated, safe characters, under `/data/local/tmp/` or `/sdcard/Download/`

Reject NULs, newlines, control characters, traversal, and shell metacharacters in values reaching the remote shell; if a value can't be represented safely, stage it in a file or use a structured tool. Commands differ by OEM/version — consult device-local help (`pm help`, `am help`, `cmd -l`, `logcat --help`) when unsure.

**Out of scope for this skill:** `adb root`, `remount`, verity/SELinux changes, `su`, recovery/bootloader/fastboot, partition writes, `dd`, `mkfs`, factory reset/wipe. Stop and explain the boundary rather than escalating.

## Inspect device state

Gather only what the task needs; filter large output on the host (e.g. for `topResumedActivity`, `mResumedActivity`, `mCurrentFocus`). Do not run an unqualified `dumpsys`.

~~~text
adb -s SERIAL shell wm size
adb -s SERIAL shell wm density
adb -s SERIAL shell dumpsys activity activities
adb -s SERIAL shell dumpsys window windows
adb -s SERIAL shell dumpsys meminfo PACKAGE
adb -s SERIAL shell df -h /data
adb -s SERIAL shell ps -A
~~~

## Manage apps

List and resolve exact packages, then launch via the resolved component:

~~~text
adb -s SERIAL shell pm list packages -3 --user USER_ID
adb -s SERIAL shell pm path --user USER_ID PACKAGE
adb -s SERIAL shell cmd package resolve-activity --brief --components --user USER_ID -a android.intent.action.MAIN -c android.intent.category.LAUNCHER PACKAGE
adb -s SERIAL shell am start -W --user USER_ID -n COMPONENT
adb -s SERIAL shell am force-stop --user USER_ID PACKAGE
~~~

Verify the `am start -W` result and resumed activity; do not use `monkey` as a launcher (it injects input).

Install from the host, not through `adb shell`:

~~~text
adb -s SERIAL install -r LOCAL_APK
adb -s SERIAL install-multiple -r BASE_APK SPLIT_APK_1 SPLIT_APK_2
~~~

- `-r` reinstalls preserving data. Do **not** add `-d` (downgrade), `-g` (grant all runtime perms), or `-t` automatically.
- For XAPK/APKS bundles, install the complete compatible split set — never an arbitrary subset.
- Verify exact package path and version after install; do not trust `Success` alone. For `INSTALL_FAILED_*` errors, see `{baseDir}/references/adb-extras.md` and diagnose the named condition — never auto-uninstall to force an install through.

Confirm before removing (prefer the scoped `--user` form):

~~~text
adb -s SERIAL shell pm clear --user USER_ID PACKAGE
adb -s SERIAL shell pm uninstall --user USER_ID PACKAGE
adb -s SERIAL uninstall PACKAGE
~~~

Do not disable, hide, or remove system packages as a troubleshooting shortcut.

## Start activities and send intents

Prefer an explicit component and current user; resolve the activity first and constrain deep links to the intended package. Use typed extras (`--es`, `--ez`, `--ei`) with validated values, and preserve host + remote quoting for a trusted data URI:

~~~text
adb -s SERIAL shell am start -W --user USER_ID -a android.intent.action.VIEW -d https://example.com PACKAGE
~~~

Treat broadcasts and service starts as higher risk: require an explicit package/component and a stated purpose. Do not send broad implicit broadcasts or security/admin/provisioning/telephony/account intents.

## Automate the UI

Inspect → act → verify, one action at a time. Confirm the screen is unlocked and on the expected app; stop at any lock or credential screen.

~~~text
adb -s SERIAL shell uiautomator dump --compressed /data/local/tmp/openclaw-ui-NONCE.xml
adb -s SERIAL pull /data/local/tmp/openclaw-ui-NONCE.xml LOCAL_XML
adb -s SERIAL shell rm -f /data/local/tmp/openclaw-ui-NONCE.xml
~~~

Derive target bounds from the hierarchy or a screenshot, validate coordinates against current `wm size`, then act with validated values:

~~~text
adb -s SERIAL shell input tap X Y
adb -s SERIAL shell input swipe X1 Y1 X2 Y2 DURATION_MS
adb -s SERIAL shell input keyevent KEYCODE_BACK
~~~

- Prefer symbolic allowlisted key codes; no rapid blind sequences, and do not repeat an action after an unexpected transition.
- Restrict `input text` to simple non-sensitive ASCII (encode spaces as `%s` after validation); Unicode/quotes/metacharacters are unreliable — use a structured text tool or ask the user to type them. **Never type secrets** (commands may be logged).
- Stop for confirmation immediately before consequential actions (send, post, buy, authorize, accept, delete). Do not bypass `FLAG_SECURE` or blocked capture surfaces.

## Transfer files

Distinguish host paths from device paths; prefer `/data/local/tmp` (temporary) and `/sdcard/Download` (user-visible). Inspect first (`ls -la`, `stat`, `df -h`), then transfer:

~~~text
adb -s SERIAL push LOCAL_PATH REMOTE_PATH
adb -s SERIAL pull REMOTE_PATH LOCAL_PATH
~~~

Confirm before overwriting user data; avoid recursive pulls until size is known; verify size and preferably SHA-256 on both sides. Never use globs for deletion. Do not read protected sandboxes, credentials, databases, media, or messages. Use `run-as PACKAGE` only for the user's debuggable app and a stated dev task — never to extract private data.

## Capture screenshots and recordings

On Windows PowerShell 5.1, do **not** use `adb exec-out screencap -p > file.png` — native binary redirection corrupts PNG bytes. Capture on-device and pull, on every host for consistency:

~~~text
adb -s SERIAL shell screencap -p /data/local/tmp/openclaw-screen-NONCE.png
adb -s SERIAL pull /data/local/tmp/openclaw-screen-NONCE.png LOCAL_PNG
adb -s SERIAL shell rm -f /data/local/tmp/openclaw-screen-NONCE.png
~~~

Verify a non-empty file and the PNG signature before claiming success; remove the remote file only after a successful pull. For a bounded recording use `screenrecord --time-limit SECONDS` to a device path, then pull. Treat captures as sensitive — do not capture unrelated notifications or accounts.

## Collect logs

Default to bounded snapshots; do not leave `logcat` streaming, and do not run `logcat -c` without confirmation (it destroys history).

~~~text
adb -s SERIAL logcat -d -t 500 -v threadtime
adb -s SERIAL logcat -b crash -d -t 200 -v threadtime
adb -s SERIAL shell pidof PACKAGE
adb -s SERIAL logcat --pid=PID -d -t 500 -v threadtime
~~~

Re-resolve the PID after every app restart; filter by PID/tag/severity/time window/buffer; redact tokens, accounts, and messages before reporting. Treat `adb bugreport` as a large, privacy-sensitive collection — explain scope, confirm, set a finite timeout, and do not transmit unless requested. Query a specific service with `dumpsys -t 10 SERVICE`.

## Situational operations

For port forwarding/connectivity, reading and changing settings or permissions, and the full error-code troubleshooting table, read `{baseDir}/references/adb-extras.md`.
