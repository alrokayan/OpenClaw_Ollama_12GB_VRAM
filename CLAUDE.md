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
   hand-edit `openclaw.json`; the models-array clamp (do NOT use `config set
   --merge` — on 2026.6.11 it left a duplicate `id` and silently failed to
   change `num_ctx`; use `Set-ModelContextCap`, a read-modify-dedupe-full-replace
   that preserves `compat.supportsTools`);
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
                  'suite','agent','xapk','launchavd','approve','status','dashboard','docs','uninstall')
$FullOnlyKeys = @('hyperv','verify','android','agent','xapk','launchavd')

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
Check "Lite has 16 items" ($script:Items.Count -eq 16) "got $($script:Items.Count)"
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
    Check "Full has 16 items" ($script:Items.Count -eq 16)
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
# Context clamp: robust helper, not the duplicate-prone --merge.
Check "Set-ModelContextCap defined"          ([bool](Get-Command Set-ModelContextCap -EA SilentlyContinue))
Check "StepOpenClaw clamps via helper (no models --merge)" (($StepOpenClaw.ToString() -match 'Set-ModelContextCap') -and ($StepOpenClaw.ToString() -notmatch 'ollama\.models.*--merge'))

Write-Host "`n== soft-test: $pass passed, $fail failed ==" -ForegroundColor (@('Green','Red')[[int]($fail -gt 0)])
if ($fail -gt 0) { exit 1 }
```

Expected on a clean tree: **63 passed, 0 failed**. A new menu item, a renamed
key, a broken `Enabled`/`Why`, a non-ASCII byte, an accidental BOM, generator
drift, or a broken unattended path each turns a line red.

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
