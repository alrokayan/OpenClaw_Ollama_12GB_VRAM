# run.ps1 -- [2] OPERATION / run the agent. No admin needed (Auto-start on boot,
# when added, will self-elevate). Run standalone:
#   powershell -ExecutionPolicy Bypass -File .\run.ps1
#
# Core is built (Status, Service Control, Restart, Sessions list/compact, list
# skills/MCPs, Dashboard). Deferred bits are marked TODO (see tmp-menu.md).

if (-not (Get-Command Say -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\common.ps1" }

# --- status ------------------------------------------------------------------
function Row ($label, $on) {
    $tag = if ($on) { 'yes' } else { 'no' }
    $col = if ($on) { 'Green' } else { 'DarkGray' }
    Write-Host ("   {0,-16} " -f $label) -NoNewline
    Write-Host $tag -ForegroundColor $col
}
function Show-Status {
    Clear-Host
    Say "== STATUS ==" Cyan
    Write-Host ""
    Row "OpenClaw"   (Test-OpenClaw)
    Row "configured" (Test-Configured)
    Row "gateway up" (Test-GatewayUp)
    if ($UseOllama) {
        Row "Ollama"     (Test-Ollama)
        Row "ollama up"  (Test-OllamaUp)
        Row "$Model"     ([bool]((ollama list 2>$null | Out-String) -match [regex]::Escape($Model)))
    }
    if ($UseAndroid) {
        Row "AVD created" (Test-Avd)
        Row "device up"   (Test-DeviceUp)
    }
    Pause
}

# --- services ----------------------------------------------------------------
function Start-Ollama {
    if (Test-OllamaUp) { Ok "Ollama already up."; return }
    Start-Process ollama -ArgumentList 'serve' -WindowStyle Hidden
    foreach ($i in 1..15) { if (Test-OllamaUp) { break }; Start-Sleep 1 }
    if (Test-OllamaUp) { Ok "Ollama started." } else { Warn "Ollama did not come up." }
}
function Stop-Ollama    { Get-Process ollama* -ErrorAction SilentlyContinue | Stop-Process -Force; Ok "Ollama stopped." }
function Restart-Ollama { Stop-Ollama; Start-Sleep 1; Start-Ollama }

function Start-Gateway   { $ErrorActionPreference='Continue'; openclaw gateway start   *>$null; $ErrorActionPreference='Stop'; Ok "gateway start issued." }
function Stop-Gateway    { $ErrorActionPreference='Continue'; openclaw gateway stop    *>$null; $ErrorActionPreference='Stop'; Ok "gateway stopped." }
function Restart-Gateway {
    Say ">>> Restarting the OpenClaw gateway..." Cyan
    $ErrorActionPreference='Continue'; openclaw gateway restart *>$null
    foreach ($i in 1..10) { if (Test-GatewayUp) { break }; Start-Sleep 2 }
    $ErrorActionPreference='Stop'
    if (Test-GatewayUp) { Ok "gateway is back up." } else { Warn "gateway did not come up in time." }
    Pause
}

# --- whole-stack control (one button -- handy around gaming) ------------------
# Stop frees ALL the VRAM/CPU: the gateway (which also ends the AVD -- the
# emulator is its child), any straggler emulator/qemu, and the Ollama server
# (which unloads the keep-alive -1 resident model). Start brings Ollama + gateway
# back with the tuned env; the AVD is launched on demand, not here.
function Stop-All {
    Say ">>> Stopping the whole stack (frees VRAM + CPU for gaming)..." Cyan
    $ErrorActionPreference = 'Continue'
    openclaw gateway stop *>$null
    Get-Process emulator, qemu-system-x86_64, crashpad_handler -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process ollama* -ErrorAction SilentlyContinue | Stop-Process -Force
    $ErrorActionPreference = 'Stop'
    Ok "stopped: gateway, AVD, Ollama. VRAM + CPU are free."
    Pause
}
function Start-All {
    Say ">>> Starting the stack (Ollama, then gateway)..." Cyan
    $env:OLLAMA_CONTEXT_LENGTH  = "$NumCtx"
    $env:OLLAMA_KV_CACHE_TYPE   = "$KvCacheType"
    $env:OLLAMA_FLASH_ATTENTION = "$FlashAttn"
    $env:OLLAMA_KEEP_ALIVE      = "$KeepAlive"
    Start-Ollama
    Start-Gateway
    Ok "started: Ollama + gateway. (The AVD launches on demand.)"
    Pause
}

# --- auto-start on boot (THE permanent fix for "connection refused") ----------
# The gateway can come up after a reboot while Ollama's daemon does NOT -- then
# the provider endpoint (:11434) is dead and every agent turn fails. This logon
# Scheduled Task brings Ollama up, WAITS for it, then restarts the gateway, so
# the provider is always live before the agent runs. Needs admin (task register).
$AutoTask = 'OpenClaw Autostart'
function Test-AutoStart { [bool](Get-ScheduledTask -TaskName $AutoTask -ErrorAction SilentlyContinue) }

# Ollama's own installer drops Ollama.lnk in the Startup folder, so Ollama serve
# auto-starts at every logon INDEPENDENT of our Scheduled Task. Fold it into the
# toggle: OFF -> move the shortcut to a backup so NOTHING launches at boot (clean
# for gaming); ON -> restore it. Harmless if our task also starts Ollama (a 2nd
# 'serve' just no-ops on the busy port). No admin needed -- it's the user's folder.
function Set-OllamaAutoStart ($on) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Ollama.lnk'
    $bak = Join-Path $ClawDir 'Ollama.lnk.disabled'
    if ($on) { if ((Test-Path $bak) -and -not (Test-Path $lnk)) { Move-Item $bak $lnk -Force } }
    else     { if (Test-Path $lnk) { New-Item -ItemType Directory -Force $ClawDir | Out-Null; Move-Item $lnk $bak -Force } }
}

function Enable-AutoStart {
    if (-not (Ensure-Admin)) { return }
    Say ">>> Enabling auto-start on boot (Ollama, then gateway)..." Cyan
    $script = "$ClawDir\oc-autostart.ps1"
    $body = @'
# Auto-generated by run.ps1. Brings the LLM provider up before the gateway.
Start-Process ollama -ArgumentList 'serve' -WindowStyle Hidden
foreach ($i in 1..30) { try { Invoke-RestMethod 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2 > $null; break } catch { Start-Sleep 2 } }
openclaw gateway restart
'@
    New-Item -ItemType Directory -Force $ClawDir | Out-Null
    [IO.File]::WriteAllText($script, $body, (New-Object Text.UTF8Encoding($false)))
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $AutoTask -Action $action -Trigger $trigger -Settings $set -RunLevel Highest -Force | Out-Null
    Set-OllamaAutoStart $true   # restore Ollama's own boot shortcut if we'd disabled it
    Ok "auto-start enabled -- Ollama + gateway come up at every logon."
    Pause
}

function Disable-AutoStart {
    if (-not (Ensure-Admin)) { return }
    Unregister-ScheduledTask -TaskName $AutoTask -Confirm:$false -ErrorAction SilentlyContinue
    Set-OllamaAutoStart $false  # also disable Ollama's own Startup shortcut -> clean boot
    Ok "auto-start disabled -- Scheduled Task removed + Ollama boot shortcut disabled (clean boot for gaming)."
    Pause
}

function Menu-Service {
    while ($true) {
        Clear-Host
        Say "== SERVICE CONTROL ==" Cyan
        Row "Ollama"     (Test-OllamaUp)
        Row "gateway"    (Test-GatewayUp)
        Row "auto-start" (Test-AutoStart)
        Write-Host ""
        Line 1 "Start EVERYTHING (Ollama + gateway)"
        Line 2 "Stop EVERYTHING (gateway + AVD + Ollama)"
        Line 3 ("Toggle auto-start on boot  (now: {0})" -f $(if (Test-AutoStart) { 'ON' } else { 'off' }))
        Line 4 "Start Ollama"      ; Line 5 "Stop Ollama"      ; Line 6 "Restart Ollama"
        Line 7 "Start gateway"     ; Line 8 "Stop gateway"     ; Line 9 "Restart gateway"
        Footer
        $c = Read-Choice 9
        if ($null -eq $c) { return }
        switch ($c) {
            '1' { Start-All }
            '2' { Stop-All }
            '3' { if (Test-AutoStart) { Disable-AutoStart } else { Enable-AutoStart } }
            '4' { if ($UseOllama) { Start-Ollama } ; Pause }
            '5' { if ($UseOllama) { Stop-Ollama }  ; Pause }
            '6' { if ($UseOllama) { Restart-Ollama } ; Pause }
            '7' { Start-Gateway   ; Pause }
            '8' { Stop-Gateway    ; Pause }
            '9' { Restart-Gateway }
        }
    }
}

# --- clean-slate reset (the full-session-reset.ps1 flow) ---------------------
# Drop the model + its KV/prompt cache by restarting Ollama with the tuned env,
# wipe the session store (clears stale conversation AND cached skills-prompts),
# then doctor --fix + gateway restart. Used by BOTH "Clear all cache" and Session
# Management > "Reset Telegram session". Driven by config.json ($Model/$NumCtx/
# $KvCacheType/$FlashAttn/$KeepAlive) -- the single source of truth -- in place of
# the original script's hardcoded qwen3.5 / 32768.
function Reset-Session {
    $ErrorActionPreference = 'Continue'
    Say "== 1/3  Stopping $Model + gateway ==" Cyan
    ollama stop $Model
    openclaw gateway stop

    Say "== 2/3  Restarting Ollama (tuned env) + loading $Model ==" Cyan
    while (ollama ps 2>$null | Select-String ([regex]::Escape($Model))) { Start-Sleep -Milliseconds 300 }
    $env:OLLAMA_CONTEXT_LENGTH  = "$NumCtx"
    $env:OLLAMA_KV_CACHE_TYPE   = "$KvCacheType"
    $env:OLLAMA_FLASH_ATTENTION = "$FlashAttn"
    $env:OLLAMA_KEEP_ALIVE      = "$KeepAlive"
    $log = "$env:LOCALAPPDATA\Ollama"
    Start-Process ollama -ArgumentList 'serve' -WindowStyle Hidden -RedirectStandardError "$log\serve-live.log" -RedirectStandardOutput "$log\serve-out.log"
    Invoke-RestMethod 'http://127.0.0.1:11434/api/generate' -Method Post -ContentType 'application/json' -Body ('{"model":"' + $Model + '","keep_alive":-1}') | Out-Null
    while (-not (ollama ps 2>$null | Select-String ([regex]::Escape($Model)))) { Start-Sleep 1 }

    Say "== 3/3  Wiping session store + doctor --fix ==" Cyan
    $sessions = Join-Path $HOME '.openclaw\agents\main\sessions'
    if (Test-Path $sessions) { Remove-Item -Recurse -Force $sessions }
    openclaw doctor --fix
    openclaw gateway restart *>$null
    ollama ps
    $ErrorActionPreference = 'Stop'
    Ok "Reset complete -- the model loads fresh on the next message."
    Pause
}

# --- sessions ----------------------------------------------------------------
$TelegramSession = 'agent:main:telegram'
function Menu-Sessions {
    while ($true) {
        Clear-Host
        Say "== SESSION MANAGEMENT ==" Cyan
        Write-Host ""
        Line 1 "List all sessions"
        Line 2 "Check Telegram context/token status"
        Line 3 "Compact Telegram session ($TelegramSession)"
        Line 4 "Reset Telegram session"
        Footer
        $c = Read-Choice 4
        if ($null -eq $c) { return }
        $ErrorActionPreference = 'Continue'
        switch ($c) {
            '1' { openclaw sessions list; Pause }
            '2' { openclaw sessions list --json 2>$null | Out-String | Write-Host; Pause }
            '3' { openclaw sessions compact --agent main 2>$null; Ok "compact requested."; Pause }
            '4' { Reset-Session }
        }
        $ErrorActionPreference = 'Stop'
    }
}

# --- one-shot operations -----------------------------------------------------
function List-SkillsMcps {
    Clear-Host; $ErrorActionPreference = 'Continue'
    Say "== SKILLS ==" Cyan; openclaw skills list
    Say "`n== MCP servers ==" Cyan; openclaw mcp list
    $ErrorActionPreference = 'Stop'; Pause
}
function Open-Dashboard { $ErrorActionPreference='Continue'; openclaw dashboard; $ErrorActionPreference='Stop'; Ok "dashboard opened."; Pause }

# Open the terminal UI attached to the running gateway. Blocks this console until
# you exit the TUI, then returns to the menu.
function Open-Tui {
    $ErrorActionPreference = 'Continue'
    if (-not (Test-GatewayUp)) { Warn "Gateway is not up -- start it first (Service Control)." }
    else { Say ">>> Opening the TUI (connected to the gateway). Exit the TUI to return here." Cyan; openclaw tui }
    $ErrorActionPreference = 'Stop'; Pause
}

# Approve every PENDING device pairing request via the CLI (house pattern -- do
# not hand-edit ~/.openclaw/devices/paired.json). `devices list --json` returns
# { pending:[...], paired:[...] }; `devices approve --latest` clears the newest
# pending one. Loop, re-listing each pass, and break on no-progress so a --latest
# that fails to approve can't spin. Then restart the gateway to re-read the table.
function Approve-Devices {
    $ErrorActionPreference = 'Continue'
    if (-not (Test-GatewayUp)) { Warn "Gateway is not up -- start it first (Service Control)."; $ErrorActionPreference='Stop'; Pause; return }
    Say ">>> Approving pending device pairing requests..." Cyan
    $n = 0; $prev = -1
    foreach ($i in 1..20) {
        $pending = @((openclaw devices list --json 2>$null | Out-String | ConvertFrom-Json).pending)
        if ($pending.Count -eq 0) { break }
        if ($pending.Count -eq $prev) { Warn "no progress -- approve manually: openclaw devices approve <requestId>"; break }
        $prev = $pending.Count
        openclaw devices approve --latest *>$null
        $n++
    }
    if ($n -gt 0) { Ok "approved $n pending device(s)."; openclaw gateway restart *>$null } else { Ok "no pending devices to approve." }
    $ErrorActionPreference = 'Stop'; Pause
}

# Print Ollama's recommended models for OpenClaw (the catalog carried in
# config.json's _recommendedModels, sourced from the docs URL below). No VRAM
# math -- just the list + the reference so you can pick a model for config.json.
function Recommend-Model {
    Clear-Host
    Say "== RECOMMENDED OLLAMA MODELS FOR OPENCLAW ==" Cyan
    Write-Host ""
    $rm = $cfg._recommendedModels
    if ($rm) {
        Say "  Cloud:" Yellow
        foreach ($p in $rm.cloud.PSObject.Properties)  { Write-Host ("    {0,-20} {1}" -f $p.Name, $p.Value) }
        Write-Host ""
        Say "  Local:" Yellow
        foreach ($p in $rm.local.PSObject.Properties)  { Write-Host ("    {0,-20} {1}" -f $p.Name, $p.Value) }
    } else { Warn "config.json has no _recommendedModels block." }
    Write-Host ""
    Say "  Source: https://docs.ollama.com/integrations/openclaw#recommended-models" DarkGray
    Say ("  Current model (config.json): {0}" -f $Model) Green
    Pause
}

# --- configure openclaw (ongoing config -- moved here from Install) -----------
# Path input. GUI file dialogs do not surface from the VS Code integrated terminal
# (they open behind the editor and hang), so just ask for the full path. Tip:
# drag-and-drop the file/folder into the terminal to paste its (quoted) path --
# we trim the surrounding quotes. '' = cancel.
function Pick-Folder ($desc)          { (Ask "$desc -- full folder path (blank=cancel)").Trim().Trim('"') }
function Pick-File   ($title, $filter) { (Ask "$title -- full file path (blank=cancel)").Trim().Trim('"') }
function Cfg-Patch ($json) {
    $ErrorActionPreference='Continue'; $json | openclaw config patch --stdin *>$null
    if (Test-GatewayUp) { openclaw gateway restart *>$null }; $ErrorActionPreference='Stop'
}
function Install-Mcp {
    $spec = Ask "MCP package (e.g. @mobilenext/mobile-mcp@latest; blank=cancel)"; if (-not $spec) { return }
    $name = Ask "Register it under name" ($spec -replace '.*/','' -replace '@.*','')
    $ErrorActionPreference='Continue'
    openclaw mcp set $name ('{"command":"cmd","args":["/c","npx","-y","'+$spec+'"]}')
    if (Test-GatewayUp) { openclaw gateway restart *>$null }
    $ErrorActionPreference='Stop'; Ok "MCP '$name' registered."; Pause
}
function Install-Skill {
    $path = Pick-Folder 'Pick the skill folder (has SKILL.md) -- Cancel to type a ClawHub/git ref'
    $ErrorActionPreference='Continue'
    if ($path) { openclaw skills install $path }
    else { $r = Ask "ClawHub/git ref (blank=cancel)"; if ($r) { openclaw skills install $r } }
    if (Test-GatewayUp) { openclaw gateway restart *>$null }
    $ErrorActionPreference='Stop'; Pause
}
function Set-Token {
    $t = Ask "Telegram bot token (from @BotFather; blank=cancel)"; if (-not $t) { return }
    [IO.File]::WriteAllText("$ClawDir\.env", "TELEGRAM_BOT_TOKEN=$t`n", (New-Object Text.UTF8Encoding($false)))
    if (Test-GatewayUp) { openclaw gateway restart *>$null }; Ok "token written to ~/.openclaw/.env"; Pause
}
function Set-Thinking {
    $l = Ask "Thinking level (off/minimal/low/medium/high)" 'off'
    Cfg-Patch ('{"agents":{"defaults":{"thinkingDefault":"'+$l+'"}}}'); Ok "thinkingDefault = $l"; Pause
}
function Toggle-Memory {
    $on  = (openclaw config get agents.defaults.memorySearch.enabled 2>$null) -match 'true'
    $new = (-not $on).ToString().ToLower()
    Cfg-Patch ('{"agents":{"defaults":{"memorySearch":{"enabled":'+$new+'}}}}'); Ok "memory = $new"; Pause
}
function Menu-Configure {
    while ($true) {
        Clear-Host; Say "== CONFIGURE OPENCLAW ==" Cyan; Write-Host ""
        Line 1 "Install an MCP  (you give the package)"        (Test-OpenClaw) 'uninstall'
        Line 2 "Install a skill (folder picker / ClawHub ref)" (Test-OpenClaw) 'uninstall'
        Line 3 "Set / reset Telegram bot token"                (Test-OpenClaw) 'uninstall'
        Line 4 "Set agent thinking level"                      (Test-OpenClaw) 'uninstall'
        Line 5 "Enable / disable memory"                       (Test-OpenClaw) 'uninstall'
        Footer
        $c = Read-Choice 5
        if ($null -eq $c) { return }
        switch ($c) { '1' { Install-Mcp } '2' { Install-Skill } '3' { Set-Token } '4' { Set-Thinking } '5' { Toggle-Memory } }
    }
}

# --- APK / XAPK onto the running AVD (an operation, not a system install) ------
function Install-Apk {
    if ($UseAndroid -and -not (Test-DeviceUp)) { Warn "No booted device -- start the AVD first."; Pause; return }
    $p = Pick-File 'Select an APK / XAPK' 'Android package (*.apk;*.xapk)|*.apk;*.xapk'
    if (-not $p) { return }
    $ErrorActionPreference='Continue'
    if ($p -match '\.xapk$') {
        Say ">>> XAPK: extract splits + install-multiple..." Cyan
        $tmp = Join-Path $env:TEMP ('xapk_' + [IO.Path]::GetFileNameWithoutExtension($p))
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        $zip = "$tmp.zip"; Copy-Item $p $zip -Force; Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $apks = (Get-ChildItem $tmp -Filter *.apk).FullName
        if ($apks) { adb -s emulator-5554 install-multiple -r @apks } else { Warn "no split APKs in the XAPK." }
    } else { Say ">>> Installing $(Split-Path $p -Leaf)..." Cyan; adb -s emulator-5554 install -r $p }
    $ErrorActionPreference='Stop'; Pause
}

function Menu-Operation {
    while ($true) {
        Clear-Host
        Say "== RUN / OPERATION ==" Cyan
        Write-Host ""
        Line  1 "Start EVERYTHING (Ollama + gateway)"
        Line  2 "Stop EVERYTHING (gateway + AVD + Ollama)"
        Line  3 "Configure OpenClaw  (opens sub-menu ...)"                    (Test-OpenClaw) 'uninstall'
        Line  4 "Status"
        Line  5 "Clear all cache (reload model + wipe sessions)"  (Test-OpenClaw) 'uninstall'
        Line  6 "Session Management  (opens sub-menu ...)"
        Line  7 "Approve all pending devices"            (Test-GatewayUp)
        Line  8 "List active skills and MCPs"
        Line  9 "Open Dashboard GUI"
        Line 10 "Open TUI"                                (Test-GatewayUp)
        Line 11 "Restart OpenClaw Gateway"
        Line 12 "Service Control  (opens sub-menu ...)"
        Line 13 "Recommended Ollama models for OpenClaw"
        if ($UseAndroid) { Line 14 "Install APK / XAPK onto the AVD" (Test-DeviceUp) }
        Footer
        $c = Read-Choice 14
        if ($null -eq $c) { return }
        switch ($c) {
            '1'  { Start-All }
            '2'  { Stop-All }
            '3'  { Menu-Configure }
            '4'  { Show-Status }
            '5'  { Reset-Session }
            '6'  { Menu-Sessions }
            '7'  { Approve-Devices }
            '8'  { List-SkillsMcps }
            '9'  { Open-Dashboard }
            '10' { Open-Tui }
            '11' { Restart-Gateway }
            '12' { Menu-Service }
            '13' { Recommend-Model }
            '14' { if ($UseAndroid) { Install-Apk } }
        }
    }
}

# Run standalone -> show this menu. start_here.ps1 sets OC_Sourced to skip this.
if (-not $global:OC_Sourced) { $global:OC_Entry = $PSCommandPath; Menu-Operation }
