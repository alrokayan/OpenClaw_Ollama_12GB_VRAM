# Android Agent Developer Documentation — Index

> **Document ID:** `android-agent-docset-index`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** Context7 libraries, official project documentation, and repository documentation

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Scope

This documentation set covers the host operating system, shells, Android toolchain, emulation layer, device-control transports, UI automation frameworks, local model runtime, and agent projects needed to build an Android-operating AI system on Windows 11.

The documents are designed to be read independently, but the recommended order is:

1. Windows 11 developer environment
2. PowerShell and CMD
3. Android Studio, SDK Manager, AVD, and Android Emulator
4. ADB
5. scrcpy
6. UIAutomator2
7. Ollama
8. scrcpy-mcp or DroidClaw
9. OpenClawm packaging
10. Full-stack integration reference

## 2. Provenance and Context7 coverage

| Topic | Context7 library/source | Coverage status |
|---|---|---|
| OpenClawm | Exact repository not found in the public Context7 index | GitHub-backed developer guide for `qzc0429/openclawm` |
| Ollama | Exact official entry was not discoverable through public Context7 search | Official Ollama documentation and repository supplement |
| PowerShell | `/websites/learn_microsoft_powershell_7_7_module` | Context7-indexed official Microsoft source |
| CMD / batch | `/tboy1337/blinter` | Context7 batch-analysis supplement plus CMD language guide |
| ADB | `/websites/developer_android_tools` | Context7-indexed official Android source |
| AVD / SDK Manager / Android Studio | `/websites/developer_android_tools` and `/websites/developer_android_topic` | Curated from official Android documentation indexed by Context7 |
| QEMU | `/websites/qemu-project_gitlab_io_qemu` | Context7-indexed official QEMU documentation |
| Windows 11 | `/awesome-windows11/windows11` | Context7-indexed community source, used cautiously |
| scrcpy | `/genymobile/scrcpy` | Context7-indexed official repository |
| scrcpy-mcp | Exact repository not found in the public Context7 index | GitHub-backed guide for `JuanCF/scrcpy-mcp` |
| DroidClaw | Exact repositories not found in the public Context7 index | GitHub-backed guide, focused on `unitedbyai/droidclaw` |
| UIAutomator2 | `/appium/appium-uiautomator2-driver` | Context7-indexed source; also distinguishes OpenATX uiautomator2 |


## 3. File map

| File | Purpose |
|---|---|
| `01-openclawm-developer-guide.md` | Build, package, and distribute OpenClaw offline installers |
| `02-ollama-developer-guide.md` | Local model runtime, API, Modelfiles, Windows operation, and optimization |
| `03-powershell-developer-guide.md` | PowerShell language, process control, modules, profiles, remoting, and robust scripting |
| `04-cmd-batch-developer-guide.md` | `cmd.exe` parsing, batch files, quoting, redirection, exit codes, and linting |
| `05-adb-developer-guide.md` | Complete Android Debug Bridge architecture and command workflows |
| `06-android-studio-sdk-avd-guide.md` | Android Studio, SDK Manager, `sdkmanager`, `avdmanager`, and emulator lifecycle |
| `07-qemu-developer-guide.md` | QEMU architecture, acceleration, storage, networking, monitor, and Android relationship |
| `08-windows11-developer-environment.md` | Reproducible Windows 11 host configuration for Android and AI tooling |
| `09-scrcpy-developer-guide.md` | Display, control, recording, virtual display, camera, network, and server protocol |
| `10-scrcpy-mcp-developer-guide.md` | MCP server installation, tool groups, architecture, configuration, and extension |
| `11-droidclaw-developer-guide.md` | Autonomous Android agent architecture, setup, workflows, perception, and safety |
| `12-uiautomator2-developer-guide.md` | Appium driver, AndroidX UI Automator, and OpenATX uiautomator2 distinctions |
| `13-full-stack-integration-reference.md` | Installation order, system architecture, process supervision, testing, and security |

## 4. Reference architecture

```text
Windows 11
├─ PowerShell 7 / CMD
├─ Android Studio + Android SDK
│  ├─ platform-tools/adb
│  ├─ emulator/ (Android Emulator, QEMU-derived engine)
│  ├─ cmdline-tools/sdkmanager
│  └─ cmdline-tools/avdmanager
├─ scrcpy
│  ├─ desktop client
│  └─ temporary Android server pushed through ADB
├─ UI automation
│  ├─ Appium UiAutomator2 Driver
│  └─ OpenATX uiautomator2, when selected
├─ Ollama
│  ├─ local model runtime
│  └─ HTTP API on localhost:11434 by default
└─ Agent layer
   ├─ scrcpy-mcp
   ├─ DroidClaw
   └─ custom orchestrator
```

## 5. Versioning policy

Pin versions in production. Record at least:

- Windows build and enabled optional features
- Android Studio version
- Android SDK command-line tools version
- Platform Tools and Emulator versions
- AVD API level, ABI, image tag, and device profile
- scrcpy client/server version
- Node.js, Bun, Java, Python, Appium, and driver versions
- Ollama version and model digests
- Agent repository commit SHA

A working environment should be reproducible from a manifest, not from memory.

## 6. Security baseline

Treat ADB, scrcpy-mcp, DroidClaw, Appium, and shell tools as privileged automation interfaces. Use a dedicated test device or emulator, isolate secrets, bind network services to loopback unless remote access is intentionally secured, and log every irreversible action.
