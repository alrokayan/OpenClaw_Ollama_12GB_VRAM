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

## Generated files — do not edit by hand

`README.md`, `LICENSE`, `.gitignore`, and `env.example` are produced by the
`$StepReadme` step ("Generate README.md, LICENSE, .gitignore" in the menu). It
introspects the script's own comment-based help, `$script:Items` menu table,
`$Model`/`$NumCtx`/etc. settings, and `Test-Case` names, so docs cannot drift
from code. **If you change behavior, update the generator, then regenerate** —
do not edit the output files directly (your edit will be overwritten and is a
lie about how the file is produced). The generator lives in Lite around
[the `$StepReadme` block](OpenClaw_Ollama_12GB_VRAM_Lite.ps1#L1153).

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

## Reference

- OpenClaw docs: https://docs.openclaw.ai
- Ollama's OpenClaw integration: https://docs.ollama.com/integrations/openclaw
- Built/debugged against OpenClaw `2026.6.11`, Windows 11, RTX 4070 (12 GB), PS 5.1.
- A clean end-to-end run on a fresh machine has **not** been verified; individual
  steps have. Treat it as a documented starting point, not a turnkey installer.
