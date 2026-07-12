# start_here.ps1 -- OpenClaw + Ollama + Android. Start here.
#
# One simple menu. Each section lives in its own file you can ALSO run on its
# own to test:  install.ps1 / run.ps1 / fix.ps1 / uninstall.ps1
# Shared config + feature flags + helpers live in common.ps1 (edit config there).
#
# Run:  powershell -ExecutionPolicy Bypass -File .\start_here.ps1
# Nav:  number + Enter to pick; 0 or blank Enter = back/exit; Ctrl+C = quit.
# Admin: Install + Uninstall self-elevate; Operation + Maintenance run as you.

# Any config.json option can also be passed as an arg (arg > config.json > default):
#   .\start_here.ps1 -Model llama3.1:8b -NumCtx 65536 -KeepAlive 5m
param(
    [string]$Model, [int]$NumCtx, [string]$AvdName,
    [string]$KeepAlive, [string]$KvCacheType, [string]$FlashAttn
)
$OC_Args = @{} + $PSBoundParameters   # capture CLI args before config.json loads

$global:OC_Entry   = $PSCommandPath   # what Ensure-Admin relaunches when elevating
$global:OC_Sourced = $true            # tell the sections NOT to auto-run their menu

. "$PSScriptRoot\common.ps1"          # $Model/$NumCtx/... <- config.json (or defaults)
. "$PSScriptRoot\install.ps1"
. "$PSScriptRoot\run.ps1"
. "$PSScriptRoot\fix.ps1"
. "$PSScriptRoot\uninstall.ps1"
Set-ArgOverrides $OC_Args             # CLI args win over config.json

function Menu-Main {
    while ($true) {
        Clear-Host
        Say "  OpenClaw + Ollama + Android   (12 GB VRAM)" Cyan
        Say "  admin: $(if (Test-Admin) { 'yes' } else { 'no  (Install/Uninstall will elevate)' })" DarkGray
        Write-Host ""
        Line 1 "Install"
        Line 2 "Operation"
        Line 3 "Maintenance"
        Line 4 "Uninstall"
        Footer 'exit'
        $c = Read-Choice
        if ($null -eq $c) { return }
        switch ($c) {
            '1' { Menu-Install }
            '2' { Menu-Operation }
            '3' { Menu-Maintenance }
            '4' { Menu-Uninstall }
        }
    }
}

Menu-Main
