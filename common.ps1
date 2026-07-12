# common.ps1 -- shared config, helpers, and state checks.
#
# Dot-sourced by oc.ps1 and by each section script (install/operations/
# maintenance/uninstall). Everything here is plain and reusable; the sections
# hold the real work. Re-sourcing is harmless (idempotent).

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Config (edit here; every section reads these)
# ---------------------------------------------------------------------------
$RepoDir  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ClawDir  = "$HOME\.openclaw"
$SdkPath  = "$env:LOCALAPPDATA\Android\Sdk"
$SysImage = 'system-images;android-37.1;google_apis_ps16k;x86_64'

# Tunables live in config.json (single source of truth) -- edit it directly or via
# the "Set model / context" menu step. Defaults below apply if a key is missing so
# the scripts always run. These flow into openclaw.json (model + context) and the
# Ollama service env (context / KV cache / keep-alive) at install/config time.
$ConfigPath  = Join-Path $RepoDir 'config.json'
$cfg = if (Test-Path $ConfigPath) { Get-Content $ConfigPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
function CfgGet ($key, $default) { if ($cfg.PSObject.Properties.Name -contains $key) { $cfg.$key } else { $default } }
$Model       = CfgGet 'model'          'qwen3.5:latest'
$NumCtx      = CfgGet 'numCtx'          65536
$AvdName     = CfgGet 'avd'             'Pixel_5'
$KeepAlive   = CfgGet 'keepAlive'       '-1'
$KvCacheType = CfgGet 'kvCacheType'     'q8_0'
$FlashAttn   = CfgGet 'flashAttention'  '1'

# Recommended Ollama models for OpenClaw (https://docs.ollama.com/integrations/openclaw)
# -- the README generator lists these. Cloud names end in ':cloud'.
#   Cloud:
#     kimi-k2.5:cloud     -- Multimodal reasoning with subagents
#     qwen3.5:cloud       -- Reasoning, coding, and agentic tool use with vision
#     glm-5.1:cloud       -- Reasoning and code generation
#     minimax-m2.7:cloud  -- Fast, efficient coding and real-world productivity
#   Local:
#     gemma4              -- Reasoning and code generation locally (~16 GB VRAM)
#     qwen3.5             -- Reasoning, coding, and visual understanding locally (~11 GB VRAM)

# Apply CLI args (an entry script's $PSBoundParameters) ON TOP of the config.json
# values -- precedence becomes: CLI arg > config.json > built-in default. Call it
# right AFTER dot-sourcing this file. Each key must name one of the vars above
# (Model, NumCtx, AvdName, KeepAlive, KvCacheType, FlashAttn); -Scope 1 writes them
# in the caller (entry-script) scope where the sections read them.
function Set-ArgOverrides ($bound) {
    if (-not $bound) { return }
    foreach ($k in $bound.Keys) { Set-Variable -Name $k -Value $bound[$k] -Scope 1 }
}

# ---------------------------------------------------------------------------
# Feature flags (all ON by default)
# ---------------------------------------------------------------------------
#   $UseOllama  = $false -> CLOUD: skip Ollama + model; install OpenClaw via its
#                           web installer (no onboarding).
#   $UseAndroid = $false -> skip Studio + SDK + AVD + iGPU + Mobile-MCP +
#                           Base64-toolkit + Mobile Skill.
$UseOllama  = $true
$UseAndroid = $true

# ---------------------------------------------------------------------------
# Tiny UI helpers
# ---------------------------------------------------------------------------
function Say  ($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Ok   ($m) { Say "  [ok] $m" Green }
function Warn ($m) { Say "  $m"      Yellow }
function Die  ($m) { throw $m }
function Pause    { Say ""; [void](Read-Host "  -- Enter to continue (Ctrl+C to quit) --") }
function Ask ($q, $default = '') {
    $a = Read-Host ("  {0}{1}" -f $q, $(if ($default) { " [$default]" } else { '' }))
    if ([string]::IsNullOrWhiteSpace($a)) { $default } else { $a }
}
function Yes ($q) { (Ask "$q (y/N)" 'n') -match '^[yY]' }

# A numbered menu line, coloured by state + style:
#   install   : installed -> Green, not installed -> White
#   uninstall : installed -> White, not installed -> DarkGray (greyed out)
#   stateless ($on = $null) -> White (a plain action, no on/off state)
function Line ($num, $text, $on = $null, $style = 'install') {
    $color =
        if     ($null -eq $on)          { 'White' }
        elseif ($style -eq 'uninstall') { if ($on) { 'White' } else { 'DarkGray' } }
        else                            { if ($on) { 'Green' } else { 'White' } }
    Write-Host ("  {0,2}) {1}" -f $num, $text) -ForegroundColor $color
}

# Same footer on every menu. Esc cannot be captured by line input across hosts,
# so the back/exit keys are 0 and the key just below Esc: \ (Mac) or ~ (Windows).
function Footer ($back = 'back') {
    Write-Host ""
    Write-Host ("   0  \  ~  = $back      (blank Enter = $back;  Ctrl+C = quit)") -ForegroundColor DarkGray
}

# Read a menu choice as a SINGLE keypress (no Enter) where it is unambiguous.
#   1-9  : selects immediately when no longer number is possible (<= $Max);
#          otherwise waits for the 2nd digit (10, 11) then Enter.
#   0 \ ~ Esc : back/exit on ONE press (0 only when nothing is typed yet).
#   Ctrl+C    : quit. Returns the number string, or $null for back/exit.
function Read-Choice ($Max = 9) {
    $buf = ''
    while ($true) {
        $k = [Console]::ReadKey($true)
        if (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq [ConsoleKey]::C) { Write-Host ""; exit }
        $ch = $k.KeyChar
        if ($k.Key -eq [ConsoleKey]::Escape -or $ch -eq '\' -or $ch -eq '~') { Write-Host ""; return $null }
        if ($k.Key -eq [ConsoleKey]::Enter)     { Write-Host ""; if ($buf) { return $buf } else { return $null } }
        if ($k.Key -eq [ConsoleKey]::Backspace) { if ($buf) { $buf = $buf.Substring(0, $buf.Length - 1); Write-Host "`b `b" -NoNewline }; continue }
        if ($ch -eq '0') {
            if ($buf -eq '') { Write-Host ""; return $null }   # 0 alone = back
            $buf += '0'; Write-Host '0' -NoNewline
        } elseif ($ch -match '[1-9]') {
            $buf += $ch; Write-Host $ch -NoNewline
        } else { continue }
        if ([int]$buf * 10 -gt $Max) { Write-Host ""; return $buf }   # no longer number possible -> act now
    }
}

# Refresh PATH in THIS session from the registry (Machine + User), so a tool
# winget just installed resolves immediately -- no need to close + reopen.
function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}

# Human-readable size of a folder (sum of file lengths), computed live so menus
# never show a stale hardcoded number. Fast for few-big-file dirs like ~/.ollama;
# avoid calling it every redraw on huge many-file trees (it walks every file).
function Get-FolderSize ($path) {
    if (-not (Test-Path $path)) { return '0 B' }
    $b = (Get-ChildItem $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if (-not $b) { return '0 B' }
    $u = 'B','KB','MB','GB','TB'; $i = 0
    while ($b -ge 1024 -and $i -lt 4) { $b = $b / 1024; $i++ }
    '{0:N1} {1}' -f $b, $u[$i]
}

# ---------------------------------------------------------------------------
# State detection (fast booleans -- drive the green/grey menu colouring)
# ---------------------------------------------------------------------------
function Have ($bin)     { [bool](Get-Command $bin -ErrorAction SilentlyContinue) }
# HypervisorPresent (CIM) is fast and works in PS 7. Get-WindowsOptionalFeature
# errors ("Class not registered") / is slow under PS 7, so avoid it for checks.
function Test-HyperV     { try { [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch { $false } }
function Test-DevMode    { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense -eq 1 }
function Test-Prereqs    { (Have node) -and (Have python3) }
function Test-Ollama     { Have ollama }
function Test-Studio     { Test-Path "$SdkPath\cmdline-tools\latest\bin\sdkmanager.bat" }
function Test-Avd        { Test-Path "$HOME\.android\avd\$AvdName.avd" }
function Test-Igpu       { $exe = "$SdkPath\emulator\emulator.exe"; [bool](((Get-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name $exe -ErrorAction SilentlyContinue).$exe) -match 'GpuPreference=1') }
function Test-OpenClaw   { Have openclaw }
function Test-Configured { Test-Path "$ClawDir\openclaw.json" }
function Test-OllamaUp   { try { Invoke-RestMethod 'http://127.0.0.1:11434/api/tags' -TimeoutSec 2 > $null; $true } catch { $false } }
# These shell out to native tools that print to stderr / exit non-zero when the
# gateway or device is DOWN. Under the global $ErrorActionPreference='Stop' that is
# a TERMINATING error (which *>$null cannot swallow -- it redirects streams, not
# exceptions), and since these run while DRAWING the menu, one throw breaks the
# whole menu. Force Continue locally + try/catch so a down service just reads false.
function Test-GatewayUp  { try { $ErrorActionPreference = 'SilentlyContinue'; openclaw gateway status *> $null; $LASTEXITCODE -eq 0 } catch { $false } }
function Test-DeviceUp    { try { $ErrorActionPreference = 'SilentlyContinue'; (adb shell getprop sys.boot_completed 2>$null | Out-String).Trim() -eq '1' } catch { $false } }
function Test-Skill ($m) { [bool](Get-ChildItem "$ClawDir\skills" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$m*" }) }

# ---------------------------------------------------------------------------
# Admin / elevation (only Install + Uninstall need it)
# ---------------------------------------------------------------------------
function Test-Admin {
    (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# Relaunch the entry script elevated if we are not admin. $global:OC_Entry is set
# by whichever script was actually run (oc.ps1, or a section run standalone).
# Returns $true if already admin, otherwise relaunches + exits (or $false if the
# user declines).
function Ensure-Admin {
    if (Test-Admin) { return $true }
    Warn "This needs Administrator."
    if (Yes "Relaunch elevated now?") {
        Start-Process powershell -Verb RunAs -ArgumentList `
            '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$($global:OC_Entry)`""
        exit
    }
    return $false
}
