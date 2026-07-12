---
name: avd-management
description: "Manage Android Virtual Devices on Windows 11: discover the SDK, install images, create/configure/launch AVDs, handle snapshots, repair, and delete safely. Use for host-side AVD lifecycle, not for work inside a booted guest (see adb-shell)."
---

# AVD management on Windows 11

Manage the host-side lifecycle of Android Virtual Devices with Windows PowerShell, `sdkmanager.bat`, `avdmanager.bat`, `emulator.exe`, and `adb.exe`. For apps, UI, files, and logs inside a booted guest, use the `adb-shell` skill.

**Before any operation, read `{baseDir}/references/android-common.md`** — it defines the operating contract, safety gates, Windows-safe PowerShell rules, device selection/readiness polling, and reporting. This file covers only AVD-lifecycle commands.

## Core loop

Restate the outcome and its risk tier → resolve one SDK root and its tools → inventory AVDs/instances → confirm if the action is destructive/persistent (create with `--force`, config edits, snapshots, wipe, delete, license/package changes) → run one scoped, time-bounded action → verify observable state independently → clean up → report.

## Resolve one SDK root, Java, and AVD home

1. Prefer an SDK root supplied by the user/project. Otherwise inspect in order: `ANDROID_HOME`, deprecated `ANDROID_SDK_ROOT`, `%LOCALAPPDATA%\Android\Sdk`, resolved tools on `PATH`. If `ANDROID_HOME` and `ANDROID_SDK_ROOT` differ, stop and ask which is authoritative.
2. Resolve all tools from the same root:

   ~~~powershell
   $sdkmanager = Join-Path $sdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
   $avdmanager = Join-Path $sdkRoot 'cmdline-tools\latest\bin\avdmanager.bat'
   $emulator   = Join-Path $sdkRoot 'emulator\emulator.exe'
   $adb        = Join-Path $sdkRoot 'platform-tools\adb.exe'
   ~~~

   If `cmdline-tools\latest` is absent, choose a complete installed versioned directory — do not invent or lexically guess a path.
3. Resolve Java from `JAVA_HOME`, `Get-Command java -All`, or Android Studio's bundled `...\Android Studio\jbr\bin\java.exe` (use a process-scoped `JAVA_HOME` if correction is needed). Inspect `ANDROID_USER_HOME`, `ANDROID_EMULATOR_HOME`, `ANDROID_AVD_HOME`; the usual AVD root is `%USERPROFILE%\.android\avd` but do not assume it after overrides.
4. Verify: `& $java -version`, `& $sdkmanager --version`, `& $emulator -version`, `& $adb version`. If any tool is missing, identify its component; do not install or persist variables without authorization.

## Inventory the host, AVDs, and running instances

~~~powershell
& $sdkmanager "--sdk_root=$sdkRoot" --list_installed
& $avdmanager list device -c
& $avdmanager list avd
& $emulator -list-avds
& $emulator -accel-check
& $emulator -help-gpu
& $adb devices -l
~~~

Map every ready `emulator-*` serial to its AVD with `& $adb -s $serial emu avd name`. Use `Get-CimInstance Win32_Process` to inspect command lines when ADB can't map a stuck instance. Do not terminate anything during inventory. Record SDK root and tool versions, effective AVD root, each AVD's name/path/profile/image/config path, and running serial/port/mapped name.

Know the files: `<n>.ini` points to the AVD content dir; `<n>.avd\config.ini` is persistent config; `hardware-qemu.ini` is generated for a running instance; `userdata-qemu.img` holds guest data. Never edit pointer/config/image/userdata/snapshot files while the AVD is running.

## Verify acceleration and capacity

- Treat `emulator.exe -accel-check` as authoritative. Prefer WHPX on Windows 11 (HAXM is obsolete). Inspect the feature only when needed:

  ~~~powershell
  Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
  ~~~

- If firmware virtualization is off, instruct the user to enable Intel VT-x / AMD-V in UEFI — do not automate firmware changes. If WHPX must be enabled, explain the effect on other virtualization software (preserve WSL2, Docker Desktop, VMware), confirm/elevate, then use a scoped change and stop for the required reboot:

  ~~~powershell
  Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart
  ~~~

- Do not enable the full Hyper-V stack unless the project requires it. Check free space on SDK/AVD volumes, RAM, and Windows commit/pagefile. Leave capacity for Windows, OpenClaw, and Ollama — do not assign most host cores/RAM to one guest.

## Create an AVD

1. Validate the name (`^[A-Za-z][A-Za-z0-9._-]{0,63}$`), the device ID against `avdmanager list device -c`, and the image ID against `--list_installed`. Check collisions in both `emulator -list-avds` and the effective AVD root.
2. Do not use `--force` for a new AVD:

   ~~~powershell
   'no' | & $avdmanager create avd --name $avdName --package $systemImage --device $deviceId
   ~~~

   The piped `no` declines a **custom hardware profile** — it does not accept an SDK license. Add `--path $avdPath` only for a validated custom location. Let `avdmanager` create the content dir and pointer file; never fabricate them.
3. Verify: both listings contain the exact name, the reported content dir and `config.ini` exist and reference the intended target/image/tag/ABI, and no existing AVD was overwritten.

To select/install a system image first, see `{baseDir}/references/system-images.md`.

## Configure persistent AVD properties

Prefer Android Studio Device Manager for complex profile edits and emulator launch flags for temporary changes. To edit `config.ini`: stop every instance using the AVD, resolve the exact file from inventory, copy it to a timestamped backup and record its hash, then **patch only an allowlisted key and preserve unknown keys** — do not regenerate the file. On PS 5.1, avoid `Set-Content` defaults that introduce a BOM. Resource-sensitive keys (project choices, not defaults): `hw.ramSize`, `hw.cpu.ncore`, `disk.dataPartition.size`, `hw.gpu.enabled`/`hw.gpu.mode`, display width/height/density. Never edit `hardware-qemu.ini` as source, repoint `image.sysdir.1`, or hand-edit the pointer `.ini` (recreate or use `avdmanager move avd`). Expect these changes to invalidate snapshots — cold-boot and verify; restore the backup if the AVD can't be inventoried or booted.

## This project's verified Windows profile

When working in this repo, re-read the active script/config before acting — do not copy values from deleted historical docs or split-script stubs.

Verified baseline: SDK `%LOCALAPPDATA%\Android\Sdk`, AVD `Pixel_5`, device profile `pixel_5`, image `system-images;android-37.1;google_apis_ps16k;x86_64`, launched with `-gpu host` routed to the integrated GPU, deterministic cold boot with snapshot load/save disabled. Current profile: 4 cores, 3072 MB RAM, 16 GB data partition, 1080x2340 @ 440 dpi, no device frame. Inspect before changing these.

## Launch and correlate the serial

Start ADB first so a new serial is detected reliably (`& $adb start-server`). Choose one snapshot mode deliberately: default (load+save Quick Boot), `-no-snapshot-load` (cold-boot, allow new save), `-no-snapshot-save` (load only), `-no-snapshot` (neither). Never add `-wipe-data` as a launch-repair default. Add other flags only when justified (`-no-window`, `-no-audio`, `-no-boot-anim`, `-gpu <mode listed by -help-gpu>`, `-port <even>`).

For deterministic ports: pick an unused **even** console port in 5554–5682, reserve the adjacent ADB port, verify both free; the serial is `emulator-<console-port>`. Build an argument array and launch asynchronously; add `-WindowStyle Hidden` only for `-no-window`:

~~~powershell
$args = @('-avd', $avdName, '-port', $consolePort, '-gpu', $gpuMode, '-no-boot-anim')
$launch = Start-Process -FilePath $emulator -ArgumentList $args -PassThru
~~~

Record the requested AVD, port, launcher PID, flags, and pre-launch serial list. The QEMU worker can hold AVD locks after the launcher exits — do not assume `emulator.exe` remains the owner.

Poll `adb devices -l` every 2–5 s with a default 8-minute deadline, select only the new/expected `emulator-*` serial, and map it back with `& $adb -s $serial emu avd name`. Stop if the mapped name differs, the port belongs to another process, or the tree exits with an error. Declare ready only when: state is `device`, `sys.boot_completed=1`, `init.svc.bootanim` is stopped/absent, `pm path android` responds, `ro.kernel.qemu` confirms an emulator, and the serial still maps to the requested AVD. For visual confirmation, capture a PNG via `adb-shell` (on-device screencap + pull) and inspect pixels — a booted OS can still show a blank framebuffer. On timeout, preserve logs and report which condition failed; do not wipe, restart all ADB clients, or launch duplicates.

## Route rendering on Windows 11

1. Query supported modes with `emulator -help-gpu`; do not copy removed/legacy renderer names. Start with `auto`; test `host` when hardware rendering is required.
2. On this OpenClaw/Ollama host, preserve discrete-GPU VRAM for the model by routing **both** executables to the integrated GPU:
   - `%LOCALAPPDATA%\Android\Sdk\emulator\emulator.exe`
   - `%LOCALAPPDATA%\Android\Sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64.exe`
3. Prefer Windows Settings > System > Display > Graphics. If automating `HKCU:\Software\Microsoft\DirectX\UserGpuPreferences`, record each prior value, explain `GpuPreference=1` (power-saving/iGPU) vs `2` (high-performance/dGPU), confirm, preserve unrelated semicolon fields, and provide rollback.
4. The verified host produced blank frames with historical `swiftshader_indirect` but valid frames with `-gpu host` plus iGPU routing — do not use the historical flag. Verify rendering with a real screenshot and pixel inspection.

## Stop the exact AVD

Map the serial to the AVD, request a graceful stop with `& $adb -s $serial emu kill`, and verify the exact serial and its QEMU process disappear, locks release, and other serials are unchanged. If ADB is unavailable, inspect `Win32_Process` command lines for the exact AVD/port. Confirm before force-stopping only that tree — never broadly stop all emulator/QEMU processes.

## Situational operations

Read the matching reference when the task calls for it:
- Select and install a system image, licenses → `{baseDir}/references/system-images.md`
- Save/load/delete snapshots → `{baseDir}/references/snapshots.md`
- Move, rename, clone, run parallel instances, wipe, delete → `{baseDir}/references/avd-lifecycle.md`
- Repair in increasing-risk order and troubleshoot by symptom (incl. headless/CI) → `{baseDir}/references/repair.md`
