# scrcpy-mcp Developer Guide

> **Document ID:** `scrcpy-mcp-developer-guide`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** GitHub `JuanCF/scrcpy-mcp`; exact Context7 entry not found

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Purpose

`scrcpy-mcp` is a Model Context Protocol server that exposes Android device vision and control to MCP-compatible AI clients. The project uses scrcpy's binary protocol as the fast path and ADB as a universal fallback.

The repository describes approximately three dozen tools covering screenshots, input, applications, UI inspection, files, clipboard, shell, and video streaming. Tool count may change by release.

## 2. Architecture

```text
MCP client
  │ stdio MCP messages
  ▼
scrcpy-mcp (Node.js)
  ├─ tool schema and validation
  ├─ device/session registry
  ├─ scrcpy fast path
  │  ├─ video stream -> decoded screenshots
  │  └─ binary control protocol -> input/clipboard
  └─ ADB fallback
     ├─ screencap
     ├─ shell input
     ├─ package/activity commands
     └─ file transfer
```

## 3. Prerequisites

- Node.js 22 or the version specified by the repository;
- ADB / Android Platform-Tools;
- authorized Android device or emulator;
- optional scrcpy for low-latency input and screenshots;
- optional FFmpeg for video-stream decoding/viewing.

Verify:

```powershell
node --version
npx --version
adb version
scrcpy --version
ffmpeg -version
adb devices -l
```

## 4. Installation

Run without global installation:

```powershell
npx scrcpy-mcp
```

Or install globally:

```powershell
npm install -g scrcpy-mcp
scrcpy-mcp
```

For production, pin the package version and lock dependencies.

## 5. MCP client configuration

### Claude Code

```powershell
claude mcp add android -- npx -y scrcpy-mcp
```

### Generic `.mcp.json`

```json
{
  "mcpServers": {
    "android": {
      "command": "npx",
      "args": ["-y", "scrcpy-mcp"]
    }
  }
}
```

### Windows compatibility wrapper

Some clients behave more reliably through CMD:

```json
{
  "mcpServers": {
    "android": {
      "command": "cmd",
      "args": ["/c", "npx", "-y", "scrcpy-mcp"]
    }
  }
}
```

## 6. Environment configuration

Important settings can include:

- `ANDROID_SERIAL` — default device;
- `SCRCPY_SERVER_PATH` — exact path to a server binary/JAR;
- `SCRCPY_SERVER_VERSION` — version matching that server;
- PATH entries for ADB, scrcpy, and FFmpeg.

Example:

```json
{
  "mcpServers": {
    "android": {
      "command": "npx",
      "args": ["-y", "scrcpy-mcp"],
      "env": {
        "ANDROID_SERIAL": "emulator-5554",
        "SCRCPY_SERVER_PATH": "C:\\Tools\\scrcpy\\scrcpy-server",
        "SCRCPY_SERVER_VERSION": "4.0"
      }
    }
  }
}
```

The server path must identify the file, not its parent directory.

## 7. Session lifecycle

A typical high-performance workflow:

1. call `device_list`;
2. select an explicit serial;
3. call `start_session`;
4. verify with `device_info` and `screenshot`;
5. perform bounded actions;
6. stop video streams;
7. call `stop_session` during teardown.

Without an active scrcpy session, the server can fall back to slower ADB operations.

## 8. Tool groups

### Device management

List devices, inspect model/version/screen/battery, wake or sleep the screen, and manage rotation or system panels.

### Vision

Capture screenshots as image content, start/stop screen recording, and optionally stream video.

### Input

Tap, long-press, swipe, type text, send key events, and use clipboard functions. Input coordinates must be checked against current screen bounds.

### Applications

List, launch, stop, install, uninstall, and inspect packages. Treat install/uninstall as privileged actions.

### UI inspection

Dump the accessibility tree and find elements by text, resource ID, description, class, or related properties. Element results can supply coordinates for action.

### Shell and files

Execute shell commands and push/pull files. These are the highest-risk tools and should be disabled or constrained when not needed.

## 9. Agent operating policy

Recommended policy tiers:

- **Read-only**: screenshot, device info, UI dump, package list.
- **Reversible interaction**: tap, swipe, back, launch, text entry into non-sensitive fields.
- **Approval required**: sending messages, submitting forms, changing settings, installing apps, writing files.
- **Blocked by default**: arbitrary shell, deleting user data, account security changes, purchases, payment, credential access.

The MCP server exposes capability; the client or gateway must enforce authorization.

## 10. Performance

The project reports scrcpy-path screenshots around tens of milliseconds and ADB screenshots around hundreds of milliseconds under favorable conditions. Actual latency depends on device encoding, USB/network transport, host decoding, resolution, and agent overhead.

Measure end-to-end step time rather than relying on isolated screenshot benchmarks.

## 11. Developing the server

Typical repository workflow:

```powershell
git clone https://github.com/JuanCF/scrcpy-mcp.git
Set-Location scrcpy-mcp
npm ci
npm run build
npm test
```

Use the repository's actual scripts from `package.json`. Development areas generally include:

- MCP server registration;
- Zod or equivalent argument schemas;
- ADB adapter;
- scrcpy protocol adapter;
- screenshot decoder;
- session lifecycle;
- UI XML parser;
- integration tests.

## 12. Adding a tool

A new tool should define:

1. stable name and description;
2. strict input schema;
3. device-selection behavior;
4. timeout and cancellation;
5. bounds and permission checks;
6. normalized output;
7. ADB and/or scrcpy implementation;
8. unit and integration tests;
9. security classification.

Avoid exposing a generic command when a narrow purpose-built tool is sufficient.

## 13. Troubleshooting

### `adb` not found

Install Platform-Tools and ensure the MCP process receives the correct PATH. GUI clients may not inherit the same PATH as an interactive terminal.

### Device unauthorized

Approve the RSA prompt and confirm `adb devices` reports `device`.

### Fast session fails with `ClassNotFoundException`

Check `SCRCPY_SERVER_PATH`, remove stale `/data/local/tmp/scrcpy-server.jar`, and ensure the configured server version matches the file.

### Screenshots remain slow

Confirm `start_session` succeeded and FFmpeg/scrcpy dependencies are available.

### Clipboard fails on Android 10+

Use an active scrcpy session rather than ADB-only fallback.

### Multiple devices

Pass a serial on every request or set `ANDROID_SERIAL` for a single-device process.

## 14. Security

The server runs locally over stdio by default, which reduces network exposure but does not make tool execution safe. The connected AI client can still exercise broad device control. Use a disposable AVD, narrow tool allowlists, explicit approval gates, action logs, and maximum loop/command limits.
