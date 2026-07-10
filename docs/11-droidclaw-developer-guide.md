# DroidClaw Developer Guide

> **Document ID:** `droidclaw-developer-guide`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** GitHub `unitedbyai/droidclaw` with a comparison appendix for `finettt/DroidClaw`; exact Context7 entries not found

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Name ambiguity

Two public projects use the DroidClaw name:

1. `unitedbyai/droidclaw` — a host-side autonomous Android agent that reads the screen, plans, and acts through ADB.
2. `finettt/DroidClaw` — a native Android/Java personal assistant inspired by OpenClaw, with an embedded Python environment.

This guide focuses on the first project because it is the Android-control developer stack most closely related to ADB, screenshots, accessibility, workflows, and external model providers.

## 2. Agent-loop architecture

```text
User goal
   │
   ▼
Kernel / orchestrator
   ├─ capture accessibility tree
   ├─ capture screenshot when required
   ├─ normalize device state
   ├─ build model prompt
   ├─ request next action
   ├─ validate action
   ├─ execute through ADB
   ├─ compare new state
   └─ detect completion, failure, or loops
```

A strong architecture separates perception, reasoning, policy, execution, and memory. Do not merge model output directly into ADB execution.

## 3. Prerequisites

Typical requirements:

- Bun runtime;
- ADB / Platform-Tools;
- Android device with USB debugging or authorized network ADB;
- model-provider credentials or local-model configuration;
- optional vision-capable model;
- isolated `.env` file;
- dedicated test device or emulator.

Verify:

```powershell
bun --version
adb version
adb devices -l
```

## 4. Installation

```powershell
git clone https://github.com/unitedbyai/droidclaw.git
Set-Location droidclaw
bun install
Copy-Item .env.example .env
```

Review every environment variable before running. Do not use fake or production credentials interchangeably; test error handling with a deliberately invalid key in an isolated phase, then remove it.

## 5. Running

Interactive goal mode:

```powershell
bun run src/kernel.ts
```

Workflow mode:

```powershell
bun run src/kernel.ts --workflow .\workflows\task.json
```

Deterministic flow mode:

```powershell
bun run src/kernel.ts --flow .\flows\task.yaml
```

Build and type-check:

```powershell
bun run build
bun run typecheck
```

Use the repository's current scripts as source of truth.

## 6. Configuration domains

A typical configuration covers:

- provider and model;
- API base URL and key;
- target device serial;
- ADB path;
- vision mode;
- maximum steps;
- screenshot policy;
- action timeout;
- stuck-detection threshold;
- logging and artifact directories;
- allowed packages/actions.

For local inference, point the provider adapter to Ollama's API only if the selected integration supports the protocol expected by the project.

## 7. Perception strategy

### Accessibility-first

Use UI hierarchy data when it is complete. It provides text, resource IDs, bounds, enabled state, class names, and content descriptions at lower token cost than screenshots.

### Vision fallback

Some Flutter, WebView, game, canvas, and custom-rendered UIs expose little accessibility information. A vision mode such as `VISION_MODE=always` can force screenshot reasoning.

### Hybrid policy

Recommended:

1. obtain UI tree;
2. compute a tree-quality score;
3. capture screenshot when tree is empty, stale, ambiguous, or action-critical;
4. fuse both representations;
5. preserve only a compact state summary in history.

## 8. Action model

Use a closed action schema, for example:

```json
{
  "action": "tap",
  "target": {
    "strategy": "resource_id",
    "value": "com.example:id/continue"
  },
  "fallback": { "x": 540, "y": 1700 },
  "reason": "Advance to the confirmation screen"
}
```

Supported actions should be explicit: tap, long press, swipe, type, key event, launch app, wait, finish, or request approval. Generic shell should be outside the normal planner schema.

## 9. Coordinate handling

At startup, detect:

```powershell
adb shell wm size
adb shell wm density
adb shell dumpsys display
```

Normalize coordinates against the actual screenshot dimensions. Account for rotation, status/navigation bars, display cutouts, and scaled screenshots. Re-detect after orientation or display changes.

## 10. Stuck detection

Detect loops using multiple signals:

- identical screenshot or perceptual hash;
- unchanged XML hash;
- repeated action signature;
- repeated model rationale;
- no navigation-state change;
- recurring error text;
- step limit.

Recovery ladder:

1. wait once for asynchronous UI;
2. refresh perception;
3. try a semantic alternative;
4. press Back when reversible;
5. relaunch the target app;
6. request human guidance;
7. stop safely.

Never keep repeating taps indefinitely.

## 11. Workflows versus autonomous goals

- **Autonomous goal**: model decides each step; flexible but less predictable.
- **Workflow**: structured sequence with checkpoints and branching.
- **Deterministic flow**: predefined selectors/actions; best for stable repetitive tasks.

Use deterministic flows for installation, health checks, and known test cases. Reserve autonomous mode for variable UI or exploratory tasks.

## 12. Memory

Keep:

- user goal and constraints;
- active plan;
- current package/activity;
- latest normalized screen state;
- unresolved facts;
- recent action outcomes;
- compact long-term summary.

Discard stale screenshots and full XML dumps from prompt history after extracting relevant facts.

## 13. Safety policy

Minimum guardrails:

- package allowlist;
- screen-category classifier;
- coordinate bounds;
- text-length limits;
- confirmation before send/submit/purchase/delete;
- block password, OTP, banking, and account-security screens by default;
- shell-command allowlist;
- maximum steps and maximum identical actions;
- complete action audit trail;
- emergency stop.

## 14. Observability

Per step, log:

```text
timestamp
session ID
step number
device serial
package/activity
screen hash
perception source
model and latency
action proposal
policy decision
executed command
exit code
resulting state hash
```

Redact user text, contacts, credentials, tokens, and screenshots according to policy.

## 15. Testing

Test perception and action layers separately:

- XML parser fixtures;
- screenshot-resolution fixtures;
- action JSON schema tests;
- bounds tests;
- provider timeouts and malformed responses;
- unauthorized/offline device states;
- empty accessibility tree;
- repeated-screen recovery;
- app crash and relaunch;
- network interruption;
- max-step termination.

Run end-to-end tests on disposable AVD snapshots.

## 16. Troubleshooting

### `adb: command not found`

Install Platform-Tools, update PATH, or set the configured ADB path.

### No devices

Enable USB debugging, approve the host, verify the cable, or connect the intended emulator/network transport.

### Empty accessibility tree

Switch to screenshot vision, inspect whether the app is Flutter/WebView/game-based, and avoid assuming the screen is blank.

### Swipe coordinates are wrong

Verify screen resolution, rotation, screenshot scaling, and coordinate transformation.

### Repeated action loop

Inspect hashes and action history, reduce model temperature, strengthen the action schema, and trigger the recovery ladder earlier.

## 17. Remote ADB

The repository documents remote use through private networking such as Tailscale. Remote ADB is highly privileged. Use authenticated private networking, device-specific firewall rules, key rotation, and no public port exposure.

## 18. Native `finettt/DroidClaw` appendix

The native project runs on Android without root, is primarily Java, bundles Python 3.11, and supports multiple model-provider APIs. Developer setup recommends Java 21 and Python 3.11 or Nix. It is a different architecture: the assistant executes inside its own Android application sandbox rather than controlling the entire phone from a host ADB loop.
