# Windows 11 Developer Environment for Android Automation and Local AI

> **Document ID:** `windows11-android-ai-environment`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** Microsoft platform behavior plus Context7 `/awesome-windows11/windows11` community snapshot

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Design goals

A reliable host should be:

- reproducible;
- isolated from personal data;
- virtualization-ready;
- observable;
- easy to reset;
- explicit about PATH and tool versions;
- resistant to accidental privilege escalation.

Use a dedicated Windows account or workstation for autonomous device agents.

## 2. Baseline inventory

Record:

```powershell
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber
$PSVersionTable
systeminfo.exe
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, VirtualizationFirmwareEnabled
Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion
```

Also record GPU runtime versions, available RAM/VRAM, free disk space, and USB controller/driver information.

## 3. Package installation

Use a package manager where packages are trustworthy and pinned when needed:

```powershell
winget install --exact Git.Git
winget install --exact Microsoft.PowerShell
winget install --exact Genymobile.scrcpy
```

Android Studio, Ollama, Node.js, Java, Python, Bun, and other tools may also be installed through approved distribution channels. Verify publisher and package identifiers before automation.

## 4. Directory strategy

```text
C:\Dev\                     # source repositories
C:\Android\Sdk\             # Android SDK
D:\Models\                  # optional large Ollama model store
D:\AVD\                     # optional AVD storage
C:\DevTools\logs\          # service logs
C:\DevTools\artifacts\     # screenshots, reports, recordings
```

Use NTFS volumes with adequate free space. Model files, system images, emulator snapshots, recordings, and Gradle caches grow quickly.

## 5. Environment variables

Manage user-level values intentionally:

```powershell
[Environment]::SetEnvironmentVariable('ANDROID_HOME', 'C:\Android\Sdk', 'User')
[Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', 'C:\Android\Sdk', 'User')
[Environment]::SetEnvironmentVariable('OLLAMA_MODELS', 'D:\Models\Ollama', 'User')
```

Avoid machine-wide changes unless all users require them. Restart applications after changing their environment.

## 6. Virtualization features

Android Emulator, WSL2, Hyper-V workloads, and containers depend on hardware virtualization. Enable only the Windows features required by the selected architecture, commonly including Windows Hypervisor Platform and Virtual Machine Platform.

Check:

```powershell
Get-WindowsOptionalFeature -Online |
  Where-Object FeatureName -match 'Hyper|VirtualMachine|Subsystem-Linux'
```

Changing optional features may require elevation and reboot. Document the final state.

## 7. Developer Mode

Windows Developer Mode can simplify development tasks such as local app deployment and symbolic links. Enable it only when required by the workflow and organizational policy.

## 8. USB and Android drivers

For physical devices:

- use a data-capable USB cable;
- install the OEM or Google USB driver when necessary;
- inspect Device Manager for warnings;
- avoid untrusted driver packages;
- approve the host RSA fingerprint on the device;
- use a stable USB port for long runs.

## 9. Firewall

Local services in this stack may include:

- ADB server on host port 5037;
- Ollama on 11434;
- emulator console/ADB ports;
- development web servers;
- optional MCP or video endpoints.

Keep services on loopback unless remote access is intentional. Create narrowly scoped firewall rules by program, port, profile, and remote address.

## 10. Microsoft Defender and exclusions

Do not globally disable Defender. If build or model directories create measurable performance problems, use the smallest approved exclusion and exclude only data that is already trusted. Never exclude download, temp, or arbitrary payload directories.

The included Context7 Windows 11 snapshot contains community tweak commands, including security-sensitive registry changes. They are reference material, not recommended baseline actions.

## 11. Power and sleep

Long emulator or model runs may fail when the host sleeps. Configure a dedicated power plan or use a supervised keep-awake mechanism during active jobs. Restore normal power policy afterward.

## 12. Long paths and developer tooling

Some build trees exceed legacy path limits. Enable long-path support only through approved policy and keep project roots short. Git also has its own long-path configuration.

## 13. Windows Terminal and shells

Use Windows Terminal profiles for PowerShell 7, CMD, WSL, and specialized build shells. A terminal profile is presentation configuration; scripts should invoke the required executable directly.

## 14. Services and process supervision

For persistent agents, use a proper supervisor rather than a permanently open terminal. Requirements:

- restart policy;
- working directory;
- environment file;
- stdout/stderr capture;
- health checks;
- graceful shutdown;
- least-privileged account;
- startup ordering.

Do not run an Android-control agent as LocalSystem.

## 15. Secrets

Store API keys in a secret manager or protected user-level storage. Do not place keys in:

- Git repositories;
- batch files;
- screenshots;
- generated MCP configuration committed to source;
- command lines visible to other processes;
- model prompts or logs.

## 16. Update policy

Separate update rings:

- stable host OS updates;
- Android SDK and emulator updates;
- scrcpy updates;
- Node/Bun/Java/Python runtime updates;
- agent dependency updates;
- Ollama runtime and model updates.

Test updates against a disposable AVD before changing the production automation environment.

## 17. Backup and recovery

Back up source, configuration templates, manifests, and test fixtures. Recreate SDK packages and models from pinned manifests rather than backing up every cache. Treat AVD snapshots as disposable unless they contain a documented test baseline.

## 18. Health-check script

```powershell
$checks = [ordered]@{}
$checks.Windows = (Get-ComputerInfo).OsBuildNumber
$checks.PowerShell = $PSVersionTable.PSVersion.ToString()
$checks.Adb = (& adb version | Select-Object -First 1)
$checks.Scrcpy = (& scrcpy --version | Select-Object -First 1)
$checks.Ollama = (& ollama --version)
$checks.Devices = (& adb devices -l) -join "`n"
$checks.OllamaApi = try {
    (Invoke-RestMethod http://localhost:11434/api/tags -TimeoutSec 3).models.Count
} catch { "ERROR: $($_.Exception.Message)" }

$checks | ConvertTo-Json -Depth 4 | Set-Content .\host-health.json -Encoding utf8
```

## 19. Context7 snapshot

See `context7-raw/windows11-context7-snapshot.md`. Review community tweaks carefully; do not apply registry or security changes without independent validation and rollback planning.
