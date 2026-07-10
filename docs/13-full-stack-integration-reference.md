# Full-Stack Integration Reference: Windows 11 + Android + Local AI Agent

> **Document ID:** `full-stack-integration-reference`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** Synthesis of the complete documentation set

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Recommended installation order

1. Update Windows 11 and GPU/USB drivers.
2. Enable required firmware and Windows virtualization features.
3. Install PowerShell 7, Git, and an approved package manager workflow.
4. Install Android Studio or command-line tools.
5. Install pinned SDK packages, Platform-Tools, Emulator, and system image.
6. Create and validate an AVD.
7. Install scrcpy.
8. Install Node.js/Bun/Java/Python as required.
9. Install Appium/UiAutomator2 or OpenATX if semantic automation is needed.
10. Install Ollama and pull pinned models.
11. Install scrcpy-mcp, DroidClaw, or the custom orchestrator.
12. Add safety policy, logs, health checks, and tests before autonomous use.

## 2. Recommended repository layout

```text
android-agent/
├─ config/
│  ├─ devices.json
│  ├─ models.json
│  ├─ policy.yaml
│  └─ logging.yaml
├─ prompts/
├─ workflows/
├─ scripts/
│  ├─ bootstrap.ps1
│  ├─ start-avd.ps1
│  ├─ health.ps1
│  └─ stop.ps1
├─ src/
│  ├─ perception/
│  ├─ planner/
│  ├─ policy/
│  ├─ executor/
│  └─ memory/
├─ tests/
├─ artifacts/            # ignored by Git
├─ logs/                 # ignored by Git
├─ .env.example
└─ README.md
```

## 3. Control-layer selection

| Requirement | Preferred layer |
|---|---|
| Device discovery, packages, shell, files, logs | ADB |
| Fast screenshot/input/clipboard/video | scrcpy |
| Semantic selectors and assertions | UiAutomator2 |
| MCP exposure to an AI client | scrcpy-mcp |
| Autonomous goal loop | DroidClaw or custom orchestrator |
| Local language/vision inference | Ollama |
| Repeatable host setup | PowerShell |
| Legacy installer compatibility | CMD/batch |

Use the narrowest capable layer. Do not use shell execution for an operation that has a safe typed API.

## 4. Process topology

```text
PowerShell supervisor
├─ Android Emulator process
├─ ADB server
├─ Ollama server
├─ optional Appium server
├─ optional scrcpy-mcp process
└─ agent process
```

Startup ordering:

1. start emulator;
2. wait for ADB transport;
3. wait for Android boot;
4. verify package manager and target app;
5. verify Ollama API/model;
6. start Appium/MCP layer;
7. start agent.

Shutdown in reverse order and collect artifacts before killing the emulator.

## 5. Device manifest

```json
{
  "serial": "emulator-5554",
  "avd": "Pixel_API_36",
  "apiLevel": 36,
  "abi": "x86_64",
  "screen": { "width": 1080, "height": 2400, "density": 420 },
  "allowedPackages": ["com.example.app"],
  "transport": "local-emulator"
}
```

Refresh dynamic fields after boot and rotation.

## 6. Model manifest

```json
{
  "runtime": "ollama",
  "runtimeVersion": "PINNED_VERSION",
  "model": "android-planner",
  "digest": "PINNED_DIGEST",
  "contextLength": 32768,
  "temperature": 0.1,
  "role": "planner"
}
```

Use separate models or configurations for vision, planning, summarization, and recovery when benchmarks justify the complexity.

## 7. Action schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["action"],
  "properties": {
    "action": {
      "enum": ["tap", "click", "swipe", "type", "key", "launch", "wait", "finish", "request_approval"]
    },
    "serial": { "type": "string" },
    "locator": { "type": "object" },
    "x": { "type": "integer", "minimum": 0 },
    "y": { "type": "integer", "minimum": 0 },
    "text": { "type": "string", "maxLength": 500 },
    "timeoutMs": { "type": "integer", "minimum": 100, "maximum": 60000 }
  },
  "additionalProperties": false
}
```

Validation order:

1. JSON syntax;
2. schema;
3. serial and package allowlist;
4. screen bounds;
5. screen-category policy;
6. action-risk classification;
7. approval requirement;
8. execution timeout.

## 8. Perception pipeline

```text
screenshot + XML + package/activity
          │
          ▼
normalizer
  ├─ rotation and dimensions
  ├─ clickable nodes
  ├─ visible text
  ├─ sensitive-screen indicators
  └─ hashes
          │
          ▼
compact state for model
```

Retain raw artifacts on disk only for the configured retention period. Send the model the minimum necessary data.

## 9. Memory strategy

Maintain four stores:

- **session facts**: device, package, user constraints;
- **active plan**: current subgoal and expected screen;
- **recent outcomes**: last few actions and state changes;
- **running summary**: compact history of completed work and unresolved issues.

Do not preserve every old screen in model history.

## 10. PowerShell bootstrap

```powershell
#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serial = 'emulator-5554'
$avd = 'Pixel_API_36'
$logRoot = Join-Path $PSScriptRoot '..\logs'
New-Item -ItemType Directory -Force $logRoot | Out-Null

$required = 'adb', 'emulator', 'scrcpy', 'ollama', 'node'
foreach ($tool in $required) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Missing required tool: $tool"
    }
}

if (-not (adb devices | Select-String $serial)) {
    Start-Process emulator -ArgumentList @('-avd', $avd, '-no-boot-anim')
}

adb -s $serial wait-for-device
$deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $deadline) {
    if ((adb -s $serial shell getprop sys.boot_completed).Trim() -eq '1') { break }
    Start-Sleep 2
}
if ((adb -s $serial shell getprop sys.boot_completed).Trim() -ne '1') {
    throw 'AVD boot timeout.'
}

Invoke-RestMethod http://localhost:11434/api/tags -TimeoutSec 5 | Out-Null
Write-Host "Ready: $serial"
```

## 11. Health gates

Before every session, verify:

- correct ADB binary;
- exactly one intended serial or explicit selection;
- Android boot complete;
- current resolution and rotation;
- target package installed;
- Ollama reachable and model present;
- MCP/Appium process healthy;
- artifact disk space;
- policy loaded;
- emergency-stop mechanism active.

## 12. Logging

Use newline-delimited JSON for machine processing:

```json
{"ts":"2026-07-10T12:00:00Z","step":4,"serial":"emulator-5554","screenHash":"abc","action":"tap","x":500,"y":900,"policy":"allow","durationMs":81}
```

Store model request IDs and latency, but redact prompts containing personal data.

## 13. Timeouts and retries

Apply independent limits to:

- ADB command;
- screenshot;
- UI selector wait;
- model request;
- action verification;
- total step;
- total session.

Retry only transient failures. Do not retry destructive operations unless the resulting state is known.

## 14. Test strategy

### Unit

- parsers;
- coordinate transforms;
- action schema;
- policy rules;
- memory compaction.

### Contract

- Ollama response parsing;
- MCP tool schemas;
- Appium capabilities;
- ADB command wrappers.

### Integration

- boot AVD;
- install app;
- capture XML and screenshot;
- tap/type/swipe;
- restart app;
- collect logs.

### End-to-end

Run representative user goals against resettable snapshots with deterministic success criteria.

## 15. Security architecture

```text
Model proposal
      │
      ▼
Schema validator
      │
      ▼
Policy engine ──► approval queue for high-risk actions
      │
      ▼
Typed executor
      │
      ▼
ADB / scrcpy / UiAutomator2
```

Mandatory controls:

- dedicated device or AVD;
- least-privileged host account;
- package allowlist;
- typed tools;
- no arbitrary shell by default;
- sensitive-screen detection;
- approval for communications and irreversible actions;
- rate and step limits;
- audit logs;
- emergency stop;
- secret redaction.

## 16. Recovery and reset

A reset hierarchy:

1. press Back;
2. close transient system panels;
3. force-stop/relaunch target app;
4. clear target app data when test policy permits;
5. restore AVD snapshot;
6. wipe/recreate AVD;
7. rebuild host environment from manifest.

Never use a deep reset without preserving diagnostic artifacts and confirming the environment is disposable.

## 17. Release checklist

- pin all runtime versions;
- export package and model manifests;
- run full test matrix;
- scan dependencies;
- verify licenses;
- review tool permissions;
- test emergency stop;
- rotate test credentials;
- publish checksums;
- document rollback.
