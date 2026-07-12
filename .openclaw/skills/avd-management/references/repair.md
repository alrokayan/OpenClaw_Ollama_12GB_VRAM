# AVD — repair and troubleshooting

Loaded on demand from `avd-management/SKILL.md`. The contract and safety gates in `android-common.md` apply.

## Repair in increasing-risk order

1. Preserve stdout/stderr logs; inventory tool versions, SDK/AVD roots, image, config, disk, RAM/commit, acceleration, ports, and processes.
2. Stop only the exact instance.
3. Retry a cold boot with `-no-snapshot-load`.
4. Retry with `-no-snapshot` if Quick Boot state appears invalid.
5. Test a renderer reported by current `-help-gpu` and verify actual pixels.
6. Restore the saved `config.ini` backup.
7. Create and validate a replacement AVD under a new name.
8. Delete only a named invalid snapshot after confirmation.
9. Use `-wipe-data` only after confirmation.
10. Remove exact stale lock files only after proving no emulator/QEMU process owns that AVD.

Prefer a working replacement before deleting the original.

## Troubleshoot by symptom

- tool missing/inconsistent: resolve every tool from one SDK root.
- Java error: verify `JAVA_HOME`, `java -version`, and the Android Studio JBR.
- image not found: re-list stable packages from the same `--sdk_root` and use the exact ID.
- AVD not found: inspect effective AVD-home variables, the Windows user, and both listings.
- acceleration unavailable: inspect UEFI virtualization, WHPX state, reboot status, and `-accel-check`.
- port collision / no ADB entry: start ADB first, use a free even port pair, and map the serial.
- offline / boot timeout: inspect process and logs, disk, RAM/commit, acceleration, image, and snapshot state.
- locked AVD: identify the exact QEMU owner; never delete locks while it runs.
- blank/white display: cold-boot, inspect GPU modes/drivers/routing, and validate a screenshot before considering a wipe.
- emulator exits early: preserve logs; check documented minimum free space plus Windows pagefile/commit.
- corrupt config: restore the backup or recreate under a new name.
- invalid snapshot: cold-boot first; delete only the named snapshot after confirmation.
- shared ADB disruption: avoid `kill-server` unless exact-instance checks are exhausted and the user accepts impact.

## Headless / CI

- Pin approved tool/image versions and pre-provision licenses; never answer license prompts in an unattended turn.
- Use a job-owned AVD name/path or a process-scoped `ANDROID_AVD_HOME` with a shared read-only SDK.
- Allocate a unique even port pair, use `adb -s`, set finite deadlines, and choose `-no-window -no-audio -no-boot-anim -no-snapshot` only when clean cold state is required.
- Sanitize redirected logs, capture a screenshot on visual failures, gracefully stop the exact serial, and remove only job-owned artifacts.
- Do not expose console/gRPC ports, disable authentication, or put proxy credentials in arguments/logs.
