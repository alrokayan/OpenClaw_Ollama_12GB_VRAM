# fix.ps1 -- [3] MAINTENANCE / fix things. No admin needed. Run standalone:
#   powershell -ExecutionPolicy Bypass -File .\fix.ps1
#
# TODO (later): Show log (script/Ollama/Android/OpenClaw), Reset script (-> Trash/),
#       deep Installation + Configuration Diagnosis, Local Agent Tests.

if (-not (Get-Command Say -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\common.ps1" }

# Parse-clean + ASCII-only across every section script -- the fast health check.
function Invoke-SelfCheck {
    Say ">>> Script self-check (parse + ASCII-only) ..." Cyan
    $ok = $true
    foreach ($f in 'common.ps1','start_here.ps1','install.ps1','run.ps1','fix.ps1','uninstall.ps1') {
        $p = Join-Path $RepoDir $f
        if (-not (Test-Path $p)) { Warn "$f  (missing)"; $ok = $false; continue }
        $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e)
        $nonAscii = @([IO.File]::ReadAllBytes($p) | Where-Object { $_ -gt 127 }).Count
        if ($e.Count -or $nonAscii) { Warn ("{0}  {1} parse err, {2} non-ASCII byte(s)" -f $f, $e.Count, $nonAscii); $ok = $false }
        else { Ok $f }
    }
    if ($ok) { Ok "all scripts parse clean + ASCII-only." }
    Pause
}

# openclaw doctor -- diagnose config / gateway / plugins / channels.
function Invoke-Doctor {
    if (-not (Test-OpenClaw)) { Warn "OpenClaw not installed."; Pause; return }
    Say ">>> openclaw doctor ..." Cyan
    $ErrorActionPreference = 'Continue'
    openclaw doctor
    $ErrorActionPreference = 'Stop'
    Pause
}

# openclaw reset -- re-init local config/state to defaults; keeps the binary
# installed. Lives here (Maintenance), not Uninstall: it FIXES config, it does
# not remove software. (Wholesale ~/.openclaw removal is Uninstall > Delete data.)
function Reset-ClawConfig {
    if (-not (Test-OpenClaw)) { Warn "OpenClaw not installed."; Pause; return }
    if (-not (Yes "Run 'openclaw reset'? (resets local config/state; keeps the binary)")) { return }
    $ErrorActionPreference = 'Continue'
    openclaw reset
    $ErrorActionPreference = 'Stop'
    Ok "config reset."
    Pause
}

function Menu-Maintenance {
    while ($true) {
        Clear-Host
        Say "== FIX / MAINTENANCE ==" Cyan
        Write-Host ""
        Line 1 "Script self-check (parse + ASCII-only)"
        Line 2 "OpenClaw config check (openclaw doctor)"    (Test-OpenClaw) 'uninstall'
        Line 3 "Reset OpenClaw config (openclaw reset)"     (Test-OpenClaw) 'uninstall'
        Footer
        $c = Read-Choice 3
        if ($null -eq $c) { return }   # 0 / \ / ~ / Esc / blank Enter = back
        switch ($c) {
            '1' { Invoke-SelfCheck }
            '2' { Invoke-Doctor }
            '3' { Reset-ClawConfig }
        }
    }
}

# Run standalone -> show this menu. start_here.ps1 sets OC_Sourced to skip this.
if (-not $global:OC_Sourced) { $global:OC_Entry = $PSCommandPath; Menu-Maintenance }
