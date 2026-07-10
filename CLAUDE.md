# CLAUDE.md

Guidance for Claude Code sessions working in this repository.

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
- **`docs/` deep guides** — read the relevant one *before* touching a subsystem
  (table at the bottom). Do not modify those docs without the user's approval.

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
   hand-edit `openclaw.json`; the array-merge trap (merge `models` by `id`);
   `num_ctx` and `contextWindow` move together; token in `~/.openclaw/.env`;
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

## Command: `soft-test` — verify every menu option, both editions

Trigger: the user says **"soft-test"** (or "test every option"). This is the
non-destructive test that runs *here*. Write the script below to the scratchpad,
run it from the repo root, and report the PASS/FAIL summary. It loads both
scripts as libraries and asserts, for all 15 options in Lite and Full:

- both files parse clean and are ASCII-only; generated files have no BOM;
- Lite exposes exactly 15 items in the expected key order; every `Enabled`
  predicate evaluates against an empty and a fully-populated `$script:Env`, and
  every `Why` renders — with no exception;
- the five Full-only steps are inert placeholders in Lite (invoking throws
  `$FullOnly`);
- Full re-wires those five off the placeholder to their real Actions, relabels
  `ollama`, and widens the `openclaw` precondition;
- the docs generator is idempotent (regenerating leaves README unchanged).

It runs **nothing** that installs, reboots, writes the registry, or deletes.
Truly destructive/interactive options (prereqs install, Hyper-V, Android SDK,
ollama pull, openclaw onboarding, agent tests, xapk install, uninstall) are
verified only structurally here; exercise their runtime behavior with the live
procedure below, on a throwaway VM.

```powershell
# soft-test.ps1 -- structural + idempotency check of EVERY menu option, both
# editions. Loads the scripts as LIBRARIES; mutates nothing on the host.
# Run from the repo root:  powershell -ExecutionPolicy Bypass -File .\soft-test.ps1
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
                  'suite','agent','xapk','approve','status','dashboard','docs','uninstall')
$FullOnlyKeys = @('hyperv','verify','android','agent','xapk')

# A synthetic "everything present" env, to prove Enabled predicates flip on.
$FullEnv = @{}
foreach ($k in 'Npm','Npx','Adb','Scrcpy','Emulator','Ollama','OpenClaw','Token','Avd',
               'Cfg','ControlUi','HyperV','Model','Device','ScrcpyMcp','Installed') { $FullEnv[$k] = $true }

Write-Host "`n== Phase 1: static parse / encoding ==" -ForegroundColor Cyan
# NB: no variable named $f here -- the README generator references $f in its
# one-liner examples, and a leaked binding would pollute generated output.
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
Check "Lite has 15 items" ($script:Items.Count -eq 15) "got $($script:Items.Count)"
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
foreach ($k in $FullOnlyKeys) {
    $it = $script:Items | Where-Object Key -eq $k
    $threw = $false
    try { & $it.Action } catch { $threw = $_.Exception.Message -match 'Full edition only' }
    Check "Lite '$k' placeholder throws FullOnly" $threw
}
# Docs generator must be idempotent. Reset ambient state it reads: empty
# $script:Env => every "Why" takes its unmet-precondition (canonical) branch.
$script:Env = @{}
$PSCommandPath = $Lite
try { & $StepReadme *> $null } catch {}     # swallow the benign git-stderr-under-Stop
$diff = (git -C $Repo status --porcelain README.md) 2>$null
Check "README regeneration is idempotent (no drift)" ([string]::IsNullOrWhiteSpace($diff)) "changed:$diff"

Write-Host "`n== Phase 3: FULL menu (headless) ==" -ForegroundColor Cyan
Remove-Variable -Name Items -Scope Script -ErrorAction SilentlyContinue
$src = Get-Content $Full -Raw
$tmp = Join-Path $Repo '.__full_headless_test.ps1'   # in repo so $PSScriptRoot finds local Lite
[IO.File]::WriteAllText($tmp, ($src -replace '(?m)^\s*Start-Menu\s*$','# stripped'),
    (New-Object Text.UTF8Encoding($false)))
try {
    $global:OC_EntryScript = $null; $global:OC_Features = $null
    . $tmp
    Check "Full has 15 items" ($script:Items.Count -eq 15)
    $get = { param($k) $script:Items | Where-Object Key -eq $k }
    foreach ($k in $FullOnlyKeys) {
        Check "Full '$k' Action rewired (not placeholder)" ((& $get $k).Action.ToString() -notmatch 'throw \$FullOnly')
    }
    Check "Full hyperv wired to Enable-WindowsOptionalFeature" ((& $get 'hyperv').Action.ToString() -match 'Enable-WindowsOptionalFeature')
    Check "Full android writes config.ini"                    ((& $get 'android').Action.ToString() -match 'config\.ini')
    Check "Full xapk uses install-multiple"                   ((& $get 'xapk').Action.ToString() -match 'install-multiple')
    Check "Full ollama label mentions scrcpy-mcp"             ((& $get 'ollama').Label -match 'scrcpy-mcp')
    Check "Full openclaw Enabled widened (needs scrcpy)"      ((& $get 'openclaw').Enabled.ToString() -match 'Scrcpy')
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

Write-Host "`n== soft-test: $pass passed, $fail failed ==" -ForegroundColor (@('Green','Red')[[int]($fail -gt 0)])
if ($fail -gt 0) { exit 1 }
```

Expected on a clean tree: **42 passed, 0 failed**. A new menu item, a renamed
key, a broken `Enabled`/`Why`, a non-ASCII byte, an accidental BOM, or generator
drift each turns a line red.

## Command: `start Full Test` — live destructive run (opt-in, Administrator, VM)

Trigger: the user says **"start Full Test"** and confirms they are at a Windows
Administrator console they can afford to rebuild. This actually installs
everything, enables Hyper-V, and runs the irreversible uninstall. **Confirm
first**, record starting state (`Get-Date`, `$PSVersionTable`, `whoami`, C: free,
Hyper-V state, whether `~/.openclaw` / `~/.android` / `~/.ollama` exist, GPU +
driver), and log each step to a `full_test_report.md` artifact. Per-step
*expected values* are the README **Test suite** and **Status check** sections —
do not duplicate them; assert against them.

Walk the menu in order in each edition. Option-by-option operational notes (what
is unique to the live run, beyond README's expected state):

**Lite** — the five Full-only steps (`hyperv`, `verify`, `android`, `agent`,
`xapk`) must stay greyed out and throw `$FullOnly` if invoked. `prereqs` installs
the base winget set (no scrcpy/JDK/ffmpeg). `ollama` pulls the model, no
scrcpy-mcp. `token` writes `env` + `~/.openclaw/.env`, never the raw token into
`openclaw.json`. `openclaw` onboarding opens the TUI and blocks until you exit.
`approve` on a missing `paired.json` must report and not crash. `status`, `docs`,
`dashboard` must run everywhere. `uninstall` runs **last**.

**Full** (reboot after `hyperv`) — `prereqs` additionally installs scrcpy,
OpenJDK 17, ffmpeg. `hyperv` enables exactly the three leaf features (management
tools stay off). `android` is interactive (SDK wizard), writes the `config.ini`
with snapshots disabled, launches detached, and polls `getprop sys.boot_completed`
(never `adb wait-for-device`). `ollama` also installs scrcpy-mcp and relabels.
`openclaw` also writes the scrcpy MCP server and the DroidClaw skill (UTF-8, no
BOM). `agent` sends three prompts — if the model narrates instead of calling
tools, that is a model-tier issue, not a script bug. `xapk` handles plain
`.apk`, split `.xapk` (`install-multiple`), and `.obb` push; catches ABI
mismatch. `uninstall` also deletes `~/.android` and kills `qemu-system-x86_64`
(not just `emulator.exe`).

Then the cross-edition checks: menu numbering identical across editions;
`-NumCtx 32768 -NoDashboard` forwards from Full into Lite; non-elevated Full
relaunches itself elevated with args intact; both `.ps1` files scan zero
non-ASCII; a missing Lite makes Full throw a clear version-mismatch error;
regenerated docs are byte-identical to the committed ones. Finish the report
with a Bugs / Improvements / Environment summary and ask before opening issues.

## Deep docs — read on demand

Not loaded automatically. Read the relevant guide **before** modifying that
subsystem; do not modify the guides themselves without the user's approval
(they were sourced from Context7-indexed references and verified upstream).

| When working on... | Read first |
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
