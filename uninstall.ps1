# uninstall.ps1 -- [4] UNINSTALL. Needs Administrator (winget, Disable feature,
# unregister the gateway task). Run standalone:
#   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
# Or reach it from start_here.ps1.
#
# Uninstalls keep your DATA (models, ~/.openclaw) unless you use "Delete data".
# Every destructive delete asks y/N first.

if (-not (Get-Command Say -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\common.ps1" }

# MCP uninstall is generic: OpenClaw manages MCP servers by name in
# openclaw.json. List them, let the user copy-paste the exact name to remove.
function Uninstall-Mcp {
    Say ">>> Installed MCP servers:" Cyan
    $ErrorActionPreference = 'Continue'
    openclaw mcp list
    $ErrorActionPreference = 'Stop'
    $name = Ask "Exact MCP name to remove (blank = cancel)"
    if (-not $name) { return }
    $ErrorActionPreference = 'Continue'
    openclaw mcp unset $name
    if (Test-GatewayUp) { openclaw gateway restart *> $null }
    $ErrorActionPreference = 'Stop'
    Ok "MCP '$name' removed (if it existed)."
    Pause
}

# Skills are just directories under ~/.openclaw/skills (no 'uninstall' verb).
# List them, let the user copy-paste the exact name, remove the dir + reload.
function Uninstall-Skill {
    $skills = Get-ChildItem "$ClawDir\skills" -Directory -ErrorAction SilentlyContinue
    if (-not $skills) { Warn "No skills installed .."; Pause; return }
    Say ">>> Installed skills:" Cyan
    $skills | ForEach-Object { Say "     $($_.Name)" }
    $name = Ask "Exact skill name to remove (blank = cancel)"
    if (-not $name) { return }
    $dir = Join-Path "$ClawDir\skills" $name
    if (-not (Test-Path $dir)) { Warn "no skill named '$name'."; Pause; return }
    if (-not (Yes "Delete skill '$name'?")) { return }
    Remove-Item $dir -Recurse -Force
    if (Test-GatewayUp) { openclaw gateway restart *> $null }
    Ok "skill '$name' removed."
    Pause
}

function Uninstall-Studio {
    Say ">>> Uninstalling Android Studio + SDK..." Cyan
    $ErrorActionPreference = 'Continue'
    winget uninstall --id Google.AndroidStudio --silent --accept-source-agreements 2>$null
    # adb.exe (platform-tools) and any emulator/qemu process lock their own files, so
    # the folder delete below fails while they run. 'adb kill-server' is graceful;
    # then force any stragglers.
    $adb = "$SdkPath\platform-tools\adb.exe"
    if (Test-Path $adb) { & $adb kill-server 2>$null }
    Get-Process adb, emulator, qemu-system-x86_64, crashpad_handler -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # Delete the entire SDK (incl. system-images -- the next install re-pulls the
    # ~8 GB image). AVDs live in ~/.android/avd, NOT here, so they are untouched.
    Remove-Item $SdkPath -Recurse -Force -ErrorAction SilentlyContinue
    $ErrorActionPreference = 'Stop'
    Ok "Android Studio + SDK removed (AVDs in ~/.android/avd are untouched)."
    Pause
}

function Uninstall-OpenClaw {
    Say ">>> Uninstalling OpenClaw (config in ~/.openclaw kept)..." Cyan
    $ErrorActionPreference = 'Continue'
    Get-ScheduledTask -TaskName '*openclaw*' -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    cmd /c "npm uninstall -g openclaw" 2>$null
    $ErrorActionPreference = 'Stop'
    Ok "OpenClaw removed. (Use 'Delete data' to also remove ~/.openclaw.)"
    Pause
}

function Uninstall-Ollama {
    Say ">>> Uninstalling Ollama (MODELS ARE SAFE)..." Cyan
    $ErrorActionPreference = 'Continue'
    Get-Process ollama* -ErrorAction SilentlyContinue | Stop-Process -Force
    winget uninstall --id Ollama.Ollama --silent --accept-source-agreements 2>$null
    $ErrorActionPreference = 'Stop'
    Ok "Ollama removed (models kept -- no re-pull needed later)."
    Pause
}

function Uninstall-Prereqs {
    Say ">>> Uninstalling prerequisites (VCRedist left -- other apps use it)..." Cyan
    $ErrorActionPreference = 'Continue'
    foreach ($id in 'OpenJS.NodeJS','Python.Python.3.12','Microsoft.OpenJDK.17') {
        Say "  removing $id" DarkGray
        winget uninstall --id $id --all-versions --silent --accept-source-agreements 2>$null
    }
    $ErrorActionPreference = 'Stop'
    Ok "prerequisites removed."
    Pause
}

function Reset-ClawConfig {
    if (-not (Yes "Run 'openclaw reset' (resets local config/state; keeps the binary)?")) { return }
    openclaw reset
    Pause
}

function Delete-Avd {
    $ErrorActionPreference = 'Continue'
    $avdmgr = "$SdkPath\cmdline-tools\latest\bin\avdmanager.bat"
    if (Test-Path $avdmgr) { & $avdmgr delete avd -n $AvdName 2>$null }
    Remove-Item "$HOME\.android\avd\$AvdName.avd", "$HOME\.android\avd\$AvdName.ini" -Recurse -Force -ErrorAction SilentlyContinue
    $ErrorActionPreference = 'Stop'
    Ok "AVD deleted."
}

function Disable-HyperV {
    if (-not (Yes "Disable Hyper-V + WHPX? (reboot after)")) { return }
    dism.exe /online /disable-feature /featurename:HypervisorPlatform           /norestart
    dism.exe /online /disable-feature /featurename:Microsoft-Hyper-V-Hypervisor /norestart
    Warn "Reboot to finish disabling."
    Pause
}

function Menu-DeleteData {
    while ($true) {
        Clear-Host
        Say "== DELETE DATA / CONFIG (irreversible) ==" Red
        Line 1 "Delete OpenClaw config  (~/.openclaw)"          (Test-Configured)            'uninstall'
        Line 2 "Delete AVD ($AvdName)"                          (Test-Avd)                   'uninstall'
        Line 3 "Delete Ollama models    (~/.ollama, 6.6 GB)"    (Test-Path "$HOME\.ollama")  'uninstall'
        Line 4 "Delete ALL of the above"
        Footer
        $c = Read-Choice 4
        if ($null -eq $c) { return }
        switch ($c) {
            '1' { if (Yes "Delete ~/.openclaw?")                  { Remove-Item $ClawDir      -Recurse -Force -EA SilentlyContinue; Ok "deleted."; Pause } }
            '2' { if (Yes "Delete the $AvdName AVD?")             { Delete-Avd; Pause } }
            '3' { if (Yes "Delete ~/.ollama models?")             { Remove-Item "$HOME\.ollama" -Recurse -Force -EA SilentlyContinue; Ok "deleted."; Pause } }
            '4' { if (Yes "Delete ~/.openclaw + AVD + ~/.ollama?") { Remove-Item $ClawDir,"$HOME\.ollama" -Recurse -Force -EA SilentlyContinue; Delete-Avd; Ok "all deleted."; Pause } }
        }
    }
}

function Menu-Uninstall {
    if (-not (Ensure-Admin)) { return }   # Uninstall needs Administrator
    while ($true) {
        Clear-Host
        Say "== UNINSTALL ==" Cyan
        Write-Host ""
        Line 1 "Uninstall an MCP"
        Line 2 "Uninstall a skill"
        if ($UseAndroid) { Line 3 "Uninstall Android Studio + SDK (AVD IS SAFE)"   (Test-Studio)   'uninstall' }
        Line 4 "Uninstall OpenClaw"                        (Test-OpenClaw)  'uninstall'
        if ($UseOllama)  { Line 5 "Uninstall Ollama (MODELS IS SAFE)"   (Test-Ollama)   'uninstall' }
        Line 6 "Uninstall Prerequisites (node/python/jdk)"  (Test-Prereqs)  'uninstall'
        Line 7 "Full reset OpenClaw config"
        Line 8 "Delete data / models / AVDs / config files (opens sub-menu ...)"
        Line 9 "Disable Hyper-V + WHPX"                     (Test-HyperV)   'uninstall'
        Footer
        $c = Read-Choice 9
        if ($null -eq $c) { return }
        switch ($c) {
            '1' { Uninstall-Mcp }
            '2' { Uninstall-Skill }
            '3' { if ($UseAndroid) { Uninstall-Studio } }
            '4' { Uninstall-OpenClaw }
            '5' { if ($UseOllama)  { Uninstall-Ollama } }
            '6' { Uninstall-Prereqs }
            '7' { Reset-ClawConfig }
            '8' { Menu-DeleteData }
            '9' { Disable-HyperV }
        }
    }
}

# Run standalone -> show this menu. start_here.ps1 sets OC_Sourced to skip this.
if (-not $global:OC_Sourced) {
    $global:OC_Entry = $PSCommandPath
    Menu-Uninstall
}
