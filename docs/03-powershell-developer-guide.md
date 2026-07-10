# PowerShell Developer Guide

> **Document ID:** `powershell-developer-guide`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** Context7 `/websites/learn_microsoft_powershell_7_7_module` and Microsoft PowerShell documentation

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. PowerShell editions

Windows 11 commonly includes Windows PowerShell 5.1 as `powershell.exe`. Modern cross-platform PowerShell is installed separately and runs as `pwsh.exe`.

```powershell
$PSVersionTable
(Get-Command powershell).Source
(Get-Command pwsh -ErrorAction SilentlyContinue).Source
```

Prefer PowerShell 7 for new automation unless a Windows-only module requires 5.1.

## 2. Object pipeline

PowerShell passes .NET objects through pipelines rather than plain text.

```powershell
Get-Process |
  Where-Object CPU -gt 10 |
  Sort-Object CPU -Descending |
  Select-Object -First 10 Name, Id, CPU
```

Use structured properties as long as possible. Convert to text only at display or interoperability boundaries.

## 3. Discovery

```powershell
Get-Command *Process*
Get-Help Start-Process -Full
Get-Member -InputObject (Get-Process | Select-Object -First 1)
```

A robust script should discover executable paths with `Get-Command` rather than assuming PATH layout.

## 4. Profiles

PowerShell exposes profile paths through `$PROFILE`:

```powershell
$PROFILE | Select-Object *
Test-Path $PROFILE
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}
notepad $PROFILE
```

For deterministic automation, start without profiles:

```powershell
pwsh -NoProfile -File .\script.ps1
```

Profiles are useful for interactive aliases and prompt customization, but production scripts must not depend on them.

## 5. Variables and scope

```powershell
$localValue = 1
$script:SharedValue = 2
$env:ANDROID_SERIAL = 'emulator-5554'
```

Use `$env:NAME` for child-process environment variables. Use `[Environment]::SetEnvironmentVariable()` to persist values.

## 6. Arrays, maps, and custom objects

```powershell
$devices = @('emulator-5554', 'R58M123456A')
$config = @{
    AdbPath = 'C:\Android\platform-tools\adb.exe'
    TimeoutSeconds = 30
}
$result = [pscustomobject]@{
    Serial = $devices[0]
    State  = 'device'
}
```

Use ordered maps when output order is meaningful:

```powershell
[ordered]@{ name = 'tap'; x = 500; y = 900 }
```

## 7. Functions

```powershell
function Invoke-Adb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Serial,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [int] $TimeoutSeconds = 30
    )

    $adb = (Get-Command adb -ErrorAction Stop).Source
    & $adb -s $Serial @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "adb failed with exit code $LASTEXITCODE"
    }
}
```

Use advanced functions, typed parameters, validation attributes, and explicit output contracts for reusable tooling.

## 8. Error handling

PowerShell distinguishes terminating and non-terminating errors. For predictable behavior:

```powershell
$ErrorActionPreference = 'Stop'
try {
    Invoke-RestMethod http://localhost:11434/api/tags -TimeoutSec 5
}
catch {
    Write-Error "Ollama health check failed: $($_.Exception.Message)"
    exit 1
}
finally {
    # cleanup
}
```

Inside functions, prefer `throw` for contract violations. At process boundaries, check `$LASTEXITCODE`.

## 9. Native process invocation

Argument handling is safer when arguments are passed as an array:

```powershell
$arguments = @('-s', 'emulator-5554', 'shell', 'wm', 'size')
& adb @arguments
```

For detached or redirected processes:

```powershell
$process = Start-Process `
  -FilePath 'ollama.exe' `
  -ArgumentList @('serve') `
  -PassThru `
  -RedirectStandardOutput '.\logs\ollama.out.log' `
  -RedirectStandardError '.\logs\ollama.err.log'
```

Avoid building a single command string and passing it to `Invoke-Expression`.

## 10. JSON and REST

```powershell
$payload = [ordered]@{
  model = 'gemma4'
  messages = @(@{ role = 'user'; content = 'Return JSON.' })
  stream = $false
}

$json = $payload | ConvertTo-Json -Depth 10
$response = Invoke-RestMethod `
  -Method Post `
  -Uri 'http://localhost:11434/api/chat' `
  -ContentType 'application/json' `
  -Body $json
```

Always set adequate `-Depth` for nested JSON. Validate output before using it as an action.

## 11. Files and paths

```powershell
$root = Join-Path $PSScriptRoot '..'
$resolved = Resolve-Path $root
New-Item -ItemType Directory -Force -Path (Join-Path $root 'logs') | Out-Null
```

Use `Join-Path`, `Resolve-Path`, and `-LiteralPath`. Do not assume the current working directory equals the script directory.

## 12. Modules

A module layout:

```text
AndroidAgentTools/
├─ AndroidAgentTools.psd1
├─ AndroidAgentTools.psm1
├─ Public/
└─ Private/
```

Export only the public API. Pin required modules in CI and sign production scripts when organizational policy requires it.

## 13. Remoting

PowerShell remoting is powerful and should be explicitly secured. Use approved authentication, constrained endpoints, least privilege, and firewall restrictions. Profiles are not automatically loaded in every remote context.

```powershell
$s = New-PSSession -ComputerName BuildHost
Invoke-Command -Session $s -ScriptBlock { $PSVersionTable.PSVersion }
Remove-PSSession $s
```

## 14. Jobs and parallel execution

Use jobs or parallel execution only when external tools support concurrency safely. Multiple ADB commands against the same device may race.

```powershell
1..4 | ForEach-Object -Parallel {
    # independent work only
} -ThrottleLimit 2
```

For one device, use a serialized command queue.

## 15. Script quality

Recommended preamble:

```powershell
#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
```

Quality controls:

- PSScriptAnalyzer
- Pester tests
- comment-based help
- typed parameters
- no hidden dependency on profiles
- explicit exit codes
- structured logs
- idempotent operations

## 16. Execution policy

Execution policy is a safety feature, not a security boundary. Avoid globally weakening it. Prefer signed scripts or process-scoped invocation when appropriate:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\trusted-ci-script.ps1
```

Use the narrowest scope and only for trusted code.

## 17. Android stack bootstrap pattern

```powershell
$required = 'adb', 'scrcpy', 'ollama', 'node', 'java'
$missing = foreach ($name in $required) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { $name }
}
if ($missing) {
    throw "Missing tools: $($missing -join ', ')"
}

adb start-server | Out-Null
$devices = adb devices
Invoke-RestMethod http://localhost:11434/api/tags -TimeoutSec 5 | Out-Null
Write-Host 'Environment ready.'
```

## 18. Context7 snapshot

See `context7-raw/powershell-context7-snapshot.md` for the retrieved PowerShell Core profile examples.
