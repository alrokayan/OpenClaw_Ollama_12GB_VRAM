# CLAUDE.md

Guidance for Claude Code sessions working in this repository.

## Shared vocabulary: agent response categories

When the user and this agent discuss what the **OpenClaw agent** (the bot on
Telegram) emits, use these three terms so we mean the same thing:

1. **Ack response** — the immediate acknowledgement received right after the
   user's prompt.
2. **In-between responses** — the streaming/thinking and processing, plus
   command outputs, from the agent itself and any subagents.
3. **Final output** — the last message, after which the agent goes idle waiting
   for the next prompt.

If the user says a category by name (e.g. "I'm not getting the *final output*"),
scope the diagnosis to that category. A common failure with a small local model
(qwen3.5 on 12 GB) is emitting only **in-between** narration and never producing
a clean **final output** — a model-tier behavior, not a script bug.

**Product facts live in [README.md](README.md)** — which is itself *generated from
the scripts*. Read it first for: what the project is, the two editions, the
pipeline diagram, every parameter, the full findings/gotchas list, the security
model, the introspected menu table, and the 17-check test suite. This file does
**not** restate any of that. It covers only what an agent *editing the code*
needs and that README does not say.

## Orient yourself

- **[README.md](README.md)** — everything user-facing, plus the load-bearing
  invariants written up as narrative "Findings, dead ends, and things that cost
  hours." When you need to know *why* a value is what it is, that section has it.
- **Comment-based help** at the top of each `.ps1` (`.SYNOPSIS` / `.DESCRIPTION`
  / `.NOTES`) — the same "why", inline with the code.
- **Deep docs on the stack** (OpenClaw, Ollama, adb, scrcpy, Android SDK/AVD,
  QEMU, PowerShell, …) are pulled **on demand via Context7**, not vendored — see
  *Documentation lookups* at the bottom. (The old `docs/` folder was removed.)

## How the two scripts compose (the editing model)

[OpenClaw_Ollama_12GB_VRAM_Lite.ps1](OpenClaw_Ollama_12GB_VRAM_Lite.ps1) is the
base script **and a library**. [OpenClaw_Ollama_12GB_VRAM_Full.ps1](OpenClaw_Ollama_12GB_VRAM_Full.ps1)
does not duplicate it — it sets `$global:OC_Features` (`Android`/`Mcp`/`DroidClaw`)
and `$global:OC_NoAutoStart = $true`, **dot-sources Lite**, defines its four
Android-only step scriptblocks, swaps them into the shared menu **by key** with
`Set-MenuItem`, then calls `Start-Menu`. Consequences when you edit:

- **Put shared logic in Lite.** Shared steps branch on `$Features.*` rather than
  being rewritten, so there is exactly one implementation of *configure
  OpenClaw*, *run the test suite*, *uninstall*, *status*.
- The canonical menu is `$script:Items` in Lite (15 items). Full mutates entries
  via `Set-MenuItem`; it never rebuilds the list, so numbering never shifts —
  `[4]` is "Install the AVD" in both editions, greyed out in Lite.
- `Start-Menu`, `Show-Menu`, `Update-EnvState`, `Invoke-Step`, `Patch`,
  `Test-Case`, and every non-Android step live in Lite.

## Rules for changing code

1. **Never hand-edit the generated files** (`README.md`, `LICENSE`, `.gitignore`,
   `env.example`). They are produced by the `$StepReadme` step in Lite, which
   introspects the help, the `$script:Items` menu, the settings, and the
   `Test-Case` names. Change behavior → **edit the generator, then regenerate**
   (command below). A hand-edit is a lie about how the file is produced and is
   overwritten on the next run.
2. **Respect the invariants in README's "Findings".** They fail *silently*:
   ASCII-only source; UTF-8-no-BOM writes via `[IO.File]::WriteAllText`; never
   hand-edit `openclaw.json`; **never pass JSON as a native-command argument** —
   Windows PowerShell 5.1 strips the embedded quotes (`openclaw.cmd` re-expands
   `%*` into node), corrupting the entry's `id`, so OpenClaw's merge-by-id
   *appends* an id-less duplicate (`--merge` is fine — merges by id; the quoting
   is the bug, and PS 7 fixes it). Always **pipe via `--stdin`** (or `--batch-file`).
   `Set-ModelContextCap` reads + de-dupes + clamps, then writes through the
   **`Patch` helper (`config patch --stdin`)** — the house pattern; it also
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
   install`/`uninstall` take **one** id per call — loop, never pass a list.
4. **Do not run the installer to "test" a change.** Its steps install system
   components, enable Hyper-V, write the registry, create Scheduled Tasks, and
   the uninstall path deletes `~/.openclaw` and `~/.android` irreversibly. Use
   the **`soft-test` command below**, which loads both scripts as libraries and
   verifies every menu option without executing anything that mutates the host.
5. **Logs.** Every menu step is transcribed to `./logs/` (gitignored) by
   `Invoke-Step` — one timestamped file per run, path printed when the step
   ends. Transcripts can capture tokens echoed by `openclaw`/`adb`, so they are
   never committed.
6. **Commit after completing AND soft-testing every task.** Run `soft-test`
   first; only commit once it is green. Stage **only** the files you changed —
   never `env`, `openclaw.json`, `paired.json`, `logs/`, or the
   `*.rejected.*`/`*.clobbered.*`/`*.bak.*` snapshots. End the commit message
   with the `Co-Authored-By` trailer.

## Secrets

The token file is named `env` (no dot) — a stock `.env` rule would miss it, so
the generated `.gitignore` lists both. Never commit `env`, `openclaw.json`
(holds a gateway token), `paired.json` (device tokens), or `logs/`. The docs
step warns if `env` is already git-tracked (`.gitignore` cannot untrack it — the
token must then be revoked via `/revoke` in @BotFather).

## Regenerate the docs (headless)

The menu item is *"Generate README.md, LICENSE, .gitignore"*. To run it without
the interactive menu:

```powershell
$global:OC_NoAutoStart = $true
. .\OpenClaw_Ollama_12GB_VRAM_Lite.ps1
$PSCommandPath = (Resolve-Path .\OpenClaw_Ollama_12GB_VRAM_Lite.ps1)
$script:Env = @{}          # empty env -> canonical menu-table "Why" text
& $StepReadme
```

Generate from **Lite** (not Full) — that is the committed variant. The generator
reads ambient `$script:Env` and `$f`; a leaked binding changes the output, so
regenerate in a clean session.

## Command: `Start Soft Test` -- verify every menu option, both editions

Trigger: the user says **"Start Soft Test"** (or "soft-test"). This is the
non-destructive test that runs *here*. Run the embedded script below from the
repo root and report the PASS/FAIL summary. It loads both scripts as libraries
and asserts, for all menu options in Lite and Full:

- both files parse clean and are ASCII-only; generated files have no BOM;
- Lite exposes exactly 18 items in the expected key order; every `Enabled`
  predicate evaluates against an empty and a fully-populated `$script:Env`, and
  every `Why` renders, with no exception;
- the six Full-only steps are inert placeholders in Lite (invoking throws
  `$FullOnly`);
- Full re-wires those off the placeholder to their real Actions, relabels
  `ollama`, and widens the `openclaw` precondition;
- the docs generator is idempotent (regenerating leaves the generated files
  matching what is staged).

It runs **nothing** that installs, reboots, writes the registry, or deletes.

This block is the ONE canonical copy of the soft-test -- it is NOT also kept as a
separate `.ps1`. The pre-commit hook and the CI Action EXTRACT this fenced block
(by its `# soft-test.ps1` first line) and run it, so there is never a second copy
to drift.

```powershell
# soft-test.ps1 -- structural + safe-dynamic verification of EVERY menu option
# in both editions. Loads the scripts as LIBRARIES; runs nothing that installs,
# reboots, writes the registry, or deletes. Run from the repo root:
#     powershell -ExecutionPolicy Bypass -File .\soft-test.ps1
$ErrorActionPreference = 'Stop'
$Repo = (Get-Location).Path
$Lite = Join-Path $Repo 'OpenClaw_Ollama_12GB_VRAM_Lite.ps1'
$Full = Join-Path $Repo 'OpenClaw_Ollama_12GB_VRAM_Full.ps1'

$pass = 0; $fail = 0
function Check($name, $cond, $detail='') {
    if ($cond) { Write-Host ("  [PASS] {0}" -f $name) -ForegroundColor Green; $script:pass++ }
    else       { Write-Host ("  [FAIL] {0} {1}" -f $name, $detail) -ForegroundColor Red; $script:fail++ }
}

$ExpectedKeys = @('prereqs','hyperv','verify','android','ollama','token','openclaw',
                  'suite','agent','xapk','launchavd','approve','status','dashboard','autostart','skills','docs','uninstall')
$FullOnlyKeys = @('hyperv','verify','android','agent','xapk','launchavd')

# A synthetic "everything present" env, to prove Enabled predicates flip on.
$FullEnv = @{}
foreach ($k in 'Npm','Npx','Adb','Scrcpy','Emulator','Ollama','OpenClaw','Token','Avd',
               'Cfg','ControlUi','HyperV','Model','Device','ScrcpyMcp','Installed') { $FullEnv[$k] = $true }

Write-Host "`n== Phase 1: static parse / encoding ==" -ForegroundColor Cyan
# NB: avoid a variable named $f here -- the README generator references $f in its
# one-liner examples, and a leaked binding would pollute the generated output.
foreach ($file in @($Lite,$Full)) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
    Check "parses clean: $(Split-Path $file -Leaf)" ($errs.Count -eq 0) "$($errs.Count) errors"
    $bytes = [IO.File]::ReadAllBytes($file)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
    Check "ASCII-only: $(Split-Path $file -Leaf)" ($nonAscii -eq 0) "$nonAscii non-ASCII bytes"
}
foreach ($g in 'README.md','LICENSE','.gitignore','env.example') {
    $p = Join-Path $Repo $g
    if (Test-Path $p) {
        $b = [IO.File]::ReadAllBytes($p)
        $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        Check "no BOM: $g" (-not $bom)
    }
}

Write-Host "`n== Phase 2: LITE menu (headless) ==" -ForegroundColor Cyan
$global:OC_NoAutoStart = $true
. $Lite
Check "Lite has 18 items" ($script:Items.Count -eq 18) "got $($script:Items.Count)"
$keys = $script:Items | ForEach-Object { $_.Key }
Check "Lite keys/order match" (@(Compare-Object $keys $ExpectedKeys -SyncWindow 0).Count -eq 0)
foreach ($it in $script:Items) {
    $script:Env = @{}
    $offOk = $true; try { [void](& $it.Enabled) } catch { $offOk = $false }
    $script:Env = $FullEnv.Clone()
    $onOk = $true; try { [void](& $it.Enabled) } catch { $onOk = $false }
    $whyOk = $true; try { if ($it.Why -is [scriptblock]) { [void](& $it.Why) } } catch { $whyOk = $false }
    Check "Lite '$($it.Key)' Enabled+Why eval" ($offOk -and $onOk -and $whyOk -and ($it.Action -is [scriptblock]))
}
# Full-only steps must be inert placeholders in Lite: invoking throws $FullOnly.
foreach ($k in $FullOnlyKeys) {
    $it = $script:Items | Where-Object Key -eq $k
    $threw = $false
    try { & $it.Action } catch { $threw = $_.Exception.Message -match 'Full edition only' }
    Check "Lite '$k' placeholder throws FullOnly" $threw
}
# Docs generator must be idempotent -- regenerate from THIS Lite context (so the
# menu table is the Lite variant) and expect no change to the committed README.
# Reset ambient state the generator reads: an empty $script:Env makes every "Why"
# scriptblock take its unmet-precondition branch (the canonical menu-table text).
$script:Env = @{}
$PSCommandPath = $Lite
try { & $StepReadme *> $null } catch {}   # swallow the benign git-stderr-under-Stop
## Compare the regenerated output to the STAGED/committed version (worktree vs
## index) with `git diff`, NOT `git status`: that passes whether run standalone
## (CI, on committed code) or inside a pre-commit hook (where the correct regen
## is already staged, which `git status` would flag). Covers EVERY generated file.
## git's autocrlf warning goes to stderr, which is FATAL under Stop -- drop to
## Continue and gate on the exit code (0 = no diff = clean), the house pattern.
$ErrorActionPreference = 'Continue'
git -C $Repo diff --quiet -- README.md LICENSE .gitignore env.example 2>$null
$genClean = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'
Check "generated docs match source (regeneration is a no-op)" $genClean "run the docs generator and stage the result"

Write-Host "`n== Phase 3: FULL menu (headless) ==" -ForegroundColor Cyan
Remove-Variable -Name Items -Scope Script -ErrorAction SilentlyContinue
$src = Get-Content $Full -Raw
$tmp = Join-Path $Repo '.__full_headless_test.ps1'   # in repo so $PSScriptRoot finds local Lite
[IO.File]::WriteAllText($tmp, ($src -replace '(?m)^\s*Start-Menu\s*$','# stripped'),
    (New-Object Text.UTF8Encoding($false)))
try {
    $global:OC_EntryScript = $null; $global:OC_Features = $null
    . $tmp
    Check "Full has 18 items" ($script:Items.Count -eq 18)
    $get = { param($k) $script:Items | Where-Object Key -eq $k }
    # The five Full-only steps must no longer be the throw-placeholder.
    foreach ($k in $FullOnlyKeys) {
        $a = (& $get $k).Action.ToString()
        Check "Full '$k' Action rewired (not placeholder)" ($a -notmatch 'throw \$FullOnly')
    }
    Check "Full hyperv wired to Enable-WindowsOptionalFeature" ((& $get 'hyperv').Action.ToString() -match 'Enable-WindowsOptionalFeature')
    Check "Full android writes config.ini"                    ((& $get 'android').Action.ToString() -match 'config\.ini')
    Check "Full xapk uses install-multiple"                   ((& $get 'xapk').Action.ToString() -match 'install-multiple')
    Check "Full ollama label mentions scrcpy-mcp"             ((& $get 'ollama').Label -match 'scrcpy-mcp')
    Check "Full openclaw Enabled widened (needs scrcpy)"      ((& $get 'openclaw').Enabled.ToString() -match 'Scrcpy')
    ## Run-from-memory elevation: Full saves itself so a UAC relaunch stays Full,
    ## and FAILS LOUD rather than silently relaunching Lite.
    $fullRaw = Get-Content $Full -Raw
    Check "Full self-saves for scriptblock elevation, fails loud (never silent Lite)" (($fullRaw -match 'OC_EntryScript = \$fullTmp') -and ($fullRaw -match 'silently drop to the LITE') -and ($fullRaw -match 'throw'))
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

Write-Host "`n== Phase 4: unattended plumbing ==" -ForegroundColor Cyan
# Full is loaded now, so every step scriptblock (Lite + Android) is in scope.
$p = (Get-Command $Lite).Parameters
Check "Lite param -Unattended"   ($p.ContainsKey('Unattended'))
Check "Lite param -AutoXapkPath" ($p.ContainsKey('AutoXapkPath'))
Check "Lite param -RunAll"       ($p.ContainsKey('RunAll'))
Check "Start-FullTest defined"   ([bool](Get-Command Start-FullTest -EA SilentlyContinue))
Check "Read-Prompt defined"      ([bool](Get-Command Read-Prompt -EA SilentlyContinue))
# Behavioral: unattended Read-Prompt returns the default instead of blocking.
$Unattended = $true
Check "Read-Prompt returns default when unattended" ((Read-Prompt 'proceed?' 'yes') -eq 'yes')
$Unattended = $false
# Invoke-Step is unattended-safe: guards the keypress, returns a result object.
$isDef = (Get-Command Invoke-Step).Definition
Check "Invoke-Step guards the pause"      ($isDef -match 'if \(-not \$Unattended\)')
Check "Invoke-Step returns result object" ($isDef -match 'PSCustomObject')
# Each interactive step body has an unattended branch.
Check "StepToken uses Read-Prompt"          ($StepToken.ToString()     -match 'Read-Prompt')
Check "StepUninstall uses Read-Prompt"      ($StepUninstall.ToString() -match 'Read-Prompt')
Check "StepOpenClaw handles unattended TUI" ($StepOpenClaw.ToString()  -match '\$Unattended')
Check "StepAndroid handles unattended"      ($StepAndroid.ToString()   -match '\$Unattended')
Check "StepXapk uses AutoXapkPath"          ($StepXapk.ToString()      -match 'AutoXapkPath')
# AVD launch: -StartAvd param, iGPU pinning, hardware GL.
Check "Lite param -StartAvd"                 ($p.ContainsKey('StartAvd'))
Check "Set-EmulatorGpuPreference defined"    ([bool](Get-Command Set-EmulatorGpuPreference -EA SilentlyContinue))
Check "StepLaunchAvd pins iGPU + -gpu host"  (($StepLaunchAvd.ToString() -match 'Set-EmulatorGpuPreference') -and ($StepLaunchAvd.ToString() -match "'host'"))
# Context clamp: writes via config patch --stdin (Patch helper), never inline JSON.
$scmDef = (Get-Command Set-ModelContextCap).Definition
Check "Set-ModelContextCap patches via stdin (Patch), no inline config set" (($scmDef -match 'Patch .context clamp') -and ($scmDef -notmatch 'config set models'))
Check "StepOpenClaw clamps via Set-ModelContextCap"  ($StepOpenClaw.ToString() -match 'Set-ModelContextCap')
# Install sub-menu: lists all three add-ons and is unattended-safe (Read-Prompt).
$skDef = $StepSkills.ToString()
Check "StepSkills sub-menu lists 3 add-ons + unattended-safe" (($skDef -match 'scrcpy-mcp') -and ($skDef -match '@thesethrose/context7') -and ($skDef -match '@freeter226/base64-toolkit') -and ($skDef -match 'Read-Prompt'))
Check "Install-ClawSkill defined" ([bool](Get-Command Install-ClawSkill -EA SilentlyContinue))
# python3 provisioning: base64-toolkit needs a 'python3' bin; Windows ships only 'python'.
Check "Ensure-Python3 defined" ([bool](Get-Command Ensure-Python3 -EA SilentlyContinue))
Check "StepPrereqs provisions python3" ($StepPrereqs.ToString() -match 'Ensure-Python3')
$epDef = (Get-Command Ensure-Python3).Definition
Check "Ensure-Python3 creates real python3.exe (copy)" (($epDef -match 'python3\.exe') -and ($epDef -match 'Copy-Item'))
# Presence pings: back-online watcher + be-right-back shutdown notify, via Bot API.
Check "Register-PresenceNotify defined"   ([bool](Get-Command Register-PresenceNotify -EA SilentlyContinue))
Check "Unregister-PresenceNotify defined" ([bool](Get-Command Unregister-PresenceNotify -EA SilentlyContinue))
Check "StepAutoStart wires presence pings" (($StepAutoStart.ToString() -match 'Register-PresenceNotify') -and ($StepAutoStart.ToString() -match 'Unregister-PresenceNotify'))
$rpDef = (Get-Command Register-PresenceNotify).Definition
Check "Presence msgs 'back online' + 'be right back' via Bot API" (($rpDef -match 'back online') -and ($rpDef -match 'be right back') -and ($rpDef -match 'api\.telegram\.org') -and ($rpDef -match '1074'))
Check "Presence watcher fires on both edges (online + brb)" (($rpDef -match 'Send-Ping \$online') -and ($rpDef -match 'Send-Ping \$brb'))
Check "Presence -OwnerName param on script + fn" ((((Get-Command $Lite).Parameters.ContainsKey('OwnerName'))) -and ((Get-Command Register-PresenceNotify).Parameters.ContainsKey('OwnerName')))
# Agent tests deliver the reply to Telegram and report SENT (not PASS).
$stDef = $StepTest.ToString()
Check "Agent tests deliver to Telegram + report SENT" (($stDef -match "reply-channel',\s*'telegram'") -and ($stDef -match '--deliver') -and ($stDef -match '\[SENT\]'))
# DroidClaw ships a deterministic no-base64 screenshot->Telegram sender.
$ocDef = $StepOpenClaw.ToString()
Check "DroidClaw bundles send-screen.ps1 (server-side, no base64)" (($ocDef -match 'send-screen\.ps1') -and ($ocDef -match 'droidclaw-screen\.png') -and ($ocDef -match 'message send --channel telegram'))
Check "Full skills limit raised to 10 (droidclaw visible in prompt)" ($ocDef -match 'maxSkillsInPrompt: 10')

Write-Host "`n== soft-test: $pass passed, $fail failed ==" -ForegroundColor (@('Green','Red')[[int]($fail -gt 0)])
if ($fail -gt 0) { exit 1 }
```

Expected on a clean tree: **80 passed, 0 failed**. A new menu item, a renamed
key, a broken `Enabled`/`Why`, a non-ASCII byte, an accidental BOM, generator
drift, or a broken unattended path each turns a line red. When you add or change
a check, edit the block above and update this count.

**Enforcement** -- two layers run this block, extracted from here:
- **Pre-commit hook** (`hooks/pre-commit`): runs before every commit. Activate
  once per clone: `git config core.hooksPath hooks`. Skippable with `--no-verify`.
- **GitHub Action** (`.github/workflows/generated-files.yml`): runs on every
  push and PR. Protects everyone; cannot be skipped.

The generated-docs check compares regenerated files to what is **staged**
(`git diff`, worktree vs index), correct both in CI and inside the hook.

## Command: `start Full Test` — automated end-to-end run (opt-in, VM)

Trigger: the user says **"start Full Test"**. This is the *live, destructive*
run — it installs everything, and ends in the **irreversible uninstall**. It is
driven by the scripts' own **`-RunAll` unattended mode** (see `Start-FullTest`
in Lite), so it is hands-off except for **one** human step: the **Android Studio
setup wizard** (a GUI with no headless entry point). That step is *not* skipped
or failed — when the SDK command-line tools are missing, `StepAndroid` launches
Studio and then **polls up to 45 min for the SDK to appear** while the human
completes the wizard, then continues to create + boot the AVD. So the AVD gets
created and the device-dependent steps (`agent`, `xapk`) run — **nothing skips**
except `hyperv` when Hyper-V is already enabled (a correct skip). Everything else
— the menu, `Read-Host` prompts, the "press any key" pauses, the OpenClaw
onboarding TUI, the `.xapk` picker, and the uninstall confirmations — is
answered or bypassed automatically.

**Before running, confirm with the user** that they are on a throwaway / VM box
they can rebuild, then have them launch (as Administrator, or with UAC disabled):

```powershell
# Full edition, fully automated. -RunAll implies -Unattended.
.\OpenClaw_Ollama_12GB_VRAM_Full.ps1 -RunAll -AutoXapkPath .\Tinder.xapk

# Lite edition:
.\OpenClaw_Ollama_12GB_VRAM_Lite.ps1 -RunAll
```

`-RunAll` walks every menu item in order: enabled steps run via the
unattended-safe `Invoke-Step`; steps whose preconditions are not yet met are
recorded as **expected skips** (with the menu's reason), not failures. The only
gate that forces a **re-run** is Hyper-V: if it was just enabled, reboot and run
`-RunAll` again (the SDK gate no longer needs a re-run — the android step waits
for the wizard in-place). It writes **`full_test_report.md`** (gitignored) with a
PASS/FAIL/SKIP row and duration per step; per-step console transcripts land in
`logs/`, and the report is written from a `finally` so it survives a mid-run
throw.

What the agent does on this trigger: confirm the VM/throwaway precondition;
**back up `~/.openclaw` first** (see below); note the current state (`Get-Date`,
`$PSVersionTable`, `whoami`, C: free, Hyper-V state, whether
`~/.openclaw`/`~/.android`/`~/.ollama` exist, GPU + driver); tell the user the
exact `-RunAll` command; after each pass, read `full_test_report.md` + the
relevant `logs/` transcripts and check results against README's **Test suite**
and **Status check** (the source of per-step expected values — do not restate
them here); flag any FAIL, then summarize Bugs / Improvements / Environment and
ask before opening issues.

Backups (part of the procedure — the run deletes `~/.openclaw`): `Start-FullTest`
copies the *current* `~/.openclaw` → `~/.openclaw.prerun-backup.<ts>` before any
step runs (protects your original token + paired devices), and `StepUninstall`
copies it again → `~/.openclaw.backup.<ts>` right before the teardown. Both are
automatic now. On a real machine still eyeball that the pre-run backup printed,
and offer to restore it after — `~/.android` (AVDs) is *not* backed up (GBs;
recreated by step 4).

Unattended behavior worth knowing: uninstall **keeps** `~/.ollama` model files
(no 6.6 GB re-pull), prereqs, and Hyper-V, but always removes `~/.openclaw` and
`~/.android` — and it *does* `winget uninstall Ollama.Ollama`, so the ollama
**binary** is gone even though the models stay (a re-run's `prereqs` reinstalls
it). `-RunAll` requires the token to already be in `./env` (the token step keeps
the saved value rather than prompting). The onboarding TUI is launched detached
and killed once `openclaw.json` appears. If the model narrates instead of calling
tools in the `agent` step, that is a model-tier issue, not a script bug.

Running it: `Start-FullTest` auto-backs-up `~/.openclaw` before it starts (and
the uninstall backs it up again), so the original token + paired devices survive
a teardown; `~/.android` is not backed up but is recreatable. The agent *can*
drive `-RunAll` from a session via a **background**
`PowerShell` task with **`dangerouslyDisableSandbox: true`** (the sandbox blocks
the installer subprocesses — you'll see `Connectivity probe: failed` otherwise);
the Studio wizard pops on the user's screen and the 45-min SDK poll waits for it.
Only do this with the user's explicit, informed go-ahead — it is destructive.
Structural coverage of every option lives in the `soft-test` command above.

Findings from the first live `-RunAll` (all fixed; keep them from regressing):
- **Tilde path:** `openclaw config file` returns a `~`-path; `[IO.File]` APIs do
  not expand `~`, so the gateway `.env` write must expand `~`→`$Home` first.
- **`Stop` + native stderr:** under the global `$ErrorActionPreference='Stop'`,
  benign stderr from `adb`/`ollama`/`git`/`openclaw` is *fatal* (even with
  `2>$null`). Native-heavy steps set `$ErrorActionPreference='Continue'` locally
  and gate on `$LASTEXITCODE`. When adding a step that shells out, do the same.
- **Report survival:** `Start-FullTest` guards every `Update-EnvState` and writes
  the report in a `finally` — one post-step throw used to lose the whole report.

## Documentation lookups (Context7)

The vendored `docs/` guides were **removed**. Instead, pull current,
version-accurate docs for any technology in the stack **on demand** via
Context7's `find-docs` skill — OpenClaw, Ollama, adb, scrcpy, scrcpy-mcp,
Android SDK / AVD, QEMU, Windows 11 / Hyper-V, PowerShell, uiautomator2, and the
end-to-end integration between them.

One-time setup (installs the `find-docs` skill + rule for each agent):

```
npx ctx7 setup --claude       # Claude Code (this agent)
npx ctx7 setup --antigravity  # Antigravity / Gemini
```

Then use the `find-docs` skill to look up a subsystem **before** modifying it.
**Still verify anything load-bearing against the primary/upstream source** — the
config-schema audit found Context7's indexed OpenClaw docs *wrong* about
`skills.limits`, and the ground truth was the binary's own `openclaw config
schema` / the Zod definitions. Indexed docs are a fast first pass, not the final
word (see README "Research").
