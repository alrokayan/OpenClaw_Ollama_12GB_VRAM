# OpenClaw + Ollama on 12 GB VRAM

A set of Windows PowerShell scripts that install, configure, operate, and
uninstall a fully local AI agent: an Ollama-served model behind an OpenClaw
gateway, reachable over Telegram, that drives an Android emulator (adb + device
skills). It targets a 12 GB-VRAM machine (e.g. an RTX 4070).

<https://github.com/alrokayan/OpenClaw_Ollama_12GB_VRAM>

_Generated from the scripts by `docs.ps1` on 2026-07-12. Do not edit by hand -- it is regenerated and staged on every commit._

## Disclaimer

**Run at your own risk.** These scripts install system-level components, enable
Hyper-V, write the registry, create a Scheduled Task, and the uninstall path
deletes directories irreversibly. Provided as-is, no warranty. Read before running.

- Enabling **Hyper-V** changes virtualization machine-wide. VirtualBox/VMware get
  slower; HAXM stops loading. Disabling it later breaks WSL2, Docker Desktop, and
  Windows Sandbox.
- The **uninstall** path can delete `~/.openclaw`, the Android SDK, AVDs, and
  optionally your pulled Ollama models. None of it is recoverable.
- The **Telegram bot token** is stored in plaintext in `~/.openclaw/.env`. Anyone
  who can read it can control your bot. `.gitignore` excludes it plus
  `openclaw.json` (a gateway token) and `paired.json` (device tokens).
- The agent has **shell access** and can drive a connected Android device.

## Abstract

OpenClaw bridges messaging apps to agents through a local gateway. These scripts
wire it to a locally-served Ollama model and an Android emulator, so an agent you
message on Telegram can look at a phone screen, reason about it, and tap, type,
and swipe. Everything runs on your machine: no cloud model, no data leaving the
box (web search aside, which is disabled by default here).

## Architecture

The old single script was split into focused, dot-sourced sections. `start_here.ps1`
is the entry point; it sources `common.ps1` (shared config, helpers, state checks)
and the four section scripts, then shows a 4-item top menu. Each section also runs
standalone (`powershell -File .\install.ps1`). Every menu action is a plain
function whose body is the real commands -- copy one out and run it by hand.

### The scripts

| Script | Purpose |
| --- | --- |
| `start_here.ps1` | OpenClaw + Ollama + Android. Start here. |
| `common.ps1` | shared config, helpers, and state checks. |
| `install.ps1` | [1] INSTALL. Needs Administrator (Hyper-V, DevMode, winget). |
| `run.ps1` | [2] OPERATION / run the agent. No admin needed (Auto-start on boot, |
| `fix.ps1` | [3] MAINTENANCE / fix things. No admin needed. Run standalone: |
| `uninstall.ps1` | [4] UNINSTALL. Needs Administrator (winget, Disable feature, |

## Quick start

Clone, then run the entry script (it self-elevates the steps that need admin):

```powershell
powershell -ExecutionPolicy Bypass -File .\start_here.ps1
```

Override a tunable for one run (arg > config.json > default):

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Model qwen3.5:latest -NumCtx 65536
```

## Configuration

All tunables live in **config.json** (single source of truth). Precedence is
**CLI arg > config.json > built-in default**: pass any tunable as a parameter to
`start_here.ps1` / `install.ps1` (e.g. `-Model`, `-NumCtx`) to override the file
for one run; if a key is absent from config.json the hardcoded default applies.
No prompting. `model` + `numCtx` flow into openclaw.json (the model's
context/num_ctx); the KV/keep-alive/flash-attn values become the Ollama server
env applied at `serve` start.

| Key | Default | Meaning |
| --- | --- | --- |
| `model` | `qwen3.5:latest` | Ollama model tag (also the OpenClaw provider model) |
| `numCtx` | `65536` | Context window (openclaw num_ctx/contextWindow + OLLAMA_CONTEXT_LENGTH) |
| `avd` | `Pixel_5` | Android Virtual Device name |
| `keepAlive` | `-1` | Ollama keep-alive (-1 = resident forever, 0 = unload immediately) |
| `kvCacheType` | `q8_0` | Ollama KV cache type (q8_0 halves KV VRAM) |
| `flashAttention` | `1` | Ollama flash attention (1 = on; required for quantized KV) |

### Recommended Ollama models for OpenClaw

_Source: <https://docs.ollama.com/integrations/openclaw#recommended-models>_

**Cloud:**

- `kimi-k2.5:cloud` -- Multimodal reasoning with subagents
- `qwen3.5:cloud` -- Reasoning, coding, and agentic tool use with vision
- `glm-5.1:cloud` -- Reasoning and code generation
- `minimax-m2.7:cloud` -- Fast, efficient coding and real-world productivity

**Local:**

- `gemma4` -- Reasoning and code generation locally (~16 GB VRAM)
- `qwen3.5` -- Reasoning, coding, and visual understanding locally (~11 GB VRAM)

## The menus

Auto-generated from each `Menu-*` function -- these tables cannot drift from the code.

### INSTALL  _(install.ps1)_

| # | Item |
| --- | --- |
| 1 | Enable Hyper-V + WHPX (reboot after) |
| 2 | Enable Developer Mode |
| 3 | Install Prerequisites (node/python) |
| 4 | Install Ollama + pull qwen3.5:latest |
| 5 | Install Android Studio + SDK |
| 6 | Create AVD (Pixel_5) |
| 7 | Set iGPU for the AVD (recommended) |
| 8 | Install OpenClaw |
| 9 | Configure and restart OpenClaw (openclaw.json and .env) |

### RUN / OPERATION  _(run.ps1)_

| # | Item |
| --- | --- |
| 1 | Start EVERYTHING (Ollama + gateway) |
| 2 | Stop EVERYTHING (gateway + AVD + Ollama) |
| 3 | Configure OpenClaw  (opens sub-menu ...) |
| 4 | Status |
| 5 | Clear all cache (reload model + wipe sessions) |
| 6 | Session Management  (opens sub-menu ...) |
| 7 | Approve all pending devices |
| 8 | List active skills and MCPs |
| 9 | Open Dashboard GUI |
| 10 | Open TUI |
| 11 | Restart OpenClaw Gateway |
| 12 | Service Control  (opens sub-menu ...) |
| 13 | Recommended Ollama models for OpenClaw |
| 14 | Install APK / XAPK onto the AVD |

### CONFIGURE OPENCLAW  _(run.ps1)_

| # | Item |
| --- | --- |
| 1 | Install an MCP  (you give the package) |
| 2 | Install a skill (folder picker / ClawHub ref) |
| 3 | Set / reset Telegram bot token |
| 4 | Set agent thinking level |
| 5 | Enable / disable memory |

### SERVICE CONTROL  _(run.ps1)_

| # | Item |
| --- | --- |
| 1 | Start EVERYTHING (Ollama + gateway) |
| 2 | Stop EVERYTHING (gateway + AVD + Ollama) |
| 3 | Toggle auto-start on boot  (now: ...) |
| 4 | Start Ollama |
| 5 | Stop Ollama |
| 6 | Restart Ollama |
| 7 | Start gateway |
| 8 | Stop gateway |
| 9 | Restart gateway |

### SESSION MANAGEMENT  _(run.ps1)_

| # | Item |
| --- | --- |
| 1 | List all sessions |
| 2 | Check Telegram context/token status |
| 3 | Compact Telegram session (agent:main:telegram) |
| 4 | Reset Telegram session |

### FIX / MAINTENANCE  _(fix.ps1)_

| # | Item |
| --- | --- |
| 1 | Script self-check (parse + ASCII-only) |
| 2 | OpenClaw config check (openclaw doctor) |
| 3 | Reset OpenClaw config (openclaw reset) |
| 4 | Regenerate README.md (from the scripts) |

### UNINSTALL  _(uninstall.ps1)_

| # | Item |
| --- | --- |
| 1 | Uninstall an MCP |
| 2 | Uninstall a skill |
| 3 | Uninstall Android Studio + SDK (AVD IS SAFE) |
| 4 | Uninstall OpenClaw |
| 5 | Uninstall Ollama (MODELS IS SAFE) |
| 6 | Uninstall Prerequisites (node/python/jdk) |
| 7 | Full reset OpenClaw config |
| 8 | Delete data / models / AVDs / config files (opens sub-menu ...) |
| 9 | Disable Hyper-V + WHPX |

### DELETE DATA / CONFIG (irreversible)  _(uninstall.ps1)_

| # | Item |
| --- | --- |
| 1 | Delete OpenClaw config  (~/.openclaw) |
| 2 | Delete AVD (Pixel_5) |
| 3 | Delete Ollama models    (~/.ollama, 6.6 GB) |
| 4 | Delete ALL of the above |

## Sharing the machine with games

Because the model sits resident in VRAM (`keepAlive = -1`), there are one-button
whole-stack controls for sharing the machine with games:

- **Start EVERYTHING / Stop EVERYTHING** (top of the Operation menu, and in
  Service Control): Stop kills the gateway (which also ends the AVD -- the
  emulator is its child), any straggler emulator/qemu, and the Ollama server
  (unloading the resident model) -- freeing all VRAM/CPU in one step. Start brings
  Ollama + gateway back with the tuned env.
- **Auto-start on boot** toggles a logon Scheduled Task **and** Ollama's own
  `Ollama.lnk` Startup shortcut, so turning auto-start OFF yields a genuinely
  clean boot (nothing launches). The shortcut is moved to a backup, not deleted.

## Security

- Secrets never enter git: `~/.openclaw/.env` (Telegram token), `openclaw.json`
  (gateway token), and `paired.json` (device tokens) are all gitignored. The repo
  tracks only templates (`env.example`, `openclaw.template.json`).
- OpenClaw reads **`.env`** (with the dot) -- matched by the `.env` gitignore rule.
- Exec policy is the owner's choice for a single-user box; `tools.exec` runs on the
  gateway host. Web search is disabled by default.
- Per-step transcripts land in `logs/` (gitignored) -- they can capture tokens
  echoed by `openclaw`/`adb`, so they are never committed.

## Findings, dead ends, and things that cost hours

- **ASCII-only source; UTF-8-no-BOM writes** via `[IO.File]::WriteAllText`. A BOM
  makes JSON parsers choke on the first key.
- **Never pass JSON as a native-command argument.** Windows PowerShell 5.1 strips
  the embedded quotes (`openclaw.cmd` re-expands `%*` into node), corrupting the
  entry id so OpenClaw's merge-by-id appends an id-less duplicate. Always pipe via
  `config patch --stdin`. (`config patch` MERGES objects but REPLACES arrays, and
  refuses an array-shrink that would drop an entry -- carry every model forward.)
- **`openclaw` reads `.env` with the dot** (not `env`). Verified via `config validate`.
- **`Stop` + native stderr is fatal.** Under the global `$ErrorActionPreference='Stop'`,
  benign stderr from `adb`/`ollama`/`git`/`openclaw` throws (even with `2>$null`).
  Native-heavy steps set `Continue` locally and gate on `$LASTEXITCODE`.
- **Tilde paths.** `openclaw config file` returns a `~`-path; `[IO.File]` APIs do
  not expand `~`, so expand to `$HOME` first.
- **Partial system image misdirects the download.** A `system-images\...\x86_64`
  dir that has `system.img` but no `package.xml` makes `sdkmanager` install the
  COMPLETE image to a sibling `x86_64-2`, leaving the AVD's `config.ini` pointed at
  the kernel-less `x86_64` -> emulator PANIC "missing kernel file". Install-Studio
  removes any such incomplete dir before downloading.
- **npm blocks install scripts** (allow-scripts policy), which would skip OpenClaw's
  `postinstall-bundled-plugins.mjs`. Install-OpenClaw allowlists the needed packages
  first.
- **WinForms dialogs need STA.** PowerShell 7 runs MTA, where `ShowDialog()` hangs;
  the file/folder pickers run on a dedicated STA runspace.
- **iGPU pin.** A DirectX per-app GPU preference (registry) points the emulator at
  the integrated GPU so the discrete card's VRAM stays for the model.
- **Small-model behavior.** qwen3.5 on 12 GB tends to emit in-between narration and
  never a clean final output. Thinking is off and the tool profile is lean to keep
  the prompt small and generation fast.

## Documentation lookups

Deep docs on the stack (OpenClaw, Ollama, adb, mobile skills, Android SDK/AVD,
QEMU, Windows/Hyper-V, PowerShell) are pulled on demand via Context7's `find-docs`
skill, not vendored. Verify anything load-bearing against the upstream source --
indexed docs can be wrong (the config-schema audit found `skills.limits`
misdocumented; ground truth was `openclaw config schema`).

## How these docs are generated

This file is produced by `docs.ps1`, which pulls the menu tables (AST-parsed
from every `Menu-*` function), the tunables and models (config.json), and each
script purpose (its header) from the code, and merges them with the narrative
prose maintained in `docs.ps1`. The `hooks/pre-commit` hook regenerates and
stages it on every commit, so it can never drift. Install the hook once with:

```powershell
git config core.hooksPath hooks
```

