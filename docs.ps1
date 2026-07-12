# docs.ps1 -- README.md generator for the split-script architecture.
#
# The README is GENERATED, never hand-edited (a hand-edit is a lie about how the
# file is produced and is overwritten on the next commit). The pre-commit hook
# (hooks/pre-commit) runs this on every commit and stages the result, so the docs
# can never drift from the code.
#
# What is pulled automatically (drift-proof):
#   - the menu tables      -> AST-parsed from every Menu-* function in the scripts
#   - the tunables + models -> read from config.json
#   - each script's purpose -> its top comment block
# What lives here as prose (the narrative that a human maintains):
#   - the $Doc here-strings below (disclaimer, abstract, findings, security, ...).
#
# Run it by hand:  pwsh -NoProfile -File .\docs.ps1
# Or headless from a dot-source:  . .\docs.ps1 ; New-Readme

# ---------------------------------------------------------------------------
# Where things are
# ---------------------------------------------------------------------------
$RepoDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
# Order matters -- this is also the install / operate order shown in the README.
$Scripts = 'start_here.ps1','common.ps1','install.ps1','run.ps1','fix.ps1','uninstall.ps1'
$RepoUrl = 'https://github.com/alrokayan/OpenClaw_Ollama_12GB_VRAM'

# ---------------------------------------------------------------------------
# Small AST + text helpers (the drift-proof extraction)
# ---------------------------------------------------------------------------
function Get-Ast ($path) {
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path).Path, [ref]$null, [ref]$e)
}

# The leading contiguous "# ..." comment block of a script = its purpose prose.
function Get-LeadingDoc ($path) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($ln in (Get-Content $path)) {
        if ($ln -match '^\s*#') { $out.Add(($ln -replace '^\s*#\s?', '')) }
        elseif ($ln.Trim() -eq '') { if ($out.Count) { break } }
        else { break }
    }
    ($out -join "`n").TrimEnd()
}

# Every Menu-* function in a script, with its title and its numbered Line entries.
# Title comes from the 'Say "== TITLE =="' call if present, else the function name.
function Get-Menus ($path) {
    $ast = Get-Ast $path
    $fns = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'Menu-*'
    }, $true)
    foreach ($fn in $fns) {
        $title = $fn.Name
        $say = $fn.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Say'
        }, $true) | Where-Object {
            $_.CommandElements.Count -ge 2 -and $_.CommandElements[1].Extent.Text -match '=='
        } | Select-Object -First 1
        if ($say) { $title = ($say.CommandElements[1].Value -replace '={2,}', '').Trim() }

        $items = New-Object System.Collections.Generic.List[object]
        $lines = $fn.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Line'
        }, $true)
        foreach ($l in $lines) {
            $els = $l.CommandElements
            if ($els.Count -lt 3) { continue }
            $num = $els[1].Extent.Text
            # Label may be a plain string, an expandable string ("... $Model"), or a
            # whole expression (("Install OpenClaw" + $(...)) / ("... {0}" -f $(...))).
            # Take the first string literal inside it; the caller substitutes vars.
            $strAst = $els[2].Find({ param($n)
                $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
            }, $true)
            $lab = if ($strAst) { $strAst.Value } else { $els[2].Extent.Text.Trim('"''') }
            $items.Add([pscustomobject]@{ N = $num; Label = $lab })
        }
        [pscustomobject]@{ Fn = $fn.Name; Title = $title; Script = (Split-Path $path -Leaf); Items = $items }
    }
}

function Get-Config {
    $p = Join-Path $RepoDir 'config.json'
    if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json } else { $null }
}

# ---------------------------------------------------------------------------
# The narrative prose (maintain this; the rest is generated from code)
# ---------------------------------------------------------------------------
$Doc = @{}

$Doc.Intro = @'
A set of Windows PowerShell scripts that install, configure, operate, and
uninstall a fully local AI agent: an Ollama-served model behind an OpenClaw
gateway, reachable over Telegram, that drives an Android emulator (adb + device
skills). It targets a 12 GB-VRAM machine (e.g. an RTX 4070).
'@

$Doc.Disclaimer = @'
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
'@

$Doc.Abstract = @'
OpenClaw bridges messaging apps to agents through a local gateway. These scripts
wire it to a locally-served Ollama model and an Android emulator, so an agent you
message on Telegram can look at a phone screen, reason about it, and tap, type,
and swipe. Everything runs on your machine: no cloud model, no data leaving the
box (web search aside, which is disabled by default here).
'@

$Doc.Architecture = @'
The old single script was split into focused, dot-sourced sections. `start_here.ps1`
is the entry point; it sources `common.ps1` (shared config, helpers, state checks)
and the four section scripts, then shows a 4-item top menu. Each section also runs
standalone (`powershell -File .\install.ps1`). Every menu action is a plain
function whose body is the real commands -- copy one out and run it by hand.
'@

$Doc.Config = @'
All tunables live in **config.json** (single source of truth). Precedence is
**CLI arg > config.json > built-in default**: pass any tunable as a parameter to
`start_here.ps1` / `install.ps1` (e.g. `-Model`, `-NumCtx`) to override the file
for one run; if a key is absent from config.json the hardcoded default applies.
No prompting. `model` + `numCtx` flow into openclaw.json (the model's
context/num_ctx); the KV/keep-alive/flash-attn values become the Ollama server
env applied at `serve` start.
'@

$Doc.Gaming = @'
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
'@

$Doc.Security = @'
- Secrets never enter git: `~/.openclaw/.env` (Telegram token), `openclaw.json`
  (gateway token), and `paired.json` (device tokens) are all gitignored. The repo
  tracks only templates (`env.example`, `openclaw.template.json`).
- OpenClaw reads **`.env`** (with the dot) -- matched by the `.env` gitignore rule.
- Exec policy is the owner's choice for a single-user box; `tools.exec` runs on the
  gateway host. Web search is disabled by default.
- Per-step transcripts land in `logs/` (gitignored) -- they can capture tokens
  echoed by `openclaw`/`adb`, so they are never committed.
'@

# The load-bearing invariants -- these fail SILENTLY if broken. Keep them current.
$Doc.Findings = @'
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
'@

$Doc.Docs = @'
Deep docs on the stack (OpenClaw, Ollama, adb, mobile skills, Android SDK/AVD,
QEMU, Windows/Hyper-V, PowerShell) are pulled on demand via Context7's `find-docs`
skill, not vendored. Verify anything load-bearing against the upstream source --
indexed docs can be wrong (the config-schema audit found `skills.limits`
misdocumented; ground truth was `openclaw config schema`).
'@

# ---------------------------------------------------------------------------
# Assemble the README
# ---------------------------------------------------------------------------
function New-Readme {
    $sb = New-Object System.Text.StringBuilder
    function Add ($t = '') { [void]$sb.AppendLine($t) }

    Add '# OpenClaw + Ollama on 12 GB VRAM'
    Add ''
    Add $Doc.Intro
    Add ''
    Add "<$RepoUrl>"
    Add ''
    Add "_Generated from the scripts by ``docs.ps1`` on $(Get-Date -Format 'yyyy-MM-dd'). Do not edit by hand -- it is regenerated and staged on every commit._"
    Add ''

    Add '## Disclaimer'; Add ''; Add $Doc.Disclaimer; Add ''
    Add '## Abstract';   Add ''; Add $Doc.Abstract;   Add ''
    Add '## Architecture'; Add ''; Add $Doc.Architecture; Add ''

    # Script inventory -- name + first line of each script's header.
    Add '### The scripts'
    Add ''
    Add '| Script | Purpose |'
    Add '| --- | --- |'
    foreach ($s in $Scripts) {
        $p = Join-Path $RepoDir $s
        if (-not (Test-Path $p)) { continue }
        $first = ((Get-LeadingDoc $p) -split "`n" | Select-Object -First 1)
        $first = ($first -replace '^\S+\.ps1\s*--\s*', '') -replace '\|', '\|'
        Add "| ``$s`` | $first |"
    }
    Add ''

    Add '## Quick start'
    Add ''
    Add 'Clone, then run the entry script (it self-elevates the steps that need admin):'
    Add ''
    Add '```powershell'
    Add 'powershell -ExecutionPolicy Bypass -File .\start_here.ps1'
    Add '```'
    Add ''
    Add 'Override a tunable for one run (arg > config.json > default):'
    Add ''
    Add '```powershell'
    Add 'powershell -ExecutionPolicy Bypass -File .\install.ps1 -Model qwen3.5:latest -NumCtx 65536'
    Add '```'
    Add ''

    # Configuration + tunables (from config.json)
    Add '## Configuration'
    Add ''
    Add $Doc.Config
    Add ''
    $cfg = Get-Config
    if ($cfg) {
        Add '| Key | Default | Meaning |'
        Add '| --- | --- | --- |'
        $meaning = @{
            model          = 'Ollama model tag (also the OpenClaw provider model)'
            numCtx         = 'Context window (openclaw num_ctx/contextWindow + OLLAMA_CONTEXT_LENGTH)'
            avd            = 'Android Virtual Device name'
            keepAlive      = 'Ollama keep-alive (-1 = resident forever, 0 = unload immediately)'
            kvCacheType    = 'Ollama KV cache type (q8_0 halves KV VRAM)'
            flashAttention = 'Ollama flash attention (1 = on; required for quantized KV)'
        }
        foreach ($prop in $cfg.PSObject.Properties) {
            if ($prop.Name -like '_*') { continue }
            $m = if ($meaning.ContainsKey($prop.Name)) { $meaning[$prop.Name] } else { '' }
            Add "| ``$($prop.Name)`` | ``$($prop.Value)`` | $m |"
        }
        Add ''

        # Recommended models (from config.json _recommendedModels)
        if ($cfg._recommendedModels) {
            Add '### Recommended Ollama models for OpenClaw'
            Add ''
            Add '_Source: <https://docs.ollama.com/integrations/openclaw#recommended-models>_'
            Add ''
            foreach ($tier in 'cloud','local') {
                if (-not $cfg._recommendedModels.$tier) { continue }
                Add "**$((Get-Culture).TextInfo.ToTitleCase($tier)):**"
                Add ''
                foreach ($m in $cfg._recommendedModels.$tier.PSObject.Properties) {
                    Add "- ``$($m.Name)`` -- $($m.Value)"
                }
                Add ''
            }
        }
    }

    # Menus -- every Menu-* function across the section scripts, in install/operate order.
    Add '## The menus'
    Add ''
    Add 'Auto-generated from each `Menu-*` function -- these tables cannot drift from the code.'
    Add ''
    # Show each script's primary menu first, then its submenus (AST order is
    # definition order, which lists submenus before the parent).
    $Primary = @{ 'install.ps1' = 'Menu-Install'; 'run.ps1' = 'Menu-Operation'; 'fix.ps1' = 'Menu-Maintenance'; 'uninstall.ps1' = 'Menu-Uninstall' }
    # Resolve the vars that appear in labels to their config.json values.
    $sub = [ordered]@{ '$TelegramSession' = 'agent:main:telegram' }
    if ($cfg) { $sub['$Model'] = [string]$cfg.model; $sub['$AvdName'] = [string]$cfg.avd; $sub['$NumCtx'] = [string]$cfg.numCtx }
    foreach ($s in 'install.ps1','run.ps1','fix.ps1','uninstall.ps1') {
        $p = Join-Path $RepoDir $s
        if (-not (Test-Path $p)) { continue }
        $menus = @(Get-Menus $p) | Sort-Object @{ Expression = { if ($_.Fn -eq $Primary[$s]) { 0 } else { 1 } } }, Title
        foreach ($menu in $menus) {
            if (-not $menu.Items.Count) { continue }
            Add "### $($menu.Title)  _($($menu.Script))_"
            Add ''
            Add '| # | Item |'
            Add '| --- | --- |'
            foreach ($it in $menu.Items) {
                $lab = $it.Label
                foreach ($k in $sub.Keys) { $lab = $lab.Replace($k, $sub[$k]) }
                $lab = ($lab -replace '\{\d+\}', '...') -replace '\|', '\|'
                Add "| $($it.N) | $($lab.Trim()) |"
            }
            Add ''
        }
    }

    Add '## Sharing the machine with games'
    Add ''; Add $Doc.Gaming; Add ''
    Add '## Security'
    Add ''; Add $Doc.Security; Add ''
    Add '## Findings, dead ends, and things that cost hours'
    Add ''; Add $Doc.Findings; Add ''
    Add '## Documentation lookups'
    Add ''; Add $Doc.Docs; Add ''
    Add '## How these docs are generated'
    Add ''
    Add 'This file is produced by `docs.ps1`, which pulls the menu tables (AST-parsed'
    Add 'from every `Menu-*` function), the tunables and models (config.json), and each'
    Add 'script purpose (its header) from the code, and merges them with the narrative'
    Add 'prose maintained in `docs.ps1`. The `hooks/pre-commit` hook regenerates and'
    Add 'stages it on every commit, so it can never drift. Install the hook once with:'
    Add ''
    Add '```powershell'
    Add 'git config core.hooksPath hooks'
    Add '```'
    Add ''

    $out = $sb.ToString() -replace "`r`n", "`n"
    $readme = Join-Path $RepoDir 'README.md'
    [IO.File]::WriteAllText($readme, $out, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "README.md written ($($out.Length) bytes)" -ForegroundColor Green
}

# Run when invoked directly (not when dot-sourced for testing).
if ($MyInvocation.InvocationName -ne '.') { New-Readme }
