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
