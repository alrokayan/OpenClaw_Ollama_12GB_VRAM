# CLAUDE.md

Guidance for future Claude Code sessions working in this repository.

## What this is

Two self-contained **Windows PowerShell 5.1** scripts that install, configure,
test, and uninstall a fully-local AI agent: an Ollama-served model (`qwen3.5`)
behind the OpenClaw gateway, reachable over a Telegram bot, optionally driving
an Android emulator it can see and control. Nothing leaves the machine — the
model runs on the GPU, the phone is an AVD, the gateway binds to loopback.

There is no build, no test runner, no CI. The scripts *are* the product. They
present an interactive arrow-key menu; a human works down it. "Running" the
project means launching a script as Administrator and driving the menu.

## Files

| File | Committed | Notes |
| --- | --- | --- |
| [OpenClaw_Ollama_12GB_VRAM_Lite.ps1](OpenClaw_Ollama_12GB_VRAM_Lite.ps1) | yes | Base script **and a library** (~2360 lines). All shared logic lives here. |
| [OpenClaw_Ollama_12GB_VRAM_Full.ps1](OpenClaw_Ollama_12GB_VRAM_Full.ps1) | yes | Dot-sources Lite, adds the Android-only steps (~580 lines). |
| `README.md`, `LICENSE`, `.gitignore`, `env.example` | yes | **Generated** — see below. |
| `env` | **no** (gitignored) | Your Telegram bot token in plaintext. |
| `Tinder.xapk` | no (gitignored via `*.xapk`) | A large local test package; not part of the repo. |

## Architecture — how Lite and Full compose

Full does **not** duplicate Lite. The extension mechanism:

1. Full sets `$global:OC_EntryScript` (claims itself as the elevation target),
   flips `$global:OC_Features` (`Android`/`Mcp`/`DroidClaw` → `$true`), and sets
   `$global:OC_NoAutoStart = $true`.
2. Full **dot-sources** Lite (`. $liteLocal @PSBoundParameters`), so all of
   Lite's functions, step scriptblocks, and the menu land in Full's scope.
3. Full defines its four Android-only step scriptblocks, then calls
   `Set-MenuItem` to swap them into the shared menu **by key** (positions and
   numbering never shift — `[4]` is "Install the AVD" in both editions, just
   greyed out in Lite).
4. Full calls `Start-Menu`.

Consequences for editing:
- **Put shared logic in Lite.** Shared steps read `$Features.*` flags rather
  than being rewritten, so there is exactly one implementation of *configure
  OpenClaw*, *run the test suite*, *uninstall*, *status*.
- The canonical menu list is `$script:Items` in Lite. Full mutates it via
  `Set-MenuItem`, never rebuilds it.
- `Start-Menu`, `Show-Menu`, `Update-EnvState`, `Invoke-Step`, `Patch`,
  `Test-Case` are all in Lite.

## Features not obvious from the menu

- **Approve paired devices** (`$StepApprove` in Lite). OpenClaw writes
  `~/.openclaw/devices/paired.json` when a device pairs. A freshly paired
  device gets fewer than the four operator scopes, so it can read but not act.
  This step elevates every pending device. Rewritten in pure PowerShell (the
  old version shelled out to `jq`). Two PS 5.1 traps apply: `ConvertTo-Json`
  must use `-Depth 10`, and absent keys need `Add-Member` not assignment.
- **`.xapk` / `.obb` installer** (`$StepXapk` in Full). Handles split APKs
  via `adb install-multiple` and pushes `.obb` game assets that a plain
  `adb install` cannot handle. Uses a GUI file picker (`System.Windows.Forms`)
  with a `Read-Host` fallback. Extracts via `Expand-Archive` (requires
  renaming to `.zip`). Detects ABI mismatches (x86_64 AVD vs arm64 splits).
- **`ollama launch openclaw`** does the whole onboarding: installs OpenClaw,
  registers the gateway Scheduled Task, configures the provider, sets the
  model. Despite `--yes` being documented as headless, **it still opens the
  interactive TUI and blocks** until you exit. The script accounts for this.
- **Test suite** (`$StepSuite` in Lite). 17 checks in dependency order. Each
  layer only matters if the one below passed. The point is to separate three
  failures that look identical from a Telegram window:
  1. the model refused to call a tool
  2. no tools were ever offered to it
  3. no device was attached

  The checks, in order: adb on PATH, scrcpy on PATH, scrcpy-mcp installed
  globally, ollama daemon answering, model pulled, AVD attached, AVD finished
  booting, `openclaw.json` validates, telegram token in gateway env,
  `compat.supportsTools = true`, `num_ctx` capped, gateway reachable, model
  responds (direct), model responds (via gateway), model loaded on GPU,
  scrcpy MCP server started, droidclaw skill loaded.

## Hard invariants — break these and the scripts silently fail

- **ASCII only.** No em dashes, no box-drawing glyphs, no smart quotes anywhere
  in the source. Non-ASCII becomes mojibake in non-UTF-8 consoles and can break
  parsing. Use `--`, `+`, `-`, `|` for menus and rules.
- **Every file written to disk is UTF-8 without BOM**, via
  `[IO.File]::WriteAllText/WriteAllLines` with `New-Object Text.UTF8Encoding($false)`.
  Never use `Set-Content -Encoding utf8` (writes a BOM on PS 5.1) or `>`
  redirection (writes UTF-16LE) for files other tools parse. A BOM before a
  skill's `---` breaks YAML frontmatter and the skill silently never loads.
- **Never hand-edit `openclaw.json`.** All config changes go through
  `openclaw config patch` (via the `Patch` helper, which dry-runs first) or
  `openclaw config set --strict-json --merge`. An invalid config makes
  `openclaw doctor --fix` silently restore last-known-good and discard changes.
  `config validate` runs before `doctor` for exactly this reason.
- **`config patch` replaces arrays wholesale.** The `models` array is a
  protected path — patch it and you strip `compat.supportsTools`, after which
  the model is never offered tools and narrates shell commands as prose. Merge
  the model entry by `id` with `config set --strict-json --merge` instead.
- **`contextWindow` and `params.num_ctx` must move together.** `NumCtx` (default
  65536) is what fits a 12 GB card. `doctor --fix` raises `num_ctx` back to the
  model's advertised 262144; the script re-clamps afterward and verifies with
  `ollama ps` that it is still `100% GPU`.
- **The Telegram token goes in `~/.openclaw/.env`, not `openclaw.json`.** The
  gateway runs as a Scheduled Task and never sees your shell's environment;
  `openclaw.json` holds the literal `${TELEGRAM_BOT_TOKEN}`, resolved at load.
- **MCP `npx` on Windows** must be `command: "cmd.exe", args: ["/c","npx",...]`.
  Bare `npx` throws ENOENT (no PATHEXT for child processes); `npx.cmd` throws
  EINVAL (Node can't spawn `.cmd` directly).
- **`ConvertTo-Json` defaults to `-Depth 2`.** Deeper objects silently flatten to
  the literal string `System.Object[]`, corrupting JSON files beyond repair.
  Always use `-Depth 10` (or higher) when round-tripping `paired.json` or any
  nested config. The `$StepApprove` logic depends on this.
- **`PSCustomObject` has no indexer.** Absent keys must be created with
  `Add-Member -NotePropertyName ... -Force`, not by assignment. Assignment to a
  missing property silently succeeds on some PS versions and throws on others.
- **`skills.limits` lives at `skills.limits`, NOT `skills.load.limits`.** Wrong
  nesting makes the config invalid. `doctor --fix` then silently restores
  last-known-good and discards every patch above it. This is the same trap as
  the `openclaw.json` invariant but specific to the skill config path.
- **DroidClaw declares `requires: bins: [adb, scrcpy]`.** If either binary is
  missing from PATH, the skill is silently ineligible -- the agent never learns
  it exists, and there is no error.
- **Never use `adb wait-for-device` in a script.** It blocks forever with no
  timeout if the emulator failed to start. Poll `getprop sys.boot_completed`
  instead, with a deadline.
- **`emulator.exe` is only a launcher.** The process holding the AVD's file
  locks is `qemu-system-x86_64`. Killing `emulator.exe` does not release locks.
- **Quick boot IS snapshot loading.** You cannot disable snapshots and keep
  quick boot. `fastboot.forceColdBoot=yes` is the price of removing the
  "Bug report interrupted by snapshot load" popup.
- **The dashboard is NOT a separate install.** It is the Control UI, served by
  the gateway at `http://127.0.0.1:$GatewayPort/`. `allowInsecureAuth: true`
  must be set for the UI to authenticate over plain HTTP on loopback. The
  `-NoDashboard` switch omits the `controlUi` block entirely.
- **`localModelLean: true`** reduces the tool surface for weak local models.
  Without it, the model gets more tools than it can reliably call, and falls
  back to narrating.
- **Security: `allowFrom` gates senders, not content.** Even with a single
  allowlisted Telegram ID, any untrusted content the agent reads (web search,
  fetched pages) can carry adversarial instructions. The Control UI is an admin
  surface and must stay on loopback.

## Generated files — do not edit by hand

`README.md`, `LICENSE`, `.gitignore`, and `env.example` are produced by the
`$StepReadme` step ("Generate README.md, LICENSE, .gitignore" in the menu). It
introspects the script's own comment-based help, `$script:Items` menu table,
`$Model`/`$NumCtx`/etc. settings, and `Test-Case` names, so docs cannot drift
from code. **If you change behavior, update the generator, then regenerate** —
do not edit the output files directly (your edit will be overwritten and is a
lie about how the file is produced). The generator lives in Lite -- search for
`$StepReadme = {` to find it (line numbers shift as the script is edited).

## Parameters (both scripts, `param()` block)

`-TelegramId`, `-Model`, `-NumCtx` (range 4096-262144), `-GatewayPort`
(1024-65535), `-AvdName`, `-SysImage`, `-NoDashboard`, `-LicenseHolder`,
`-NoElevate`. Prefer overriding on the command line over editing defaults. Full
forwards its params to Lite when dot-sourcing, and re-forwards them if it
relaunches elevated.

## Working conventions

- **Match the existing house style**: heavy explanatory comments stating *why*
  (especially the non-obvious Windows/PS-5.1/OpenClaw traps), ASCII menus,
  `Write-Host` with `-ForegroundColor`, `throw` on failure with
  `$ErrorActionPreference = "Stop"`.
- **`winget install`/`uninstall` take ONE id per call** — loop, don't pass a
  list (only the first installs).
- **Don't run the scripts to "test" a change** unless the user asks and is at a
  Windows admin console — steps install system components, enable Hyper-V, write
  the registry, create Scheduled Tasks, and the uninstall path deletes
  `~/.openclaw` and `~/.android` irreversibly. Prefer reasoning and targeted
  edits; there is no safe dry-run of the whole menu.
- **Secrets**: `env` is gitignored but the pattern is `env` (not `.env`) — a
  stock `.env` rule would not match it. If asked to commit, never add `env`,
  `openclaw.json`, `paired.json`, or the `*.rejected.*/*.clobbered.*/*.bak.*`
  snapshots. The docs step warns if `env` is already git-tracked.

## Deep docs -- read on demand

The `docs/` directory contains ~8 KB developer guides for every technology in
the stack. These are NOT loaded automatically. **Read the relevant file before
modifying that subsystem.**

| When you are working on... | Read first |
|---|---|
| OpenClaw gateway, config, onboarding | `docs/01-openclawm-developer-guide.md` |
| Ollama models, Modelfiles, API, VRAM tuning | `docs/02-ollama-developer-guide.md` |
| PowerShell scripting, modules, error handling | `docs/03-powershell-developer-guide.md` |
| CMD/batch scripts, quoting, redirection | `docs/04-cmd-batch-developer-guide.md` |
| ADB commands, device communication, Wi-Fi debug | `docs/05-adb-developer-guide.md` |
| Android Studio, SDK Manager, AVD lifecycle | `docs/06-android-studio-sdk-avd-guide.md` |
| QEMU internals, emulator acceleration | `docs/07-qemu-developer-guide.md` |
| Windows 11 dev environment, Hyper-V, WSL2 | `docs/08-windows11-developer-environment.md` |
| Scrcpy mirroring, flags, recording | `docs/09-scrcpy-developer-guide.md` |
| scrcpy-mcp bridge, MCP endpoints | `docs/10-scrcpy-mcp-developer-guide.md` |
| DroidClaw skill, vision loop, plugins | `docs/11-droidclaw-developer-guide.md` |
| uiautomator2, element selectors, weditor | `docs/12-uiautomator2-developer-guide.md` |
| End-to-end integration across all tools | `docs/13-full-stack-integration-reference.md` |

Do not modify these docs without the user's explicit approval -- they were
sourced from Context7-indexed references and verified against upstream repos.

## Reference

- OpenClaw docs: https://docs.openclaw.ai
- Ollama's OpenClaw integration: https://docs.ollama.com/integrations/openclaw
- Built/debugged against OpenClaw `2026.6.11`, Windows 11, RTX 4070 (12 GB), PS 5.1.
- A clean end-to-end run on a fresh machine has **not** been verified; individual
  steps have. Treat it as a documented starting point, not a turnkey installer.

## Full Test -- trigger prompt: "start Full Test"

When the user sends **"start Full Test"**, execute the procedure below. This is
a live, destructive test run -- it installs system components, enables Hyper-V,
creates Scheduled Tasks, writes to the registry, and the uninstall step deletes
directories irreversibly. **Only run when the user explicitly triggers it and is
at a Windows Administrator console.**

### Before you begin

1. Confirm with the user: "This will run every menu option in both Lite and
   Full, including Hyper-V, Android Studio, and a full uninstall. It is
   destructive and requires Administrator. Proceed?"
2. Record the starting state:
   - `Get-Date`, `$PSVersionTable`, `whoami`, disk free on C:
   - Whether Hyper-V is already enabled
   - Whether `~/.openclaw`, `~/.android`, `~/.ollama` exist
   - GPU name and driver version
3. Create a results artifact `full_test_report.md` and update it after every
   step. Each entry must include: step name, edition (Lite/Full), pass/fail,
   wall-clock duration, stdout/stderr summary, and any anomaly.

### Phase 1 -- Lite edition (all steps)

Run `OpenClaw_Ollama_12GB_VRAM_Lite.ps1` as Administrator. Walk the menu in
order. For each step, verify preconditions, run it, and capture output.

| # | Menu key | Step | What to verify |
|---|----------|------|----------------|
| 1 | `prereqs` | Install prerequisites | winget, node, npm, npx, VCRedist all on PATH after completion. Dev mode enabled in registry. |
| 2 | `hyperv` | Enable Hyper-V | **Greyed out in Lite.** Verify it throws `$FullOnly` and does not attempt to enable anything. |
| 3 | `verify` | Verify Hyper-V | **Greyed out in Lite.** Same -- must throw, not run. |
| 4 | `android` | Install Android Studio + AVD | **Greyed out in Lite.** Same -- must throw, not run. |
| 5 | `ollama` | Install Ollama, pull qwen3.5 | Ollama binary on PATH. `ollama list` shows `qwen3.5:latest`. `ollama ps` shows 100% GPU after a warm-up query. No scrcpy-mcp install in Lite. |
| 6 | `token` | Set Telegram bot token | `env` file created in script directory. Token also written to `~/.openclaw/.env`. `openclaw.json` contains the literal `${TELEGRAM_BOT_TOKEN}`, NOT the raw token. |
| 7 | `openclaw` | Install + configure OpenClaw | `openclaw --version` works. `openclaw config validate` exits 0. `num_ctx` = `$NumCtx`. `contextWindow` = `$NumCtx`. `compat.supportsTools` = true. `localModelLean` = true. Gateway reachable at `http://127.0.0.1:$GatewayPort/`. If `$EnableDashboard`: `controlUi.allowInsecureAuth` = true. DuckDuckGo search provider set. Skills: `allowBundled` = []. No DroidClaw skill in Lite (no `~/.openclaw/skills/droidclaw/`). |
| 8 | `suite` | Run the test suite | All 17 test cases must be listed. In Lite, Android/MCP/DroidClaw checks should gracefully skip or report as expected-missing. No unhandled exceptions. |
| 9 | `agent` | Run agent tests | **Greyed out in Lite.** Must throw `$FullOnly`. |
| 0 | `xapk` | Install .xapk | **Greyed out in Lite.** Must throw `$FullOnly`. |
| - | `approve` | Approve paired devices | If no `paired.json` exists: must show "No paired.json" and not crash. If it exists: verify `-Depth 10` round-trip, no `System.Object[]` corruption, backup created with timestamp. |
| - | `status` | Status check | Must print all sections (host, virtualization, toolchain, model, device, openclaw configuration, droidclaw skill, readiness). No unhandled exceptions even when components are missing. Verify dashboard drift detection if `$EnableDashboard` differs from config. |
| - | `dashboard` | Open the dashboard | If `$EnableDashboard` and OpenClaw configured: should open `http://127.0.0.1:$GatewayPort/`. If not configured: must show correct "Why" reason. |
| - | `docs` | Generate README, LICENSE, .gitignore | All three files regenerated. README matches current menu, parameters, and test-case names. LICENSE contains `$LicenseHolder`. `.gitignore` includes `env` (not `.env`), `openclaw.json`, `paired.json`, `*.xapk`. Warn if `env` is git-tracked. |
| - | `uninstall` | Uninstall everything | **Run last.** Removes `~/.openclaw`. Prompts about `~/.ollama`. Stops the gateway Scheduled Task. Verify nothing is left behind. Check exit state is clean. |

### Phase 2 -- Full edition (all steps)

Reboot if Hyper-V was just enabled. Then run
`OpenClaw_Ollama_12GB_VRAM_Full.ps1` as Administrator.

| # | Menu key | Step | What to verify (beyond Lite) |
|---|----------|------|------------------------------|
| 1 | `prereqs` | Install prerequisites | Same as Lite PLUS: scrcpy, OpenJDK 17, FFmpeg also installed via winget. |
| 2 | `hyperv` | Enable Hyper-V + WHPX | Three leaf features enabled: `Microsoft-Hyper-V-Hypervisor`, `Microsoft-Hyper-V-Services`, `HypervisorPlatform`. Management tools NOT enabled. Reboot prompt shown. |
| 3 | `verify` | Verify Hyper-V / WHPX | `emulator -accel-check` reports WHPX. Feature table shows correct Enabled/Disabled pattern. |
| 4 | `android` | Install Android Studio + AVD | Android Studio installed. ANDROID_HOME set. `sdkmanager`, `avdmanager`, `adb`, `emulator` all on PATH. AVD `$AvdName` created. `config.ini` has: `hw.gpu.mode=swiftshader_indirect`, `hw.cpu.ncore=4`, `hw.ramSize=3072`, `disk.dataPartition.size=16G`, snapshots fully disabled (`fastboot.forceColdBoot=yes`). Emulator launches detached. Boot poll uses `getprop sys.boot_completed` (NOT `adb wait-for-device`). Analytics opted out. |
| 5 | `ollama` | Install scrcpy-mcp + Ollama | Same as Lite PLUS: `npm list -g scrcpy-mcp` confirms global install. Label reads "Install scrcpy-mcp + Ollama, pull qwen3.5". |
| 6 | `token` | Set Telegram bot token | Same as Lite. |
| 7 | `openclaw` | Install + configure OpenClaw | Same as Lite PLUS: `mcp.servers.scrcpy` configured with `command: "cmd.exe", args: ["/c","npx","scrcpy-mcp"]`. DroidClaw skill written to `~/.openclaw/skills/droidclaw/SKILL.md` -- must be UTF-8 with NO BOM. Skill declares `requires.bins: [adb, scrcpy]`. `skills.load.extraDirs` includes `~/.openclaw/skills`. `skills.limits` (NOT `skills.load.limits`) set. `openclaw skills info droidclaw` exits 0. `openclaw mcp doctor --probe` lists scrcpy tools. |
| 8 | `suite` | Run the test suite | All 17 checks must pass, including Android-specific: adb on PATH, scrcpy on PATH, scrcpy-mcp installed, AVD attached, AVD booted, scrcpy MCP server started, droidclaw skill loaded. |
| 9 | `agent` | Run the three agent tests | Three prompts sent via `openclaw agent`. Verify: (a) screenshot capture uses a real tool call not prose, (b) Home key event executes, (c) Telegram open/type/send completes. If model narrates instead of calling tools, log as a model-tier issue (not a script bug). |
| 0 | `xapk` | Install .xapk onto AVD | Test with a plain `.apk` (single install). Test with a `.xapk` containing splits (`adb install-multiple`). If `.obb` files present, verify push to `/sdcard/Android/obb/<pkg>/`. Verify ABI mismatch is caught (x86_64 AVD vs arm64-only splits). File picker opens or falls back to `Read-Host`. |
| - | `approve` | Approve paired devices | Same as Lite. Additionally verify `ConvertTo-Json -Depth 10` preserves nested token objects. |
| - | `status` | Status check | All sections green. Verify GPU row, WHPX row, scrcpy-mcp row, droidclaw skill row, dashboard drift detection. |
| - | `dashboard` | Open the dashboard | Dashboard opens at loopback URL. Gateway token printed. |
| - | `docs` | Generate README, LICENSE, .gitignore | Same as Lite. Verify Full-specific menu entries appear in generated README. |
| - | `uninstall` | Uninstall everything | Same as Lite PLUS: `~/.android` deleted (AVDs and disk images gone). Emulator process (`qemu-system-x86_64`) killed, not just `emulator.exe`. |

### Phase 3 -- Cross-edition consistency checks

After both editions have been tested:

1. **Menu numbering**: Confirm `[4]` is "Install the AVD" in both editions
   (greyed out in Lite, live in Full). No position shifts.
2. **Parameter forwarding**: Run Full with `-NumCtx 32768 -NoDashboard` and
   verify those values reach Lite's logic.
3. **Elevation forwarding**: Launch Full non-elevated and verify it relaunches
   itself elevated with all parameters intact.
4. **Encoding audit**: Scan both `.ps1` files for non-ASCII characters. There
   must be zero.
5. **Version mismatch guard**: Rename Lite to simulate it missing. Full must
   throw a clear error, not silently proceed with stale state.
6. **Generated docs freshness**: After Full's test, regenerate docs and diff
   against the previous run. They must be identical (no drift).

### Reporting

After all phases, finalize `full_test_report.md` with:

```markdown
## Summary
- Edition tested: Lite / Full / Both
- Total steps executed: N
- Passed: N
- Failed: N
- Skipped (expected): N

## Bugs Found
| # | Severity | Step | Edition | Description | Suggested Fix |
|---|----------|------|---------|-------------|---------------|
| 1 | ...      | ...  | ...     | ...         | ...           |

## Improvements Suggested
| # | Step | Edition | Description | Rationale |
|---|------|---------|-------------|-----------|
| 1 | ...  | ...     | ...         | ...       |

## Environment
- OS, PS version, GPU, VRAM, disk free, OpenClaw version, Ollama version
- Test start time, end time, total duration
```

Present the report to the user and ask whether to open issues for any bugs
found.
