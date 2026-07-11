# CLAUDE.md

Guidance for Claude Code sessions working in this repository.

## Shared vocabulary: agent response categories

When the user and this agent discuss what the **OpenClaw agent** (the bot on
Telegram) emits, use these three terms so we mean the same thing:

1. **Ack response** -- the immediate acknowledgement received right after the
   user's prompt.
2. **In-between responses** -- the streaming/thinking and processing, plus
   command outputs, from the agent itself and any subagents.
3. **Final output** -- the last message, after which the agent goes idle waiting
   for the next prompt.

If the user says a category by name (e.g. "I'm not getting the *final output*"),
scope the diagnosis to that category. A common failure with a small local model
(qwen3.5 on 12 GB) is emitting only **in-between** narration and never producing
a clean **final output** -- a model-tier behavior, not a script bug.

## What this is (one script)

There is now **one** script: [OpenClaw_Ollama_12GB_VRAM.ps1](OpenClaw_Ollama_12GB_VRAM.ps1).
It installs, configures, tests, and uninstalls a fully local AI agent that runs
on Telegram (Ollama + qwen3.5 -> OpenClaw gateway) and drives an Android emulator
via the **mobile-mcp** MCP server, guided by a device-control skill.

- The menu is `$script:Items` (18 items). `Start-Menu`, `Show-Menu`,
  `Update-EnvState`, `Invoke-Step`, `Patch`, `Test-Case`, and every step
  scriptblock live in this file.
- Android / the MCP / the device skill are always on, gated by `$Features`
  (`Android`/`Mcp`/`MobileMcpSkill`, all `$true`). This is the single switch left
  over from the old "Lite vs Full" split, which was **merged into this one file**.

**Product facts live in [README.md](README.md)** -- itself *generated from the
script*. Read it for: the pipeline, every parameter, the findings/gotchas, the
security model, the introspected menu table, and the diagnostics test suite. This
file covers only what an agent *editing the code* needs.

## Orient yourself

- **[README.md](README.md)** -- everything user-facing, plus the load-bearing
  invariants written up as "Findings, dead ends, and things that cost hours."
  When you need to know *why* a value is what it is, that section has it.
- **Comment-based help** at the top of the `.ps1` (`.SYNOPSIS` / `.DESCRIPTION`
  / `.NOTES`) -- the same "why", inline with the code.
- **Deep docs on the stack** (OpenClaw, Ollama, adb, mobile-mcp, Android SDK/AVD,
  QEMU, Windows 11 / Hyper-V, PowerShell, ...) are pulled **on demand via
  Context7**, not vendored -- see *Documentation lookups* at the bottom.

## Rules for changing code

1. **Never hand-edit the generated files** (`README.md`, `LICENSE`, `.gitignore`,
   `env.example`). They are produced by the `$StepReadme` step, which introspects
   the help, the `$script:Items` menu, the settings, and the `Test-Case` names.
   Change behavior -> **edit the generator, then regenerate** (command below). A
   hand-edit is a lie about how the file is produced and is overwritten next run.
2. **Respect the invariants in README's "Findings".** They fail *silently*:
   ASCII-only source; UTF-8-no-BOM writes via `[IO.File]::WriteAllText`; never
   hand-edit `openclaw.json`; **never pass JSON as a native-command argument** --
   Windows PowerShell 5.1 strips the embedded quotes (`openclaw.cmd` re-expands
   `%*` into node), corrupting the entry's `id`, so OpenClaw's merge-by-id
   *appends* an id-less duplicate (`--merge` is fine -- merges by id; the quoting
   is the bug, and PS 7 fixes it). Always **pipe via `--stdin`** (or `--batch-file`).
   `Set-ModelContextCap` reads + de-dupes + clamps, then writes through the
   **`Patch` helper (`config patch --stdin`)** -- the house pattern; it also
   clears the protected-path gate that a raw `config set models.*` would need
   `--replace` for, and it carries every field forward so `compat.supportsTools`
   and `input:["text","image"]` (vision) survive the array replace;
   `num_ctx`, `contextTokens`, and `contextWindow` all set equal (per-model);
   token in `~/.openclaw/.env`;
   `cmd.exe /c npx` for MCP; `ConvertTo-Json -Depth 10`; `Add-Member` for absent
   keys; `skills.limits` not `skills.load.limits`. **Re-read that section before
   editing any config-writing or file-writing code.**
3. **Match the house style**: heavy comments stating *why* (especially the
   Windows / PS-5.1 / OpenClaw traps), ASCII menus, `Write-Host -ForegroundColor`,
   `throw` on failure under `$ErrorActionPreference = "Stop"`. `winget
   install`/`uninstall` take **one** id per call -- loop, never pass a list.
4. **Do not run the installer to "test" a change.** Its steps install system
   components, enable Hyper-V, write the registry, create Scheduled Tasks, and the
   uninstall path deletes `~/.openclaw` and `~/.android` irreversibly. To
   sanity-check an edit, **parse it and load it headless** -- this runs nothing:

   ```powershell
   # parse clean + ASCII-only
   $e = $null
   [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\OpenClaw_Ollama_12GB_VRAM.ps1).Path, [ref]$null, [ref]$e)
   $b = [IO.File]::ReadAllBytes((Resolve-Path .\OpenClaw_Ollama_12GB_VRAM.ps1).Path)
   "parse errors: $($e.Count)  non-ASCII bytes: $(@($b | ? { $_ -gt 127 }).Count)"   # both 0

   # menu loads: 18 items, every Action a real scriptblock
   $global:OC_NoAutoStart = $true
   . .\OpenClaw_Ollama_12GB_VRAM.ps1
   $script:Items.Count            # 18
   $script:Items | % { $_.Key }   # prereqs hyperv verify android ollama token openclaw suite ...
   ```
5. **Logs.** Every menu step is transcribed to `./logs/` (gitignored) by
   `Invoke-Step` -- one timestamped file per run, path printed when the step ends.
   Transcripts can capture tokens echoed by `openclaw`/`adb`, so they are never
   committed.
6. **Commit after completing a task.** Stage **only** the files you changed --
   never `env`, `openclaw.json`, `paired.json`, `logs/`, or the
   `*.rejected.*`/`*.clobbered.*`/`*.bak.*` snapshots. Regenerate the docs first
   if you touched anything the README reflects. End the commit message with the
   `Co-Authored-By` trailer.

## Secrets

The token file is named `env` (no dot) -- a stock `.env` rule would miss it, so
the generated `.gitignore` lists both. Never commit `env`, `openclaw.json`
(holds a gateway token), `paired.json` (device tokens), or `logs/`. The docs step
warns if `env` is already git-tracked (`.gitignore` cannot untrack it -- the token
must then be revoked via `/revoke` in @BotFather).

## Regenerate the docs (headless)

The menu item is *"Generate README.md, LICENSE, .gitignore"*. To run it without
the interactive menu:

```powershell
$global:OC_NoAutoStart = $true
. .\OpenClaw_Ollama_12GB_VRAM.ps1
$PSCommandPath = (Resolve-Path .\OpenClaw_Ollama_12GB_VRAM.ps1)
$script:Env = @{}          # empty env -> canonical menu-table "Why" text
& $StepReadme
```

The generator reads ambient `$script:Env` and `$f`; a leaked binding changes the
output, so regenerate in a clean session.

## Automated end-to-end run (`-RunAll`, opt-in, VM only)

The script's own **`-RunAll` unattended mode** (`Start-FullTest`) walks every menu
item in order, hands-off except for the one **Android Studio setup wizard** (a GUI
with no headless entry point -- `StepAndroid` launches Studio and polls up to
45 min for the SDK to appear, then continues). It ends in the **irreversible
uninstall**, so run it **only on a throwaway / VM box**:

```powershell
.\OpenClaw_Ollama_12GB_VRAM.ps1 -RunAll -AutoXapkPath .\Tinder.xapk
```

`Start-FullTest` backs up `~/.openclaw` before it starts (and the uninstall backs
it up again), so the original token + paired devices survive a teardown;
`~/.android` (AVDs) is not backed up but is recreatable. It writes
`full_test_report.md` (gitignored, from a `finally` so it survives a mid-run
throw); per-step transcripts land in `logs/`. Enabled steps run via the
unattended-safe `Invoke-Step`; steps whose preconditions are unmet are recorded as
**expected skips**, not failures. Confirm the VM precondition with the user before
driving this from a session (a background `PowerShell` task with
`dangerouslyDisableSandbox: true` -- the sandbox blocks the installer subprocesses).

Findings from the first live `-RunAll` (all fixed; keep them from regressing):
- **Tilde path:** `openclaw config file` returns a `~`-path; `[IO.File]` APIs do
  not expand `~`, so the gateway `.env` write must expand `~`->`$Home` first.
- **`Stop` + native stderr:** under the global `$ErrorActionPreference='Stop'`,
  benign stderr from `adb`/`ollama`/`git`/`openclaw` is *fatal* (even with
  `2>$null`). Native-heavy steps set `$ErrorActionPreference='Continue'` locally
  and gate on `$LASTEXITCODE`. When adding a step that shells out, do the same.
- **Report survival:** `Start-FullTest` guards every `Update-EnvState` and writes
  the report in a `finally` -- one post-step throw used to lose the whole report.

## Documentation lookups (Context7)

Pull current, version-accurate docs for any technology in the stack **on demand**
via Context7's `find-docs` skill -- OpenClaw, Ollama, adb, mobile-mcp, Android
SDK / AVD, QEMU, Windows 11 / Hyper-V, PowerShell, and the end-to-end integration
between them.

One-time setup (installs the `find-docs` skill + rule for each agent):

```
npx ctx7 setup --claude       # Claude Code (this agent)
npx ctx7 setup --antigravity  # Antigravity / Gemini
```

Then use the `find-docs` skill to look up a subsystem **before** modifying it.
**Still verify anything load-bearing against the primary/upstream source** -- the
config-schema audit found Context7's indexed OpenClaw docs *wrong* about
`skills.limits`, and the ground truth was the binary's own `openclaw config
schema` / the Zod definitions. Indexed docs are a fast first pass, not the final
word (see README "Research").
