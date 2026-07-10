# Android Studio, SDK Manager, AVD, and Android Emulator Guide

> **Document ID:** `android-studio-sdk-avd-guide`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** Context7 `/websites/developer_android_tools` and `/websites/developer_android_topic`; official Android documentation

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Component boundaries

- **Android Studio**: IDE, project tooling, profilers, Device Manager, and SDK UI.
- **Android SDK**: packages installed under an SDK root.
- **SDK Manager**: graphical package manager in Android Studio.
- **`sdkmanager`**: command-line package manager.
- **AVD Manager / Device Manager**: graphical virtual-device manager.
- **`avdmanager`**: command-line AVD manager.
- **Android Emulator**: process that runs an AVD using a QEMU-derived virtualization engine.
- **ADB**: transport and debugging interface to the running system.

## 2. Recommended Windows layout

```text
C:\Android\Sdk\
├─ build-tools\
├─ cmdline-tools\latest\bin\
├─ emulator\
├─ licenses\
├─ platform-tools\
├─ platforms\
└─ system-images\
```

User-profile defaults are supported, but a short path simplifies automation. Avoid moving an SDK without updating environment variables and IDE settings.

Recommended variables:

```powershell
[Environment]::SetEnvironmentVariable('ANDROID_HOME', 'C:\Android\Sdk', 'User')
[Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', 'C:\Android\Sdk', 'User')
```

Add these to user PATH:

```text
C:\Android\Sdk\platform-tools
C:\Android\Sdk\emulator
C:\Android\Sdk\cmdline-tools\latest\bin
```

Some tooling prefers `ANDROID_HOME`; older tooling may inspect `ANDROID_SDK_ROOT`. Keep them consistent.

## 3. Package management

List packages:

```powershell
sdkmanager --list
```

Install a typical set:

```powershell
sdkmanager `
  'platform-tools' `
  'emulator' `
  'cmdline-tools;latest' `
  'platforms;android-36' `
  'build-tools;36.0.0' `
  'system-images;android-36;google_apis;x86_64'
```

Accept licenses in a supervised environment:

```powershell
sdkmanager --licenses
```

For CI, pre-accept only licenses approved by the organization and retain the SDK package manifest.

## 4. AVD anatomy

An AVD combines:

- device profile;
- system image/API level;
- CPU ABI;
- storage configuration;
- display size and density;
- RAM and VM heap;
- graphics mode;
- network and sensor settings;
- snapshot state;
- optional Google APIs or Play Store image.

The AVD definition and writable data are normally stored in the user's `.android\avd` directory.

## 5. Creating an AVD

List device profiles:

```powershell
avdmanager list device
```

Create:

```powershell
'no' | avdmanager create avd `
  --name Pixel_API_36 `
  --package 'system-images;android-36;google_apis;x86_64' `
  --device 'pixel_7'
```

Inspect:

```powershell
emulator -list-avds
```

Use stable, explicit names. Do not encode secrets or user identities in AVD names.

## 6. Starting the emulator

Interactive:

```powershell
emulator -avd Pixel_API_36
```

Automation-oriented:

```powershell
emulator -avd Pixel_API_36 `
  -no-boot-anim `
  -no-snapshot-save `
  -gpu auto `
  -netdelay none `
  -netspeed full
```

Headless CI:

```powershell
emulator -avd Pixel_API_36 `
  -no-window `
  -no-audio `
  -no-boot-anim `
  -no-snapshot `
  -gpu swiftshader_indirect
```

Graphics options evolve. Confirm accepted values with `emulator -help-gpu` for the installed emulator version.

## 7. Hardware acceleration on Windows 11

Modern Android Emulator configurations use Windows virtualization facilities such as Windows Hypervisor Platform. Hyper-V, WSL2, Virtual Machine Platform, Docker Desktop, and the Android Emulator may share the same virtualization stack.

Verify firmware virtualization is enabled and inspect emulator acceleration:

```powershell
emulator -accel-check
systeminfo.exe
```

Avoid obsolete HAXM instructions for modern Intel/Windows setups. Use the acceleration method supported by the installed emulator and Windows configuration.

## 8. Boot readiness

Process start does not mean Android is ready:

```powershell
$serial = 'emulator-5554'
adb -s $serial wait-for-device
while ((adb -s $serial shell getprop sys.boot_completed).Trim() -ne '1') {
    Start-Sleep 2
}
```

Also wait for package manager and launcher readiness in tests that install or launch apps immediately after boot.

## 9. Cold boot, quick boot, and snapshots

- **Cold boot**: deterministic but slower; initializes from system image and data partition.
- **Quick Boot snapshot**: faster, but can preserve unwanted state or become incompatible after updates.
- **Named snapshots**: useful for controlled test baselines when validated.

For reproducible CI, prefer a known clean data image or wipe data:

```powershell
emulator -avd Pixel_API_36 -wipe-data -no-snapshot
```

This is destructive to the AVD's writable state.

## 10. Ports and serials

The first emulator usually uses console port 5554 and ADB port 5555, appearing as `emulator-5554`. Additional instances use subsequent even console ports.

Pin a port when orchestration needs stable mapping:

```powershell
emulator -avd Pixel_API_36 -port 5560
```

Ensure the port is available and allowed by policy.

## 11. Networking

The emulator provides a virtual network. Host-loopback access from Android commonly uses the emulator-specific host alias rather than Android's own `localhost`.

Use ADB reverse for a deterministic development service path:

```powershell
adb -s emulator-5554 reverse tcp:3000 tcp:3000
```

Proxy configuration can be supplied at launch or configured inside Android. Never embed production proxy credentials in AVD files.

## 12. Storage and SD card images

The SDK includes utilities such as `mksdcard` for creating disk images. Modern tests often use emulated shared storage without a separate image, but explicit images remain useful for storage scenarios.

```powershell
mksdcard -l TestCard 1024M test-sdcard.img
```

## 13. Android Studio Device Manager

Use Device Manager for:

- creating/editing AVDs;
- selecting system images;
- cold booting or wiping data;
- viewing device files and logs;
- pairing physical devices over Wi-Fi;
- controlling snapshots.

Use command-line tools for CI and scripted repeatability. Keep the GUI and CLI pointed at the same SDK root.

## 14. JDK and Gradle

Android Studio bundles a runtime suitable for the IDE. Builds may use the embedded JDK or an explicitly configured JDK. Record:

- Gradle wrapper version;
- Android Gradle Plugin version;
- JDK version;
- compile SDK and build-tools versions.

Use the Gradle wrapper (`gradlew`) rather than a machine-global Gradle installation.

## 15. CI provisioning

A reliable image build should:

1. install command-line tools;
2. set SDK variables;
3. install pinned packages;
4. accept approved licenses;
5. create the AVD;
6. start with explicit flags;
7. wait for boot readiness;
8. install and test the app;
9. collect logcat, screenshots, and test reports;
10. terminate the emulator cleanly.

## 16. Troubleshooting

### `sdkmanager` not found

Confirm `cmdline-tools\latest\bin` exists and is on PATH. Incorrect nesting such as `cmdline-tools\cmdline-tools\bin` is common.

### Emulator is extremely slow

Run `emulator -accel-check`, enable firmware virtualization, verify Windows hypervisor features, and check whether software rendering is being used.

### AVD does not appear in `adb devices`

Ensure Platform-Tools and Emulator come from the same SDK, restart ADB, inspect emulator logs, and check local firewall/security software.

### System image missing

Install the exact package shown by `sdkmanager --list`. API level, image tag, and ABI must all match the AVD definition.

### Snapshot boot loops

Cold boot, disable snapshots, or wipe the AVD.

## 17. Context7 references

The Android Developer Tools snapshot is available at `context7-raw/android-tools-context7-snapshot.md`. It includes `sdkmanager`, AVD creation, emulator visibility, Platform-Tools, APK installation, and related examples.
