#Requires -Version 5.1

<#
.SYNOPSIS
    OpenClaw + Ollama, Lite. A local AI agent on Telegram, backed by a
    model served from your own GPU. No Android, no MCP, no device control.

.DESCRIPTION
    This is the base script. It installs and configures:

      - Ollama serving qwen3.5:latest, context capped to 65536
      - The OpenClaw gateway, bound to loopback
      - A Telegram bot, DM-allowlisted to one user id
      - DuckDuckGo web search (key-free)
      - The Control UI dashboard

    It is ALSO a library. OpenClaw_Ollama_12GB_VRAM_Full.ps1 sets
    $global:OC_NoAutoStart, dot-sources this file, flips the flags in
    $global:OC_Features, appends its own menu items, and calls Start-Menu.
    Nothing in this file is duplicated there.

      $OC_Features.Android     Android Studio, SDK, Pixel_5 AVD, Hyper-V
      $OC_Features.Mcp         scrcpy-mcp as an MCP server
      $OC_Features.DroidClaw   the DroidClaw device-control skill

    WHY THE CONTEXT IS CAPPED

    qwen3.5 advertises a 262144-token window. That KV cache does not fit a
    12 GB card. Three numbers are set equal so they cannot diverge:
    contextTokens (the effective budget OpenClaw compacts against),
    contextWindow (the advertised window), and params.num_ctx (what Ollama
    actually allocates). Let any exceed num_ctx and OpenClaw believes it has
    room Ollama never gave it, and the tail of every prompt is silently
    truncated.

    "openclaw doctor --fix" also raises num_ctx back to the advertised
    window. The cap is re-applied afterwards, then verified with
    "ollama ps", which must still report 100% GPU.

    CONFIGURATION SAFETY

    Config is written with "openclaw config patch", never by editing the
    JSON. Every patch is dry-run first. OpenClaw validates the full
    post-change config before committing; an invalid payload leaves the
    active config untouched and lands as openclaw.json.rejected.*

    This matters: an invalid openclaw.json makes "doctor --fix" silently
    restore the last-known-good copy and discard every change, saving
    yours as .clobbered.* with no loud error. Hence "config validate" runs
    before doctor, and the script aborts rather than let doctor loose on a
    bad config.

    The models array is a protected path. "config patch" replaces arrays
    wholesale, which would strip fields Ollama's onboarding set --
    including compat.supportsTools. Losing that is not cosmetic: the model
    is then never offered tools, and will narrate shell commands as prose
    instead of calling anything. So the model entry is merged by id with
    "config set --strict-json --merge".

.PARAMETER None
    No parameters. Edit the settings block near the top before first run.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\OpenClaw_Ollama_12GB_VRAM_Lite.ps1

    Opens the menu.

.EXAMPLE
    .\OpenClaw_Ollama_12GB_VRAM_Lite.ps1 -NumCtx 32768 -NoDashboard

    Overrides. -NumCtx is range-validated, so a typo fails at parse time
    rather than halfway through configuring the gateway.

.EXAMPLE
    $f = "$env:TEMP\OpenClaw_Lite.ps1"
    irm https://raw.githubusercontent.com/alrokayan/OpenClaw_Ollama_12GB_VRAM/main/OpenClaw_Ollama_12GB_VRAM_Lite.ps1 -OutFile $f
    Unblock-File $f
    & $f

    One-liner install. NOT "irm ... | iex": this script has #Requires and a
    param() block, and neither survives Invoke-Expression. Saving to a file
    also keeps $PSCommandPath set, which self-elevation and the docs
    generator both need.

    This executes remote code with no review and no integrity check. The
    file is sitting in $env:TEMP -- read it before you let it run.

.NOTES
    DISCLAIMER
              Run at your own risk. No warranty of any kind. This script
              installs system-level components, writes to the registry, and
              creates a Scheduled Task. Its uninstall path irreversibly
              deletes ~/.openclaw and optionally ~/.ollama (your models).
              Read it before running it.

              The Telegram bot token is stored in plaintext in .\env and
              ~/.openclaw/.env. Anyone who can read those controls the bot.

    Keys      Up/Down move, Enter run, R refresh state, Home/End jump,
              1-9 and 0 select directly, Esc quit.

    Requires  Windows PowerShell 5.1 or later, run as Administrator.

    Encoding  Every file this script writes is UTF-8 without a BOM, via
              [IO.File]::WriteAllText / WriteAllLines. Set-Content
              -Encoding utf8 emits a BOM on PS 5.1, and ">" redirection
              emits UTF-16LE. Both corrupt files that other tools parse.

    ASCII     The script contains no non-ASCII characters. Box-drawing
              glyphs and em dashes become mojibake in consoles that are not
              on a UTF-8 code page, and a mangled character inside a string
              can break parsing outright.

    Debugging If the agent narrates shell commands instead of calling
              tools, run the test suite before blaming the model.

.LINK
    https://github.com/alrokayan/OpenClaw_Ollama_12GB_VRAM
.LINK
    https://docs.openclaw.ai
.LINK
    https://docs.ollama.com/integrations/openclaw
#>

## ============================================================
##  Parameters
##
##  Defaults are the values this build was tuned for. Override on the
##  command line rather than editing the file:
##
##      .\OpenClaw_Ollama_12GB_VRAM_Lite.ps1 -NumCtx 32768 -NoDashboard
##
##  Full forwards its own parameters here when it dot-sources this file.
## ============================================================
[CmdletBinding()]
param(
    ## Your numeric Telegram user id. Message @userinfobot to find it.
    [string]$TelegramId = "6420885035",

    [string]$Model = "qwen3.5:latest",

    ## contextTokens, contextWindow, and num_ctx are all set to this, or the
    ## prompt is silently truncated. 65536 is what fits a 12 GB card once the
    ## model is loaded. Drop to 32768 if "ollama ps" stops reporting 100% GPU.
    [ValidateRange(4096, 262144)]
    [int]$NumCtx = 65536,

    [ValidateRange(1024, 65535)]
    [int]$GatewayPort = 18789,

    [string]$AvdName = "Pixel_5",

    [string]$SysImage = "system-images;android-37.1;google_apis_ps16k;x86_64",

    ## Omit the controlUi block from openclaw.json. The dashboard is served
    ## by the gateway either way; without this it refuses your token over
    ## plain http on loopback.
    [switch]$NoDashboard,

    [string]$LicenseHolder = "Mohammed Alrokayan",

    ## Skip the elevation prompt. Most steps fail unelevated; Status check
    ## and the docs generator do not.
    [switch]$NoElevate,

    ## Unattended mode: never block on a human. Read-Host prompts return their
    ## safe default (via Read-Prompt), Invoke-Step drops its "press any key"
    ## pause, and the OpenClaw onboarding TUI is launched detached and killed
    ## once it has written its config instead of waiting for you to exit it.
    ## The ONE thing it cannot bypass is the Android Studio setup wizard (a GUI
    ## with no headless entry point); that step still pauses unless the SDK is
    ## already installed. Can also be forced with $env:OC_UNATTENDED = "1".
    [switch]$Unattended,

    ## Package that the .xapk step installs when unattended, so it does not pop
    ## a file picker. Relative paths resolve against the script directory.
    [string]$AutoXapkPath = "",

    ## Run every menu step in order (both editions), non-interactively, writing
    ## full_test_report.md. Implies -Unattended. Ends in the DESTRUCTIVE
    ## uninstall -- only for a throwaway/VM box. See Start-FullTest.
    [switch]$RunAll,

    ## Launch/relaunch the AVD (cold boot) and exit, without opening the menu.
    ## Full edition only (needs the emulator); a CLI shortcut for the menu's
    ## "Launch / relaunch the AVD" item.
    [switch]$StartAvd
)

$ErrorActionPreference = "Stop"

## ------------------------------------------------------------
##  Who is the entry point?
##
##  When Full dot-sources this file, $PSCommandPath here points at LITE.
##  Relaunching that for elevation would silently drop Android, MCP, and
##  the skill. So the first script to load records itself, and Full sets
##  these before dot-sourcing us.
## ------------------------------------------------------------
if (-not $global:OC_EntryScript) {
    $global:OC_EntryScript = $PSCommandPath
    $global:OC_EntryArgs   = $PSBoundParameters
}

## The dashboard is not a separate install: it is the Control UI, served by
## the gateway at http://127.0.0.1:<port>/ . This only decides whether we
## configure it for plain-http localhost auth. Set $false to leave the
## controlUi block out of the config entirely.
## -NoDashboard inverts to the flag the rest of the script reads.
$EnableDashboard = -not $NoDashboard

$LicenseYear = (Get-Date).Year
$RepoUrl       = "https://github.com/alrokayan/OpenClaw_Ollama_12GB_VRAM"

## Raw file base. Check your repo's default branch: GitHub has used "main"
## since 2020, but older repos are still on "master". The longer
## /refs/heads/<branch>/ form also works and resolves to the same file.
$RepoBranch    = "main"
$RepoRaw       = "https://raw.githubusercontent.com/alrokayan/OpenClaw_Ollama_12GB_VRAM/$RepoBranch"

$BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$EnvFile = Join-Path $BaseDir "env"

## Every menu step is transcribed here, one file per run. The folder is
## gitignored (transcripts can capture tokens echoed by openclaw/adb output),
## created on demand by Invoke-Step, and never committed. Kept next to the
## script so a failed run leaves a readable trail where you launched it.
$LogDir = Join-Path $BaseDir "logs"

## ============================================================
##  Feature flags
##
##  Lite ships with all of these off. The Full script dot-sources this
##  file, flips them on, appends its own menu items, and starts the menu.
##  Nothing in this file is duplicated there.
##
##  Shared steps consult these flags rather than being rewritten, so
##  there is exactly one implementation of "configure OpenClaw", "run the
##  test suite", and "uninstall".
## ============================================================
if (-not (Get-Variable -Name OC_Features -Scope Global -ErrorAction SilentlyContinue)) {
    $global:OC_Features = @{
        Android   = $false   # Android Studio, SDK, the Pixel_5 AVD, Hyper-V/WHPX
        Mcp       = $false   # scrcpy-mcp registered as an MCP server
        DroidClaw = $false   # the DroidClaw skill
    }
}
$Features = $global:OC_Features

## Shown in the banner. Full overrides this before calling Start-Menu.
if (-not $script:Edition) { $script:Edition = "Lite" }

## ------------------------------------------------------------
##  Unattended mode
##
##  -RunAll implies it. $env:OC_UNATTENDED=1 forces it (useful when Full
##  relaunches elevated and switch state is awkward to forward). When on,
##  every human wait point degrades to a safe default instead of blocking.
## ------------------------------------------------------------
$Unattended = [bool]$Unattended -or [bool]$RunAll -or [bool]$StartAvd -or ($env:OC_UNATTENDED -eq '1')

## ============================================================
##  Helpers
## ============================================================

## Read-Host that cannot block a headless run. Interactively it prompts as
## usual; unattended it announces and returns $Default, so callers keep their
## normal "answer or hit the default" control flow with no special-casing.
function Read-Prompt {
    param([string]$Prompt, [string]$Default = "")
    if ($Unattended) {
        Write-Host "  [auto] $Prompt -> '$Default'" -ForegroundColor DarkGray
        return $Default
    }
    Read-Host $Prompt
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Rule {
    param([string]$Text = "", [string]$Color = "DarkGray")
    if ($Text) {
        $pad = "-" * [Math]::Max(0, 58 - $Text.Length)
        Write-Host "  -- $Text $pad" -ForegroundColor $Color
    } else {
        Write-Host ("  " + ("-" * 62)) -ForegroundColor $Color
    }
}

## ------------------------------------------------------------
##  Environment state
##
##  Cached, not recomputed per keypress. Some of these probes spawn
##  processes (ollama list, adb devices) or query DISM (Hyper-V), which
##  would make arrow keys feel laggy. Refreshed at startup, after every
##  step, and on demand with R.
## ------------------------------------------------------------
$script:Env = @{}

function Update-EnvState {
    ## Pure probing -- it must NEVER throw. Under the global Stop preference,
    ## native tools writing to stderr (adb "daemon not running", ollama, npm)
    ## raise a terminating NativeCommandError even with 2>$null. That once
    ## killed the -RunAll report writer mid-loop. Continue keeps probes benign.
    $ErrorActionPreference = 'Continue'
    $s = @{}

    $s.Npm      = [bool](Get-Command npm      -ErrorAction SilentlyContinue)
    $s.Npx      = [bool](Get-Command npx      -ErrorAction SilentlyContinue)
    $s.Adb      = [bool](Get-Command adb      -ErrorAction SilentlyContinue)
    $s.Scrcpy   = [bool](Get-Command scrcpy   -ErrorAction SilentlyContinue)
    $s.Emulator = [bool](Get-Command emulator -ErrorAction SilentlyContinue)
    $s.Ollama   = [bool](Get-Command ollama   -ErrorAction SilentlyContinue)
    $s.OpenClaw = [bool](Get-Command openclaw -ErrorAction SilentlyContinue)

    $s.Token = [bool](Get-SavedToken)
    $s.Avd   = Test-Path "$env:USERPROFILE\.android\avd\$AvdName.avd"

    $cfgFile = "$env:USERPROFILE\.openclaw\openclaw.json"
    $s.Cfg   = Test-Path $cfgFile

    ## Is the Control UI actually configured for plain-http loopback auth?
    ##
    ## Read the file, not $EnableDashboard: that variable describes what THIS
    ## session would write, while the gateway obeys what is already on disk.
    ## A config written when $EnableDashboard was $false has no controlUi block,
    ## and the Control UI will refuse the token over http://127.0.0.1 no matter
    ## what the variable says today.
    ##
    ## Parsed straight from JSON -- no process spawn, so this stays cheap enough
    ## to run on every state refresh.
    $s.ControlUi = $false
    if ($s.Cfg) {
        try {
            $j = Get-Content $cfgFile -Raw -ErrorAction Stop | ConvertFrom-Json
            $s.ControlUi = ($j.gateway.controlUi.allowInsecureAuth -eq $true)
        } catch {
            ## Invalid JSON. Leave $false; the "schema valid" check will surface it.
        }
    }

    ## True when the session setting and the on-disk config disagree, which
    ## means step 7 needs re-running for the change to take effect.
    $s.DashboardDrift = ($EnableDashboard -ne $s.ControlUi) -and $s.Cfg

    ## DISM query is slow (~1s) and needs elevation to be meaningful
    $s.HyperV = $false
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction Stop
        $s.HyperV = ($f.State -eq 'Enabled')
    } catch { }

    ## Model presence: one process spawn, cached
    $s.Model = $false
    if ($s.Ollama) {
        $s.Model = (ollama list 2>$null | Out-String) -match [regex]::Escape($Model.Split(':')[0])
    }

    ## Device attached (not the same as booted -- booting is checked in the suite)
    $s.Device = $false
    if ($s.Adb) {
        $s.Device = @(adb devices 2>$null | Where-Object { $_ -match '^\S+\s+device\s*$' }).Count -gt 0
    }

    $s.ScrcpyMcp = $false
    if ($s.Npm) {
        $s.ScrcpyMcp = [bool](npm list -g --depth=0 2>$null | Select-String scrcpy-mcp)
    }

    ## Anything at all to tear down?
    $s.Installed = $s.OpenClaw -or $s.Cfg -or $s.Avd -or $s.Ollama -or
                   (Test-Path "C:\Program Files\Android")

    $script:Env = $s
}


## ---- Telegram token -----------------------------------------
## Lives in .\env as TELEGRAM_BOT_TOKEN=... . The token never lands in
## openclaw.json: that file holds the literal "${TELEGRAM_BOT_TOKEN}",
## which the gateway resolves at config load.

function Get-SavedToken {
    if (-not (Test-Path $EnvFile)) { return $null }
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match '^\s*TELEGRAM_BOT_TOKEN\s*=\s*(.+?)\s*$') { return $matches[1] }
    }
    return $null
}

function Set-SavedToken {
    Write-Host "Get a token from @BotFather in Telegram (/newbot)." -ForegroundColor DarkGray
    Write-Host "It looks like 1234567890:AA... and is about 46 characters." -ForegroundColor DarkGray
    Write-Host ""

    ## -AsSecureString keeps it off screen and out of console history
    $secure = Read-Host "Paste the bot token" -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    if ([string]::IsNullOrWhiteSpace($plain)) { throw "No token entered." }
    if ($plain -notmatch '^\d+:[A-Za-z0-9_-]+$') {
        Write-Host "That does not look like a Telegram bot token." -ForegroundColor Yellow
        if ((Read-Host "Save it anyway? (y/N)") -ne 'y') { throw "Aborted." }
    }

    $keep = @()
    if (Test-Path $EnvFile) {
        $keep = Get-Content $EnvFile | Where-Object { $_ -notmatch '^\s*TELEGRAM_BOT_TOKEN\s*=' }
    }
    ## UTF-8 without BOM. Set-Content -Encoding utf8 writes a BOM on PS 5.1,
    ## which lands inside the first key name and breaks the parse.
    [IO.File]::WriteAllLines($EnvFile, @($keep) + "TELEGRAM_BOT_TOKEN=$plain",
        (New-Object Text.UTF8Encoding($false)))

    Write-Host ""
    Write-Host "Saved to $EnvFile" -ForegroundColor Green
    Write-Host "Anyone who can read that file can control your bot." -ForegroundColor Yellow
}

## ---- File lock breaker (Windows Restart Manager) -------------
## openclaw.sqlite is the usual EBUSY offender during uninstall.

function Kill-FileLock {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return }
    $Path = (Resolve-Path $Path).Path

    $sig = @'
using System;
using System.Runtime.InteropServices;
public class RmApi {
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmStartSession(out uint h, int f, string key);
    [DllImport("rstrtmgr.dll")]
    public static extern int RmEndSession(uint h);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmRegisterResources(uint h, uint nFiles, string[] files, uint nApps, IntPtr apps, uint nSvcs, string[] svcs);
    [DllImport("rstrtmgr.dll")]
    public static extern int RmGetList(uint h, out uint needed, ref uint have, [In, Out] RM_PROCESS_INFO[] info, ref uint reasons);

    [StructLayout(LayoutKind.Sequential)]
    public struct RM_UNIQUE_PROCESS { public int pid; public System.Runtime.InteropServices.ComTypes.FILETIME startTime; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string strServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
}
'@
    Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue

    [uint32]$h = 0
    if ([RmApi]::RmStartSession([ref]$h, 0, [Guid]::NewGuid().ToString()) -ne 0) { return }

    try {
        if ([RmApi]::RmRegisterResources($h, 1, @($Path), 0, [IntPtr]::Zero, 0, $null) -ne 0) { return }

        [uint32]$needed = 0; [uint32]$have = 0; [uint32]$reasons = 0
        [RmApi]::RmGetList($h, [ref]$needed, [ref]$have, $null, [ref]$reasons) | Out-Null
        if ($needed -eq 0) { return }

        $have = $needed
        $info = New-Object RmApi+RM_PROCESS_INFO[] $have
        [RmApi]::RmGetList($h, [ref]$needed, [ref]$have, $info, [ref]$reasons) | Out-Null

        for ($i = 0; $i -lt $have; $i++) {
            $procId = $info[$i].Process.pid
            $procName = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
            try {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                Write-Host "  killed PID $procId ($procName)" -ForegroundColor Yellow
            } catch {
                Write-Host "  could not kill PID $procId ($procName)" -ForegroundColor Red
            }
        }
    } finally {
        [RmApi]::RmEndSession($h) | Out-Null
    }
}

## ---- Config patch -------------------------------------------
## Dry-run every patch first. A payload that fails schema validation
## leaves the config untouched and lands in openclaw.json.rejected.*
## instead of poisoning the file and letting 'doctor --fix' silently
## revert everything to last-known-good.

function Patch {
    param([string]$Label, [string]$Json)
    Write-Host "`n>>> $Label" -ForegroundColor Cyan
    $Json | openclaw config patch --stdin --dry-run
    if ($LASTEXITCODE -ne 0) { throw "Dry-run failed: $Label" }
    $Json | openclaw config patch --stdin
    if ($LASTEXITCODE -ne 0) { throw "Patch failed: $Label" }
}

## ---- Clamp the model's context to $Cap, robustly ----------------
## Sets contextWindow, contextTokens, and params.num_ctx on the ollama model
## entry, ALL equal to $Cap, without losing sibling fields or leaving a duplicate.
##
## The write goes through the Patch helper ('openclaw config patch --stdin') --
## NEVER inline JSON as a native-command argument. Passing JSON as an argument is
## unsafe on Windows PowerShell 5.1: openclaw.cmd re-expands %* into node and the
## embedded double quotes get stripped, corrupting the entry's "id". OpenClaw
## then treats the id-less entry as new and APPENDS it (merge-by-id, per
## src/config/merge-patch.ts), leaving a DUPLICATE; the resolver reads the first
## (doctor's 262144) and the model runs on CPU. Piping via --stdin carries the
## JSON verbatim past all shell quoting (portable across 5.1 and PS7), and
## 'config patch' also clears the protected-path gate that a raw 'config set' on
## models.* would need --replace for. ('config set --batch-file' is an equivalent
## file-based route; both beat inline JSON -- see the README Windows-findings.)
##
## config patch REPLACES arrays, so read the current entry to carry EVERY field
## forward -- compat.supportsTools (lose it and the model narrates instead of
## calling tools), input:["text","image"] (vision, for the screenshot loop),
## reasoning, cost -- de-dupe by id, set the three context fields, and patch the
## whole de-duped array back.
function Set-ModelContextCap {
    param([int]$Cap)
    $models = @(openclaw config get models.providers.ollama.models --json 2>$null | Out-String | ConvertFrom-Json)
    if (-not $models -or $models.Count -eq 0) { throw "No models.providers.ollama.models to clamp." }

    ## de-dupe by id, keep first occurrence of each
    $seen = @{}; $dedup = @()
    foreach ($e in $models) { if ($e.id -and -not $seen.ContainsKey($e.id)) { $seen[$e.id] = $true; $dedup += $e } }

    $m = @($dedup | Where-Object { $_.id -eq $Model })[0]
    if (-not $m) { throw "No '$Model' entry in models.providers.ollama.models to clamp." }
    $m.contextWindow = $Cap
    if ($m.PSObject.Properties.Name -contains 'contextTokens') { $m.contextTokens = $Cap }
    else { $m | Add-Member -NotePropertyName contextTokens -NotePropertyValue $Cap -Force }
    if (-not $m.params) { $m | Add-Member -NotePropertyName params -NotePropertyValue ([PSCustomObject]@{}) -Force }
    if ($m.params.PSObject.Properties.Name -contains 'num_ctx') { $m.params.num_ctx = $Cap }
    else { $m.params | Add-Member -NotePropertyName num_ctx -NotePropertyValue $Cap -Force }

    ## Patch the whole (de-duped) models array. -Depth deep: nested
    ## compat/cost/params/input. Patch pipes it via stdin and dry-runs first.
    $patchObj = @{ models = @{ providers = @{ ollama = @{ models = @($dedup) } } } }
    Patch "context clamp to $Cap" (ConvertTo-Json $patchObj -Depth 40)
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    Clear-Host

    ## Transcribe the whole step to .\logs\ . Best-effort: a logging failure
    ## (locked dir, transcription unsupported in the host) must never abort a
    ## real step, so every transcript call is guarded and $logFile falls back to
    ## $null. Started before the banner so the log includes it.
    $logFile = $null
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $slug = ($Name -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
        if (-not $slug) { $slug = "step" }
        $logFile = Join-Path $LogDir ("{0}_{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $slug)
        Start-Transcript -Path $logFile -Force -ErrorAction Stop | Out-Null
    } catch {
        $logFile = $null
    }

    Write-Host ""
    Write-Host "  +--------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  | " -ForegroundColor DarkCyan -NoNewline
    Write-Host $Name.PadRight(60).Substring(0, 60) -ForegroundColor White -NoNewline
    Write-Host " |" -ForegroundColor DarkCyan
    Write-Host "  +--------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $failed = $false
    try {
        & $Body
    } catch {
        $failed = $true
        Write-Host ""
        Write-Host "  ####  FAILED  ####" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        if ($_.InvocationInfo.ScriptLineNumber) {
            Write-Host "  at line $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkRed
        }
    }
    $sw.Stop()

    Write-Host ""
    if ($failed) {
        Write-Host "  [ FAILED ] " -ForegroundColor Red -NoNewline
    } else {
        Write-Host "  [ DONE ] " -ForegroundColor Green -NoNewline
    }
    Write-Host "$Name " -ForegroundColor Gray -NoNewline
    Write-Host ("({0:mm}m {0:ss}s)" -f $sw.Elapsed) -ForegroundColor DarkGray

    ## Close the transcript before the pause so the file is flushed and the path
    ## is printed for the operator. Guarded: Stop-Transcript throws if none runs.
    if ($logFile) {
        try { Stop-Transcript | Out-Null } catch { }
        Write-Host "  log: $logFile" -ForegroundColor DarkGray
    }

    ## Unattended (e.g. -RunAll) must not wait on a keypress. Return a result the
    ## runner can record; interactive callers ignore it and just get the pause.
    if (-not $Unattended) {
        Write-Host ""
        Write-Host "  Press any key to return to the menu..." -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    }
    [PSCustomObject]@{ Name = $Name; Failed = $failed; Elapsed = $sw.Elapsed; Log = $logFile }
}

## ============================================================
##  Step 1 -- prerequisites
## ============================================================
$StepPrereqs = {
    ## Store python stubs shadow a real install
    Remove-Item "$env:LOCALAPPDATA\Microsoft\WindowsApps\python.exe"  -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Microsoft\WindowsApps\python3.exe" -ErrorAction SilentlyContinue

    ## winget install takes ONE id per call. Passing several silently
    ## installs only the first.
    ##
    ## No jq: config goes through "openclaw config patch" and paired.json
    ## through ConvertFrom-Json. No Python: nothing here calls it.
    $packages = @('Git.Git','7zip.7zip','OpenJS.NodeJS','Ollama.Ollama')
    if ($Features.Android) {
        ## scrcpy ships adb; the JDK and ffmpeg are for Android Studio
        $packages += @('Microsoft.OpenJDK.17','Genymobile.scrcpy','Gyan.FFmpeg')
    }
    foreach ($p in $packages) {
        Write-Host "installing $p" -ForegroundColor DarkGray
        winget install -e --id $p --accept-source-agreements --accept-package-agreements
    }

    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v "AllowDevelopmentWithoutDevLicense" /d "1"
    winget install Microsoft.VCRedist.2015+.x64 --accept-source-agreements --accept-package-agreements

    ## Allow local scripts for this process only -- do not change the
    ## machine policy on someone's behalf.
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

    ## Files downloaded from the web carry a mark-of-the-web alternate data
    ## stream and refuse to run. $BaseDir is the current directory when this
    ## was piped from the web rather than run as a file.
    Get-ChildItem "$BaseDir\*.ps1" -ErrorAction SilentlyContinue | Unblock-File

    Write-Host ""
    Write-Host "Close this window and open a NEW admin PowerShell." -ForegroundColor Yellow
    Write-Host "PATH does not refresh in the current session." -ForegroundColor Yellow
}

## ============================================================
##  Step 5 -- scrcpy-mcp + Ollama + model
## ============================================================
$StepOllama = {
    ## npm and ollama stream progress/warnings to stderr, which is fatal under
    ## the global Stop preference even when the command succeeds ("pulling
    ## manifest ..." tripped this on the first -RunAll). Drive them by
    ## $LASTEXITCODE, not by stderr. Explicit 'throw' still fails the step.
    $ErrorActionPreference = 'Continue'

    if ($Features.Mcp) {
        npm install -g scrcpy-mcp
        if ($LASTEXITCODE -ne 0) { throw "npm install -g scrcpy-mcp failed." }
    }

    Get-Process ollama* -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden

    ## 'ollama serve' returns immediately; wait for the daemon
    $ok = $false
    foreach ($i in 1..30) {
        try { Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 > $null; $ok = $true; break }
        catch { Start-Sleep -Seconds 2 }
    }
    if (-not $ok) { throw "Ollama daemon never came up on 127.0.0.1:11434" }

    ollama pull qwen3.5
    if ($LASTEXITCODE -ne 0) { throw "ollama pull qwen3.5 failed." }
    ollama list
}

## ============================================================
##  Step 6 -- Telegram token
## ============================================================
$StepToken = {
    $existing = Get-SavedToken
    if ($existing) {
        $masked = $existing.Substring(0, [Math]::Min(8, $existing.Length)) + "..."
        Write-Host "A token is already saved: $masked" -ForegroundColor Green
        Write-Host ""
        ## Unattended keeps the saved token (default 'n') -- Set-SavedToken would
        ## otherwise block on Read-Host for the new value.
        if ((Read-Prompt "Replace it? (y/N)" "n") -ne 'y') { Write-Host "Kept existing token."; return }
    }
    Set-SavedToken
}

## ============================================================
##  Step 7 -- OpenClaw
## ============================================================
$StepOpenClaw = {
    ## This step is native-command heavy (openclaw, ollama), and those write
    ## progress/diagnostics to stderr that is fatal under the global Stop
    ## preference even on success. Real failures are still caught explicitly:
    ## Patch dry-runs and checks $LASTEXITCODE, and 'config validate' is gated
    ## by $LASTEXITCODE before doctor runs.
    $ErrorActionPreference = 'Continue'

    $tokenValue = Get-SavedToken
    if (-not $tokenValue) { throw "No Telegram token saved. Run step [6] first." }

    ## Preflight. droidclaw declares 'requires: bins: [adb, scrcpy]'; missing
    ## either and the skill is silently ineligible -- the agent never learns it
    ## can drive the phone.
    $needed = @("npx","ollama")
    if ($Features.Android) { $needed += @("adb","scrcpy") }
    foreach ($bin in $needed) {
        if (-not (Get-Command $bin -ErrorAction SilentlyContinue)) {
            throw "$bin not on PATH. Open a NEW terminal."
        }
    }
    if ($Features.Mcp) {
        if (-not (npm list -g --depth=0 2>$null | Select-String scrcpy-mcp)) {
            throw "scrcpy-mcp missing. Install it first."
        }
        ## No attached device looks exactly like "the model refused to call tools"
        if ((adb shell getprop sys.boot_completed 2>$null | Out-String).Trim() -ne "1") {
            Write-Host "WARNING: AVD not booted. scrcpy tools will fail." -ForegroundColor Yellow
        }
    }

    ## Ollama onboarding: installs OpenClaw, the gateway Scheduled Task, the
    ## provider, and starts the gateway. Opens the TUI and blocks until you exit,
    ## even with --yes (documented as headless, but it is not).
    $cfgDefault = "$Home\.openclaw\openclaw.json"
    if ($Unattended) {
        ## Cannot wait on a human to exit the TUI. Launch onboarding detached,
        ## wait for it to write the config (past that point the TUI is just
        ## idling), give it a grace window to finish registering the gateway
        ## task and provider, then end it. Best-effort kill of the launcher and
        ## the openclaw/node processes it spawned -- the gateway is restarted
        ## below regardless.
        Write-Host ">>> [auto] Onboarding detached; ending the TUI once config is written." -ForegroundColor DarkGray
        $proc = Start-Process ollama -ArgumentList 'launch','openclaw','--model','qwen3.5','--yes' -PassThru -WindowStyle Hidden
        $deadline = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $deadline) {
            if ($proc.HasExited) { break }
            if (Test-Path $cfgDefault) { Start-Sleep -Seconds 15; break }
            Start-Sleep -Seconds 3
        }
        $kill = @($proc.Id)
        $kill += (Get-Process openclaw*, node -ErrorAction SilentlyContinue |
                  Where-Object { $_.Path -match 'openclaw' } | Select-Object -ExpandProperty Id)
        foreach ($id in ($kill | Select-Object -Unique)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        if (-not (Test-Path $cfgDefault)) { throw "Onboarding did not write $cfgDefault within 5 min." }
    } else {
        Write-Host ">>> The OpenClaw TUI will open. Exit it (/exit or Ctrl+C) to continue." -ForegroundColor Yellow
        ollama launch openclaw --model qwen3.5 --yes
    }

    ## 'openclaw config file' can return a ~-prefixed path. PowerShell cmdlets
    ## (Test-Path, Copy-Item, Get-Content) expand ~, but the .NET [IO.File] APIs
    ## below do NOT -- they resolve ~ against the current directory, so the .env
    ## write lands at <cwd>\~\.openclaw\.env and fails. Expand ~ to $Home once,
    ## here, so every later use (Split-Path, WriteAllLines) is an absolute path.
    $cfg = (openclaw config file).Trim()
    if ($cfg -like '~*') { $cfg = Join-Path $Home ($cfg -replace '^~[\\/]?', '') }
    if (-not (Test-Path $cfg)) { throw "No config at $cfg. Did onboarding fail?" }
    if (-not (Test-Path "$cfg.post-ollama-launch")) { Copy-Item $cfg "$cfg.post-ollama-launch" }
    openclaw gateway stop

    ## The gateway runs as a Scheduled Task and never sees this terminal's
    ## environment. OpenClaw reads ~/.openclaw/.env, so the secret goes there
    ## or config load fails with "Missing/empty vars".
    $dotEnv = Join-Path (Split-Path $cfg) ".env"
    $keep = @()
    if (Test-Path $dotEnv) {
        $keep = Get-Content $dotEnv | Where-Object { $_ -notmatch '^\s*TELEGRAM_BOT_TOKEN\s*=' }
    }
    [IO.File]::WriteAllLines($dotEnv, @($keep) + "TELEGRAM_BOT_TOKEN=$tokenValue",
        (New-Object Text.UTF8Encoding($false)))

    $gwToken = -join ((48..57)+(97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_})

    ## allowInsecureAuth is what lets the Control UI authenticate over plain
    ## http on loopback. Omit the whole block to leave the dashboard unconfigured.
    $controlUi = if ($EnableDashboard) { 'controlUi: { allowInsecureAuth: true },' } else { '' }

    Patch "gateway" @"
{ gateway: {
    mode: "local", port: $GatewayPort, bind: "loopback",
    $controlUi
    auth: { mode: "token", token: "$gwToken" } } }
"@

    ## Compaction sized for a 64k window, not the 262k qwen3.5 claims.
    ## Too generous here and compaction fires on every single turn.
    Patch "agent defaults" @'
{ agents: { defaults: {
    blockStreamingDefault: "on", blockStreamingBreak: "text_end",
    humanDelay: { mode: "natural" },
    toolProgressDetail: "explain", verboseDefault: "on",
    reasoningDefault: "on", thinkingDefault: "low",
    experimental: { localModelLean: true },
    memorySearch: { enabled: false },
    compaction: {
      mode: "safeguard", reserveTokensFloor: 12000, keepRecentTokens: 24000,
      recentTurnsPreserve: 3, maxHistoryShare: 0.6,
      truncateAfterCompaction: true, maxActiveTranscriptBytes: "20mb",
      notifyUser: true,
      memoryFlush: { enabled: true, softThresholdTokens: 6000, forceFlushTranscriptBytes: "2mb" } } } } }
'@

    Patch "model" @"
{ agents: { defaults: {
    model: { primary: "ollama/$Model" },
    imageModel: { primary: "ollama/$Model" } } } }
"@

    Patch "telegram" @"
{ channels: { telegram: {
    botToken: "`${TELEGRAM_BOT_TOKEN}",
    dmPolicy: "allowlist", allowFrom: ["$TelegramId"],
    streaming: { mode: "progress" } } },
  commands: {
    allowFrom: { telegram: ["$TelegramId"] },
    ownerAllowFrom: ["telegram:$TelegramId"] } }
"@

    if ($Features.Mcp) {
        ## cmd.exe wrapper: Node's spawn() throws ENOENT on bare 'npx' (no PATHEXT
        ## for child processes) and EINVAL on 'npx.cmd' (cannot spawn .cmd directly).
        Patch "scrcpy mcp" @'
{ mcp: { servers: { scrcpy: { command: "cmd.exe", args: ["/c","npx","scrcpy-mcp"] } } } }
'@
    }

    ## DuckDuckGo is key-free but never auto-selected, since auto-detection only
    ## considers providers with credentials. Must be set explicitly.
    Patch "duckduckgo" @'
{ tools: { web: { search: { provider: "duckduckgo" } } },
  plugins: { entries: { duckduckgo: { config: { webSearch: { region: "us-en", safeSearch: "off" } } } } } }
'@

if ($Features.DroidClaw) {

    ## ---- DroidClaw skill ----
    New-Item -ItemType Directory -Force "$Home\.openclaw\skills\droidclaw" | Out-Null
    $skill = @'
---
name: droidclaw
description: Controls a connected Android device via the scrcpy-mcp bridge using a perception-reasoning-action loop.
requires:
  bins:
    - adb
    - scrcpy
---

# DroidClaw Android Automation Agent

Use this skill when the user requests tasks on an Android device: opening apps, toggling features, sending messages, or typing into form fields.

## Execution Framework
1. **Perception**: Capture the screen via scrcpy, then read it with your vision component.
2. **Reasoning**: Locate UI elements. Calculate coordinates for taps and text fields.
3. **Action**: Issue explicit input commands through the tool chain.

## Core Directives
* Always read the screen before pressing anything.
* If a tap does not change the layout after three attempts, stop and tell the user.
* Clear existing text before typing into a field.
'@
    ## A BOM before the opening --- breaks YAML frontmatter and the skill never
    ## loads. Set-Content -Encoding utf8 writes a BOM on PS 5.1; this does not.
    [IO.File]::WriteAllText("$Home\.openclaw\skills\droidclaw\SKILL.md", $skill,
        (New-Object Text.UTF8Encoding($false)))

    ## limits lives at skills.limits, NOT skills.load.limits. Getting this wrong
    ## makes the config invalid, and 'doctor --fix' then silently restores
    ## last-known-good and discards every patch above.
    Patch "skills" @'
{ skills: {
    allowBundled: [],
    load: { extraDirs: ["~/.openclaw/skills"] },
    limits: { maxSkillsInPrompt: 5, maxSkillsPromptChars: 4000 } } }
'@

} else {
    ## Lite: no skills directory. Bundled skills stay off to keep the system
    ## prompt small -- a bloated prompt on a 64k window triggers compaction
    ## on every single turn.
    Patch "skills" @'
{ skills: { allowBundled: [], limits: { maxSkillsInPrompt: 5, maxSkillsPromptChars: 4000 } } }
'@
}

    ## ---- Context window ----
    ## Three numbers must agree at $NumCtx, or OpenClaw believes it has room
    ## Ollama never allocated and the prompt tail is silently truncated:
    ##   contextTokens -- the effective runtime budget OpenClaw compacts against
    ##                    (schema field; per src/agents/context-resolution.ts it
    ##                    takes precedence over contextWindow: contextTokens ??
    ##                    contextWindow)
    ##   contextWindow -- the model's advertised window (kept equal, zero-risk)
    ##   params.num_ctx -- what Ollama actually allocates in VRAM
    ## Set-ModelContextCap sets all three by read-modify-dedupe-full-replace, NOT
    ## 'config set ... --merge': that merge left a DUPLICATE model entry and then
    ## silently failed to change num_ctx, so the model ran at 262144 on CPU. The
    ## helper also preserves compat.supportsTools (losing it stops tool calls).
    Write-Host "`n>>> Capping context to $NumCtx" -ForegroundColor Cyan
    Set-ModelContextCap $NumCtx
    openclaw config set models.providers.ollama.contextWindow $NumCtx --strict-json

    ## ---- Validate, repair, restart ----
    openclaw config validate
    if ($LASTEXITCODE -ne 0) {
        throw "Config invalid. Do NOT run doctor --fix -- it would discard all of the above."
    }

    openclaw doctor --fix

    ## doctor raises the model's context back to the native 262144. Clamp again
    ## -- authoritative: Set-ModelContextCap also de-duplicates whatever doctor
    ## left, so the final array is one entry with all three fields at $NumCtx.
    Write-Host "`n>>> Re-clamping context to $NumCtx (doctor raises it)" -ForegroundColor Cyan
    Set-ModelContextCap $NumCtx

    openclaw gateway restart
    foreach ($i in 1..30) {
        openclaw gateway status *>$null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 2
    }

    ## ---- Probes ----
    Write-Host "`n=== 1-2. Model reachable? (want: pong) ===" -ForegroundColor Cyan
    openclaw infer model run --local   --model "ollama/$Model" --prompt "Reply with exactly: pong" --json
    openclaw infer model run --gateway --model "ollama/$Model" --prompt "Reply with exactly: pong" --json

    Write-Host "`n=== 3. MCP tools discovered? (must list scrcpy TOOLS) ===" -ForegroundColor Cyan
    openclaw mcp status --verbose
    openclaw mcp doctor --probe

    Write-Host "`n=== 4. droidclaw skill loaded? ===" -ForegroundColor Cyan
    openclaw skills info droidclaw

    Write-Host "`n=== 5. num_ctx applied, still on GPU? (want $NumCtx / 100% GPU) ===" -ForegroundColor Cyan
    ollama ps

    Write-Host "`n=== 6. supportsTools survived? (must be true) ===" -ForegroundColor Cyan
    openclaw config get models.providers.ollama.models --json

    Write-Host ""
    Write-Host "If probe 3 lists no tools, the agent will narrate shell commands as" -ForegroundColor Yellow
    Write-Host "text instead of calling them, and step [8] would teach you nothing." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Dashboard token: $gwToken" -ForegroundColor Green
    Write-Host "Open with: openclaw dashboard" -ForegroundColor Green
}

## ============================================================
##  Test suite -- diagnostics, not agent turns
##
##  Every check here isolates one link in the chain. The point is to
##  tell apart failures that look identical from the outside:
##    "the model refused to call a tool"  vs
##    "no tools were ever offered to it"  vs
##    "no device was attached"
## ============================================================

$script:TPass = 0
$script:TFail = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Check, [string]$Hint = "")

    Write-Host ("  {0,-48}" -f $Name) -NoNewline
    $result = $false
    $err    = ""
    try   { $result = [bool](& $Check) }
    catch { $result = $false; $err = $_.Exception.Message }

    if ($result) {
        Write-Host "[ PASS ]" -ForegroundColor Green
        $script:TPass++
    } else {
        Write-Host "[ FAIL ]" -ForegroundColor Red
        $script:TFail++
        if ($err)  { Write-Host "         $err"  -ForegroundColor DarkRed }
        if ($Hint) { Write-Host "         $Hint" -ForegroundColor DarkYellow }
    }
}

$StepSuite = {
    ## Diagnostics only. Each Test-Case wraps its check in try/catch, but under
    ## the global Stop preference a native tool's stderr turns into a throw that
    ## the catch scores as a FALSE fail. Continue lets each check evaluate its
    ## real boolean.
    $ErrorActionPreference = 'Continue'

    $script:TPass = 0
    $script:TFail = 0

    if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
        throw "openclaw not installed. Run step [7] first."
    }

    Write-Rule "environment" DarkCyan

    if ($Features.Android) {
        Test-Case "adb on PATH" { [bool](Get-Command adb -ErrorAction SilentlyContinue) } "Install the Android SDK."
        Test-Case "scrcpy on PATH" { [bool](Get-Command scrcpy -ErrorAction SilentlyContinue) } "winget install Genymobile.scrcpy"
    }
    if ($Features.Mcp) {
        Test-Case "scrcpy-mcp installed globally" {
            [bool](npm list -g --depth=0 2>$null | Select-String scrcpy-mcp)
        } "npm install -g scrcpy-mcp"
    }

    Test-Case "ollama daemon answering" {
        try { Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 3 > $null; $true } catch { $false }
    } "Start-Process ollama -ArgumentList serve -WindowStyle Hidden"

    Test-Case "$Model pulled" {
        (ollama list 2>$null | Out-String) -match [regex]::Escape($Model)
    } "ollama pull qwen3.5"

    if ($Features.Android) {

    Write-Rule "device" DarkCyan

    Test-Case "AVD attached" {
        @(adb devices 2>$null | Where-Object { $_ -match '^\S+\s+device\s*$' }).Count -gt 0
    } "Start the emulator (step [4])."

    Test-Case "AVD finished booting" {
        (adb shell getprop sys.boot_completed 2>$null | Out-String).Trim() -eq "1"
    } "adb answers long before Android is up. Wait, or check the emulator window."

    }  ## end Features.Android

    Write-Rule "config" DarkCyan

    Test-Case "openclaw.json validates" {
        openclaw config validate *>$null
        $LASTEXITCODE -eq 0
    } "Do NOT run 'doctor --fix' on an invalid config; it discards your changes."

    Test-Case "telegram token in gateway env" {
        ## Use the known path, NOT 'openclaw config file' -- that command prints a
        ## startup spinner that interleaves with this line and misaligns [ PASS ].
        $dotEnv = "$Home\.openclaw\.env"
        (Test-Path $dotEnv) -and ((Get-Content $dotEnv | Out-String) -match 'TELEGRAM_BOT_TOKEN=\S')
    } "The gateway is a Scheduled Task; it cannot see this shell's environment."

    Test-Case "compat.supportsTools = true" {
        $json = openclaw config get models.providers.ollama.models --json 2>$null | Out-String
        $m = ($json | ConvertFrom-Json) | Where-Object { $_.id -eq $Model }
        $m.compat.supportsTools -eq $true
    } "Without this the model is never offered tools, and narrates commands instead."

    Test-Case "num_ctx capped to $NumCtx" {
        $json = openclaw config get models.providers.ollama.models --json 2>$null | Out-String
        $m = ($json | ConvertFrom-Json) | Where-Object { $_.id -eq $Model }
        $m.params.num_ctx -eq $NumCtx
    } "doctor --fix raises this to 262144. Re-clamp it."

    Test-Case "contextTokens capped to $NumCtx" {
        $json = openclaw config get models.providers.ollama.models --json 2>$null | Out-String
        $m = ($json | ConvertFrom-Json) | Where-Object { $_.id -eq $Model }
        $m.contextTokens -eq $NumCtx
    } "The effective budget OpenClaw compacts against; must equal num_ctx."

    Write-Rule "runtime" DarkCyan

    Test-Case "gateway reachable" {
        openclaw gateway status *>$null
        $LASTEXITCODE -eq 0
    } "openclaw gateway restart"

    Test-Case "model responds (direct)" {
        (openclaw infer model run --local --model "ollama/$Model" --prompt "Reply with exactly: pong" 2>$null | Out-String) -match 'pong'
    } "Transport or model problem, before any agent context is involved."

    Test-Case "model responds (via gateway)" {
        (openclaw infer model run --gateway --model "ollama/$Model" --prompt "Reply with exactly: pong" 2>$null | Out-String) -match 'pong'
    } "Direct works but gateway does not: routing, auth, or provider selection."

    Test-Case "model loaded on GPU, not CPU" {
        (ollama ps 2>$null | Out-String) -match '100% GPU'
    } "KV cache spilled to CPU. Lower num_ctx (and contextTokens/contextWindow with it)."

    if ($Features.Mcp -or $Features.DroidClaw) {
        Write-Rule "tools" DarkCyan
    }

    if ($Features.Mcp) {
        Test-Case "scrcpy MCP server started" {
            $out = openclaw mcp status --verbose 2>$null | Out-String
            ($out -match 'scrcpy') -and ($out -notmatch 'failed to start')
        } "ENOENT on 'npx', EINVAL on 'npx.cmd'. Use cmd.exe /c npx scrcpy-mcp."
    }

    if ($Features.DroidClaw) {
        Test-Case "droidclaw skill loaded" {
            openclaw skills info droidclaw *>$null
            $LASTEXITCODE -eq 0
        } "A BOM before the opening --- breaks the YAML frontmatter silently."
    }

    ## ---- summary ----
    Write-Host ""
    Write-Rule "" DarkGray
    Write-Host "  passed " -ForegroundColor DarkGray -NoNewline
    Write-Host $script:TPass -ForegroundColor Green -NoNewline
    Write-Host "   failed " -ForegroundColor DarkGray -NoNewline
    if ($script:TFail -gt 0) { Write-Host $script:TFail -ForegroundColor Red }
    else                     { Write-Host $script:TFail -ForegroundColor Green }
    Write-Host ""

    if ($script:TFail -eq 0) {
        Write-Host "  All checks passed. The agent tests in the next step are" -ForegroundColor Green
        Write-Host "  now meaningful: a failure there is a model or prompt issue," -ForegroundColor Green
        Write-Host "  not plumbing." -ForegroundColor Green
    } else {
        Write-Host "  Fix the failures above before running the agent tests." -ForegroundColor Yellow
        Write-Host "  A failing tool chain makes the agent narrate shell commands" -ForegroundColor Yellow
        Write-Host "  as text, which looks exactly like a bad model." -ForegroundColor Yellow
    }
}

## ============================================================
##  Step 8 -- agent tests
## ============================================================
## Defined here so Full can use it unchanged. Lite never lists it in the
## menu: with no MCP tools and no device, these prompts have nothing to do.
$StepTest = {
    if (-not $Features.Mcp) { throw "Agent device tests need the MCP bridge (Full)." }

    ## 'openclaw agent' streams to stderr (and node prints gateway diagnostics
    ## there); fatal under Stop even when a prompt completes. Continue so all
    ## three prompts run and you can judge tool-calls vs narration from output.
    $ErrorActionPreference = 'Continue'

    Write-Host "These only mean anything if the test suite showed real scrcpy" -ForegroundColor Yellow
    Write-Host "tools and supportsTools: true." -ForegroundColor Yellow
    Write-Host ""

    openclaw agent --session-key test --message 'Capture a screenshot of the current AVD display using "scrcpy-mcp" or "android_automation_agent:read_screen" to verify the visual stream is rendering correctly'
    openclaw agent --session-key test --message 'Execute a Home button key event via ADB to ensure the emulator layout resets to a known state'
    ## Uses the built-in Messages app (com.google.android.apps.messaging), which
    ## ships on the stock system image -- Telegram is not preinstalled, so an
    ## agent test that assumes it can never complete the send.
    openclaw agent --session-key test --message 'Open the built-in Messages app (com.google.android.apps.messaging), start a new conversation, type Hi in the message field, then send'
}

## ============================================================
##  Step 10 -- status
## ============================================================
$StepStatus = {
    ## Read-only reporting. It shells out to openclaw/ollama/adb/emulator, whose
    ## stderr ("Connectivity probe: failed" when the gateway is down, etc.) is
    ## fatal under Stop and would abort a status check that should just show red
    ## rows. Continue lets every probe fail into its own cell instead.
    $ErrorActionPreference = 'Continue'
    Update-EnvState
    $e = $script:Env

    function Row($label, $value, $good) {
        Write-Host ("  {0,-26}" -f $label) -ForegroundColor Gray -NoNewline
        if ($null -eq $good) { Write-Host $value -ForegroundColor DarkGray }
        elseif ($good)       { Write-Host $value -ForegroundColor Green }
        else                 { Write-Host $value -ForegroundColor Red }
    }

    ## ---- host ----
    Write-Rule "host" DarkCyan
    Row "PowerShell" $PSVersionTable.PSVersion.ToString() $null
    Row "Administrator" $(if (Test-Admin) { "yes" } else { "no" }) (Test-Admin)
    $free = (Get-PSDrive C).Free / 1GB
    Row "C: free" ("{0:N1} GB" -f $free) ($free -gt 20)

    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
           Where-Object { $_.AdapterRAM -gt 0 } | Select-Object -First 1
    if ($gpu) {
        ## AdapterRAM is a signed 32-bit field and wraps above 4 GB, so it
        ## under-reports a 12 GB card. Report the name, not the bogus size.
        Row "GPU (discrete)" $gpu.Name $null
    }

    ## Integrated GPU + which card the emulator is pinned to. The emulator should
    ## render on the iGPU (Set-EmulatorGpuPreference) so the discrete card's VRAM
    ## stays entirely for the model.
    $igpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'UHD|Iris|Radeon.*Graphics|Vega|Integrated' } | Select-Object -First 1
    Row "GPU (integrated)" $(if ($igpu) { $igpu.Name } else { "none detected" }) $null
    $emuExe = "$env:LOCALAPPDATA\Android\Sdk\emulator\emulator.exe"
    $pref = $null
    try { $pref = (Get-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -ErrorAction Stop).$emuExe } catch { }
    $emuGpu = if ($pref -match 'GpuPreference=1') { "integrated (pinned)" }
              elseif ($pref -match 'GpuPreference=2') { "discrete (pinned)" }
              else { "OS default (Autoselect)" }
    Row "emulator GPU" $emuGpu ($pref -match 'GpuPreference=1')

    ## ---- virtualization ----
    Write-Host ""
    Write-Rule "virtualization" DarkCyan
    Row "Hyper-V hypervisor" $(if ($e.HyperV) { "enabled" } else { "disabled" }) $e.HyperV
    if ($e.Emulator) {
        $accel = emulator -accel-check 2>&1 | Out-String
        $whpx = $accel -match 'WHPX'
        Row "emulator accel" $(if ($whpx) { "WHPX" } else { "none" }) $whpx
    } else {
        Row "emulator accel" "emulator not on PATH" $false
    }

    ## ---- toolchain ----
    Write-Host ""
    Write-Rule "toolchain" DarkCyan
    Row "node"       $(if (Get-Command node -EA SilentlyContinue) { (node --version) } else { "missing" }) $e.Npm
    Row "adb"        $(if ($e.Adb)    { "present" } else { "missing" }) $e.Adb
    Row "scrcpy"     $(if ($e.Scrcpy) { "present" } else { "missing" }) $e.Scrcpy
    Row "scrcpy-mcp" $(if ($e.ScrcpyMcp) { "installed" } else { "missing" }) $e.ScrcpyMcp
    Row "ollama"     $(if ($e.Ollama) { "present" } else { "missing" }) $e.Ollama
    Row "openclaw"   $(if ($e.OpenClaw) { (openclaw --version 2>$null | Select-Object -First 1) } else { "missing" }) $e.OpenClaw

    ## ---- model ----
    Write-Host ""
    Write-Rule "model" DarkCyan
    Row "configured" $Model $null
    Row "pulled"     $(if ($e.Model) { "yes" } else { "no" }) $e.Model
    if ($e.Ollama) {
        $ps = ollama ps 2>$null | Out-String
        if ($ps -match '\S' -and $ps -notmatch '^\s*NAME') {
            $onGpu = $ps -match '100% GPU'
            Row "loaded" $(if ($onGpu) { "100% GPU" } else { "CPU spill" }) $onGpu
            if ($ps -match '(\d{4,})') { Row "runtime context" $matches[1] ($matches[1] -eq "$NumCtx") }
        } else {
            Row "loaded" "not resident (cold)" $null
        }
    }

    ## ---- device ----
    Write-Host ""
    Write-Rule "device" DarkCyan
    Row "AVD created" $(if ($e.Avd) { $AvdName } else { "none" }) $e.Avd
    Row "attached"    $(if ($e.Device) { "yes" } else { "no" }) $e.Device
    if ($e.Device) {
        $boot = (adb shell getprop sys.boot_completed 2>$null | Out-String).Trim()
        Row "boot_completed" $(if ($boot -eq "1") { "1" } else { "not yet" }) ($boot -eq "1")
        Row "android" ((adb shell getprop ro.build.version.release 2>$null | Out-String).Trim()) $null
        Row "abi"     ((adb shell getprop ro.product.cpu.abi 2>$null | Out-String).Trim()) $null
    }

    ## ---- openclaw configuration ----
    Write-Host ""
    Write-Rule "openclaw configuration" DarkCyan
    if (-not $e.OpenClaw) {
        Write-Host "  not installed" -ForegroundColor DarkGray
    } else {
        $cfgFile = (openclaw config file 2>$null).Trim()
        Row "config path" $cfgFile $null

        openclaw config validate *>$null
        $valid = ($LASTEXITCODE -eq 0)
        Row "schema valid" $(if ($valid) { "yes" } else { "NO" }) $valid

        openclaw gateway status *>$null
        $gw = ($LASTEXITCODE -eq 0)
        Row "gateway" $(if ($gw) { "running" } else { "stopped" }) $gw

        if ($valid) {
            ## Read the values this script is responsible for setting
            $primary = (openclaw config get agents.defaults.model.primary 2>$null | Select-Object -Last 1).Trim()
            Row "model.primary" $primary ($primary -eq "ollama/$Model")

            $lean = (openclaw config get agents.defaults.experimental.localModelLean 2>$null | Select-Object -Last 1).Trim()
            Row "localModelLean" $lean ($lean -eq "True" -or $lean -eq "true")

            try {
                $models = openclaw config get models.providers.ollama.models --json 2>$null | Out-String | ConvertFrom-Json
                $m = $models | Where-Object { $_.id -eq $Model }
                Row "compat.supportsTools" "$($m.compat.supportsTools)" ($m.compat.supportsTools -eq $true)
                Row "num_ctx"       "$($m.params.num_ctx)"    ($m.params.num_ctx -eq $NumCtx)
                Row "contextTokens" "$($m.contextTokens)"     ($m.contextTokens -eq $NumCtx)
                Row "contextWindow" "$($m.contextWindow)"     ($m.contextWindow -eq $NumCtx)
            } catch {
                Row "models array" "unreadable" $false
            }

            $search = (openclaw config get tools.web.search.provider 2>$null | Select-Object -Last 1).Trim()
            Row "web search" $search $null
        }

        ## Control UI: the dashboard is not installed, it is served by the
        ## gateway. allowInsecureAuth is what lets it authenticate over plain
        ## http on loopback. Without it the UI refuses the token.
        Row "controlUi configured" $(if ($e.ControlUi) { "yes" } else { "no" }) $e.ControlUi
        if ($e.DashboardDrift) {
            $want = if ($EnableDashboard) { "on" } else { "off" }
            $have = if ($e.ControlUi)     { "on" } else { "off" }
            Write-Host "  " -NoNewline
            Write-Host "drift: `$EnableDashboard=$want but config=$have -- re-run step 7" -ForegroundColor DarkYellow
        }

        ## Secret placement: token must reach the gateway process, not just us
        $dotEnv = Join-Path (Split-Path $cfgFile) ".env"
        $inGwEnv = (Test-Path $dotEnv) -and ((Get-Content $dotEnv | Out-String) -match 'TELEGRAM_BOT_TOKEN=\S')
        Row "token in gateway .env" $(if ($inGwEnv) { "yes" } else { "NO" }) $inGwEnv

        $raw = if (Test-Path $cfgFile) { Get-Content $cfgFile -Raw } else { "" }
        $literal = $raw -match '\$\{TELEGRAM_BOT_TOKEN\}'
        Row "token kept out of json" $(if ($literal) { "yes" } else { "no" }) $literal
    }

    ## ---- skill ----
    Write-Host ""
    Write-Rule "droidclaw skill" DarkCyan
    $skillPath = "$Home\.openclaw\skills\droidclaw\SKILL.md"
    if (Test-Path $skillPath) {
        Row "SKILL.md" "present" $true
        ## A BOM here silently breaks the YAML frontmatter
        $bytes = [IO.File]::ReadAllBytes($skillPath)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Row "no BOM" $(if ($hasBom) { "HAS BOM" } else { "clean" }) (-not $hasBom)
        if ($e.OpenClaw) {
            openclaw skills info droidclaw *>$null
            Row "loaded by openclaw" $(if ($LASTEXITCODE -eq 0) { "yes" } else { "no" }) ($LASTEXITCODE -eq 0)
        }
    } else {
        Row "SKILL.md" "missing" $false
    }

    ## ---- readiness verdict ----
    Write-Host ""
    Write-Rule "" DarkGray
    $ready = $e.HyperV -and $e.Adb -and $e.Device -and $e.Ollama -and $e.Model -and
             $e.OpenClaw -and $e.Cfg -and $e.Token -and $e.ScrcpyMcp
    if ($ready) {
        Write-Host "  READY" -ForegroundColor Green -NoNewline
        Write-Host " -- run the test suite to confirm the tool chain." -ForegroundColor Gray
    } else {
        Write-Host "  NOT READY" -ForegroundColor Yellow -NoNewline
        Write-Host " -- missing:" -ForegroundColor Gray
        if (-not $e.HyperV)    { Write-Host "    Hyper-V           (step 2, then reboot)" -ForegroundColor DarkYellow }
        if (-not $e.Adb)       { Write-Host "    adb / Android SDK (step 4)" -ForegroundColor DarkYellow }
        if (-not $e.Avd)       { Write-Host "    the AVD           (step 4)" -ForegroundColor DarkYellow }
        if (-not $e.Device)    { Write-Host "    a running device  (start the emulator)" -ForegroundColor DarkYellow }
        if (-not $e.Ollama)    { Write-Host "    ollama            (step 1)" -ForegroundColor DarkYellow }
        if (-not $e.Model)     { Write-Host "    $Model            (step 5)" -ForegroundColor DarkYellow }
        if (-not $e.ScrcpyMcp) { Write-Host "    scrcpy-mcp        (step 5)" -ForegroundColor DarkYellow }
        if (-not $e.Token)     { Write-Host "    telegram token    (step 6)" -ForegroundColor DarkYellow }
        if (-not $e.OpenClaw)  { Write-Host "    openclaw          (step 7)" -ForegroundColor DarkYellow }
    }
}

## ============================================================
##  Generate README.md
##
##  platyPS is the usual answer for PowerShell docs, but it is the wrong
##  tool here: Microsoft.PowerShell.PlatyPS generates external MAML help
##  for module cmdlets, and cannot introspect a standalone script whose
##  top level is a menu loop -- you would have to dot-source it, which
##  starts the menu. It also targets newer PowerShell than 5.1.
##
##  Instead this reads the script's own comment-based help, menu table,
##  and Test-Case names, and writes a README from them. The docs cannot
##  drift from the code because they are generated out of it.
## ============================================================
$StepReadme = {
    $self = $PSCommandPath
    if (-not $self) { throw "Run this from the .ps1 file, not by pasting it." }
    $src = Get-Content $self -Raw

    $out = New-Object Text.StringBuilder
    function Add-Line($t = "") { [void]$out.AppendLine($t) }

    Add-Line "# OpenClaw + Ollama on 12 GB VRAM"
    Add-Line ""
    Add-Line "A single self-contained PowerShell script that installs, configures, tests,"
    Add-Line "and uninstalls a fully local AI agent that drives an Android emulator and is"
    Add-Line "controlled over Telegram."
    Add-Line ""
    Add-Line "<$RepoUrl>"
    Add-Line ""
    Add-Line "Generated from ``$(Split-Path $self -Leaf)`` on $(Get-Date -Format 'yyyy-MM-dd')."
    Add-Line "Do not edit by hand -- regenerate with the *Generate README.md, LICENSE, .gitignore* menu item."
    Add-Line ""

    ## ---------------- disclaimer ----------------
    Add-Line "## Disclaimer"
    Add-Line ""
    Add-Line "**Run at your own risk.** This script installs system-level components,"
    Add-Line "enables Hyper-V, writes to the registry, creates a Scheduled Task, and its"
    Add-Line "uninstall path deletes directories irreversibly. It is provided as-is, with"
    Add-Line "no warranty of any kind. Read it before running it."
    Add-Line ""
    Add-Line "Specific things worth knowing before you start:"
    Add-Line ""
    Add-Line "- Enabling Hyper-V changes how virtualization works machine-wide. VirtualBox"
    Add-Line "  and VMware get slower; HAXM stops loading entirely. Disabling it later also"
    Add-Line "  breaks WSL2, Docker Desktop, and Windows Sandbox."
    Add-Line "- The uninstall step deletes ``~/.openclaw``, ``~/.android`` (your AVDs and their"
    Add-Line "  disk images), and optionally ``~/.ollama`` (your pulled models). None of it is"
    Add-Line "  recoverable."
    Add-Line "- The Telegram bot token is stored in plaintext in ``.\env`` and ``~/.openclaw/.env``."
    Add-Line "  Anyone who can read those files can control your bot. The generated"
    Add-Line "  ``.gitignore`` excludes both, plus ``openclaw.json`` (which holds a gateway token)."
    Add-Line "  Note the secret file is named ``env``, **not** ``.env`` -- a stock ``.env`` rule does"
    Add-Line "  not match it. That is how tokens end up in public history."
    Add-Line "- The agent has shell access and can drive a connected Android device. Web"
    Add-Line "  search is enabled, which means it reads untrusted content. See *Security*."
    Add-Line ""

    ## ---------------- abstract ----------------
    Add-Line "## Abstract"
    Add-Line ""
    Add-Line "OpenClaw is a personal AI assistant that bridges messaging apps to agents"
    Add-Line "through a local gateway. This script wires it to a locally-served Ollama model"
    Add-Line "and an Android emulator, so an agent you message on Telegram can look at a"
    Add-Line "phone screen, reason about what it sees, and tap, type, and swipe on it."
    Add-Line ""
    Add-Line "Nothing leaves the machine. The model runs on your GPU, the phone is an AVD on"
    Add-Line "your desktop, and the gateway binds to loopback."
    Add-Line ""
    Add-Line "The pipeline:"
    Add-Line ""
    Add-Line '```'
    Add-Line "  Telegram  -->  OpenClaw gateway  -->  Ollama (qwen3.5, 64k ctx)"
    Add-Line "                       |"
    Add-Line "                       +-->  MCP: scrcpy-mcp  -->  adb  -->  Pixel_5 AVD"
    Add-Line "                       |"
    Add-Line "                       +-->  skill: droidclaw (perception / reason / act)"
    Add-Line '```'
    Add-Line ""
    Add-Line "The emulator renders in hardware (``-gpu host``) but is pinned to the **integrated**"
    Add-Line "GPU (via the Windows per-app graphics preference), so on a 12 GB card every"
    Add-Line "megabyte of the discrete card's VRAM stays with the model. Software rendering"
    Add-Line "(``swiftshader_indirect``) was the original plan but drew a blank/white framebuffer"
    Add-Line "on the build host, so hardware GL on the iGPU is the reliable way to the same goal."
    Add-Line ""

    ## ---------------- editions ----------------
    Add-Line "## Two editions"
    Add-Line ""
    Add-Line "| | Lite | Full |"
    Add-Line "| --- | --- | --- |"
    Add-Line "| Ollama + qwen3.5 @ 64k | yes | yes |"
    Add-Line "| OpenClaw gateway, loopback | yes | yes |"
    Add-Line "| Telegram bot, allowlisted | yes | yes |"
    Add-Line "| DuckDuckGo search | yes | yes |"
    Add-Line "| Control UI dashboard | yes | yes |"
    Add-Line "| Test suite, status, uninstall | yes | yes |"
    Add-Line "| Hyper-V / WHPX | no | yes |"
    Add-Line "| Android Studio + Pixel_5 AVD | no | yes |"
    Add-Line "| scrcpy-mcp bridge | no | yes |"
    Add-Line "| DroidClaw skill | no | yes |"
    Add-Line "| .xapk / .obb installer | no | yes |"
    Add-Line "| Approve paired devices | yes | yes |"
    Add-Line ""
    Add-Line "Full does not copy Lite. It sets ``\$global:OC_NoAutoStart``, dot-sources the Lite"
    Add-Line "script, flips three flags in ``\$global:OC_Features``, defines the four"
    Add-Line "Android-only steps, rebuilds the menu, and calls ``Start-Menu``. Shared steps read"
    Add-Line "the flags rather than being duplicated, so there is exactly one implementation"
    Add-Line "of *configure OpenClaw*, *run the test suite*, and *uninstall*."
    Add-Line ""

    ## ---------------- one-liners ----------------
    Add-Line "## One-liner install"
    Add-Line ""
    Add-Line "Lite:"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line "\$f = \"\$env:TEMP\OpenClaw_Lite.ps1\"; irm $RepoRaw/OpenClaw_Ollama_12GB_VRAM_Lite.ps1 -OutFile \$f; Unblock-File \$f; & \$f"
    Add-Line '```'
    Add-Line ""
    Add-Line "Full (fetches Lite too):"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line "\$f = \"\$env:TEMP\OpenClaw_Full.ps1\"; irm $RepoRaw/OpenClaw_Ollama_12GB_VRAM_Full.ps1 -OutFile \$f; Unblock-File \$f; & \$f"
    Add-Line '```'
    Add-Line ""
    Add-Line "**Not** ``irm ... | iex``. Both scripts declare ``#Requires`` and a ``param()`` block,"
    Add-Line "and neither survives being piped through ``Invoke-Expression``: parameters cannot"
    Add-Line "bind, and the version check is skipped. Saving to a file first also means"
    Add-Line "``\$PSCommandPath`` is set, so self-elevation and the docs generator both work."
    Add-Line ""
    Add-Line "> **Read this before running either.** These download code and execute it"
    Add-Line "> immediately, with no review, no signature, and no checksum. Whoever controls"
    Add-Line "> that URL controls your machine, and the script will ask for Administrator."
    Add-Line "> The convenience is real; so is the risk. The file lands in ``\$env:TEMP`` -- open"
    Add-Line "> it and read it before you let it run."
    Add-Line ""
    Add-Line "Both scripts offer to relaunch themselves elevated, forwarding whatever"
    Add-Line "arguments you gave them."
    Add-Line ""

    ## ---------------- parameters ----------------
    Add-Line "## Parameters"
    Add-Line ""
    Add-Line "Override on the command line rather than editing the file:"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line ".\OpenClaw_Ollama_12GB_VRAM_Full.ps1 -NumCtx 32768 -TelegramId 123456789"
    Add-Line ".\OpenClaw_Ollama_12GB_VRAM_Lite.ps1 -NoDashboard -NoElevate"
    Add-Line '```'
    Add-Line ""
    Add-Line "| Parameter | Default | Notes |"
    Add-Line "| --- | --- | --- |"
    Add-Line "| ``-TelegramId`` | ``$TelegramId`` | message @userinfobot to find yours |"
    Add-Line "| ``-Model`` | ``$Model`` | |"
    Add-Line "| ``-NumCtx`` | ``$NumCtx`` | drop to 32768 if ``ollama ps`` stops saying 100% GPU |"
    Add-Line "| ``-GatewayPort`` | ``$GatewayPort`` | loopback only |"
    Add-Line "| ``-AvdName`` | ``$AvdName`` | Full only |"
    Add-Line "| ``-SysImage`` | (Android 37.1 ps16k x86_64) | Full only |"
    Add-Line "| ``-NoDashboard`` | off | omit the controlUi block from openclaw.json |"
    Add-Line "| ``-LicenseHolder`` | ``$LicenseHolder`` | written into LICENSE |"
    Add-Line "| ``-NoElevate`` | off | skip the Administrator relaunch prompt |"
    Add-Line "| ``-Unattended`` | off | never block on a human: prompts take their default, no 'press any key', the onboarding TUI is launched detached and killed once it writes config. Set OC_UNATTENDED=1 in the environment to force it |"
    Add-Line "| ``-AutoXapkPath`` | (none) | package the .xapk step installs when unattended, skipping the file picker |"
    Add-Line "| ``-RunAll`` | off | drive every menu step end-to-end, non-interactively, writing ``full_test_report.md``. Implies ``-Unattended`` and ends in the **destructive uninstall** -- VM/throwaway only |"
    Add-Line "| ``-StartAvd`` | off | launch/relaunch the AVD (cold boot) and exit, without the menu. Full only |"
    Add-Line ""
    Add-Line "``-NumCtx`` is range-validated (4096-262144) and ``-GatewayPort`` (1024-65535), so a"
    Add-Line "typo fails at parse time rather than halfway through configuring the gateway."
    Add-Line ""

    ## ---------------- launching the AVD ----------------
    Add-Line "## Launching the AVD"
    Add-Line ""
    Add-Line "Two ways to start (or restart) the emulator:"
    Add-Line ""
    Add-Line "1. **Via this script** -- the *Launch / relaunch the AVD (cold boot)* menu item,"
    Add-Line "   or headless:"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line ".\OpenClaw_Ollama_12GB_VRAM_Full.ps1 -StartAvd"
    Add-Line '```'
    Add-Line ""
    Add-Line "   It stops any running instance (``qemu-system-x86_64`` holds the locks, not the"
    Add-Line "   ``emulator.exe`` launcher), pins ``emulator.exe`` + ``qemu-system-x86_64.exe`` to the"
    Add-Line "   **integrated GPU** (Windows per-app graphics preference), and cold-boots with"
    Add-Line "   ``-gpu host``. The iGPU renders the display; the discrete card's VRAM stays for"
    Add-Line "   the model."
    Add-Line ""
    Add-Line "2. **Via Android Studio** -- open **Device Manager**, and press Play on ``$AvdName``"
    Add-Line "   (pencil > *Show Advanced Settings* > **Emulated Performance > Graphics =**"
    Add-Line "   **Hardware - GLES 2.0** to match)."
    Add-Line ""
    Add-Line "> Software rendering (``swiftshader_indirect``) drew a blank/white framebuffer on the"
    Add-Line "> build host (RTX 4070 Ti + i7-13700K): the OS booted but nothing painted. Hardware"
    Add-Line "> GL pinned to the Intel iGPU renders reliably and keeps the discrete GPU free."
    Add-Line ""
    Add-Line "### Pinning the emulator to the integrated GPU"
    Add-Line ""
    Add-Line "The script does this automatically before every launch (``Set-EmulatorGpuPreference``):"
    Add-Line "it writes a per-app graphics preference so the emulator renders on the **integrated**"
    Add-Line "GPU while the discrete card's VRAM stays entirely for the model. To do it by hand,"
    Add-Line "or to verify it:"
    Add-Line ""
    Add-Line "1. **Start > Graphics settings** (``ms-settings:display-advancedgraphics``)."
    Add-Line "2. **Add a Desktop app > Browse**, and add **both** executables:"
    Add-Line ""
    Add-Line '```'
    Add-Line "%LOCALAPPDATA%\Android\Sdk\emulator\emulator.exe"
    Add-Line "%LOCALAPPDATA%\Android\Sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64.exe"
    Add-Line '```'
    Add-Line ""
    Add-Line "3. Click each > **Options** > **Power saving** (this is the integrated GPU) > **Save**."
    Add-Line "   (Choose *High performance* instead if you have no iGPU and want the discrete card.)"
    Add-Line "4. In Android Studio's Device Manager, set the AVD's **Graphics = Hardware - GLES 2.0**."
    Add-Line "5. Relaunch: ``.\OpenClaw_Ollama_12GB_VRAM_Full.ps1 -StartAvd``."
    Add-Line ""
    Add-Line "Equivalent to the manual steps, done in one line (what the script runs), for each exe:"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line "New-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' ``"
    Add-Line "  -Name `"`$env:LOCALAPPDATA\Android\Sdk\emulator\emulator.exe`" ``"
    Add-Line "  -Value 'GpuPreference=1;' -PropertyType String -Force   # 1 = iGPU, 2 = dGPU"
    Add-Line '```'
    Add-Line ""

    ## ---------------- quick start ----------------
    Add-Line "## Quick start (recommended)"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line "git clone $RepoUrl"
    Add-Line "cd $(Split-Path $RepoUrl -Leaf)"
    Add-Line ""
    Add-Line "# Downloaded .ps1 files carry a mark-of-the-web flag and are blocked."
    Add-Line "Get-ChildItem .\*.ps1 | Unblock-File"
    Add-Line ""
    Add-Line "# Put your Telegram bot token here (see env.example)"
    Add-Line "Copy-Item env.example env"
    Add-Line "notepad env"
    Add-Line ""
    Add-Line "# Run as Administrator. Pick one:"
    Add-Line "powershell -ExecutionPolicy Bypass -File .\OpenClaw_Ollama_12GB_VRAM_Lite.ps1"
    Add-Line "powershell -ExecutionPolicy Bypass -File .\OpenClaw_Ollama_12GB_VRAM_Full.ps1"
    Add-Line '```'
    Add-Line ""
    Add-Line "Then work down the menu. Steps 1-7 run in order on a fresh machine, with a"
    Add-Line "**reboot required between step 2 and step 3**. Steps grey out until their"
    Add-Line "preconditions are met, and the reason is printed under the cursor."
    Add-Line ""
    Add-Line "Before trusting anything: run *Status check*, then *Run the test suite*."
    Add-Line ""

    ## ---------------- hardware reality ----------------
    Add-Line "## Hardware reality check"
    Add-Line ""
    Add-Line "Read this before investing a weekend. OpenClaw's own documentation on local"
    Add-Line "models states:"
    Add-Line ""
    Add-Line "> Aim for 2+ maxed-out Mac Studios or an equivalent GPU rig for a comfortable"
    Add-Line "> agent loop. A single 24 GB GPU only handles lighter prompts at higher latency."
    Add-Line ""
    Add-Line "A 12 GB card is **below** the tier the docs call marginal. This build works, but"
    Add-Line "it is working against the grain, and that shapes almost every decision in the"
    Add-Line "script:"
    Add-Line ""
    Add-Line "| Constraint | Consequence |"
    Add-Line "| --- | --- |"
    Add-Line "| 12 GB VRAM | ``qwen3.5`` (~6.6 GB quantized) leaves ~5 GB for KV cache |"
    Add-Line "| KV cache scales with context | 262144-token window will not fit; capped to 65536 |"
    Add-Line "| Emulator would compete for VRAM | hardware-rendered on the **integrated** GPU, discrete card left for the model |"
    Add-Line "| Small models are weak at tool calling | ``localModelLean`` on, tool surface reduced |"
    Add-Line ""
    Add-Line "If the agent still narrates shell commands instead of calling tools after all"
    Add-Line "of this, the honest answer is the model tier, not the config. OpenClaw's docs"
    Add-Line "describe a hybrid setup (hosted model for the agent loop, local model as"
    Add-Line "fallback) and that is the documented escape hatch."
    Add-Line ""

    ## ---------------- findings ----------------
    Add-Line "## Findings, dead ends, and things that cost hours"
    Add-Line ""
    Add-Line "Everything below was hit for real while building this. Each is now handled by"
    Add-Line "the script; they are written down so nobody has to rediscover them."
    Add-Line ""

    Add-Line "### The one that matters most"
    Add-Line ""
    Add-Line "**A model that cannot emit structured tool calls will politely describe what it"
    Add-Line "would do instead of doing it.** ``qwen2.5:7b`` produced replies like:"
    Add-Line ""
    Add-Line '```'
    Add-Line "  Here is the command we will run:"
    Add-Line "      scrcpy --screenshot screenshot.png"
    Add-Line "  Do you want to proceed?"
    Add-Line '```'
    Add-Line ""
    Add-Line "That is not a tool call. It is prose in a code fence, and the flag it invented"
    Add-Line "does not exist. OpenClaw's docs name this exactly:"
    Add-Line ""
    Add-Line "> If a model emits JSON/XML/ReAct-style text that looks like a tool call but"
    Add-Line "> wasn't a structured invocation, OpenClaw leaves it as text [...] That is"
    Add-Line "> provider/model incompatibility, not a completed tool run."
    Add-Line ""
    Add-Line "Hours were spent tuning streaming and verbosity settings to make the"
    Add-Line "\"in-between output\" appear. There was no in-between output to show, because no"
    Add-Line "tool ever ran. **Diagnose the tool chain before tuning what you can see.** That"
    Add-Line "is why the test suite exists and why it runs before the agent tests."
    Add-Line ""
    Add-Line "Three failures look identical from a Telegram window:"
    Add-Line ""
    Add-Line "1. the model refused to call a tool"
    Add-Line "2. no tools were ever offered to it"
    Add-Line "3. no device was attached"
    Add-Line ""

    Add-Line "### Config corruption"
    Add-Line ""
    Add-Line "| Symptom | Cause | Fix |"
    Add-Line "| --- | --- | --- |"
    Add-Line "| Half the config silently reverted after ``doctor --fix`` | An invalid key made the whole file invalid. ``doctor --fix`` restores the last-known-good copy and saves yours as ``.clobbered.*`` -- with no loud error | Run ``openclaw config validate`` **before** doctor and abort on failure |"
    Add-Line "| ``skills.load: Invalid input`` | ``limits`` lives at ``skills.limits``, not ``skills.load.limits`` | Correct nesting |"
    Add-Line "| ``commands.allowFrom: expected record, received array`` | ``allowFrom`` is an object keyed by channel; ``ownerAllowFrom`` is a flat ``channel:id`` array | ``{telegram:[\"id\"]}`` vs ``[\"telegram:id\"]`` |"
    Add-Line "| MCP server ignored | The key is ``mcp.servers.<name>``, not top-level ``mcpServers`` | Correct path |"
    Add-Line "| ``models[].name: Invalid input`` | Each model entry needs ``name`` as well as ``id`` | Add both |"
    Add-Line ""
    Add-Line "**Never hand-edit ``openclaw.json``.** ``openclaw config patch`` validates the full"
    Add-Line "post-change config before committing, leaves the active file untouched on"
    Add-Line "failure, and drops the bad payload as ``openclaw.json.rejected.*``. Dry-run first."
    Add-Line ""

    Add-Line "### The array-merge trap"
    Add-Line ""
    Add-Line "``config patch`` merges objects recursively but **replaces arrays wholesale**. A"
    Add-Line "one-element ``models`` array silently deleted a sibling model and stripped fields"
    Add-Line "Ollama's onboarding had set:"
    Add-Line ""
    Add-Line '```json'
    Add-Line '  "compat": { "supportsTools": true, "supportsUsageInStreaming": true },'
    Add-Line '  "reasoning": true,'
    Add-Line '  "cost": { "input": 0, "output": 0 }'
    Add-Line '```'
    Add-Line ""
    Add-Line "Losing ``compat.supportsTools`` is not cosmetic: the model is then never offered"
    Add-Line "tools, and falls back to narrating shell commands -- looking exactly like a"
    Add-Line "model-capability problem."
    Add-Line ""
    Add-Line "Clamping the ``models`` array has **two locks**:"
    Add-Line ""
    Add-Line "1. It is a **protected path**, so a full write needs ``--replace`` (``config set"
    Add-Line "   --help``: *""Allow full replacement of protected map/list paths""*)."
    Add-Line "2. A **quoted JSON argument** is mangled by Windows PowerShell 5.1: ``openclaw.cmd``"
    Add-Line "   re-expands ``%*`` into node, the embedded quotes are stripped, the ``id`` is"
    Add-Line "   lost, and OpenClaw's merge-by-id (which is correct -- it *does* merge by id)"
    Add-Line "   then **appends** the id-less entry as a **duplicate**. Two same-id rows, the"
    Add-Line "   resolver reads the first (``doctor``'s 262144), and the model runs with its KV"
    Add-Line "   cache spilled to CPU -- ``ollama ps`` never reaches ``100% GPU``. (PowerShell 7"
    Add-Line "   fixes the quoting; 5.1 is the default this ships for.)"
    Add-Line ""
    Add-Line "The script clears both by writing through **``openclaw config patch --stdin``** (the"
    Add-Line "same ``Patch`` helper used everywhere else): it reads the current entry, de-duplicates"
    Add-Line "by id, sets the three context fields, and patches the whole array back. Piping via"
    Add-Line "**stdin** carries the JSON verbatim past all shell quoting, and ``config patch`` also"
    Add-Line "clears the protected-path gate (no ``--replace`` needed). Because it carries the *whole*"
    Add-Line "entry forward, ``compat.supportsTools`` **and** ``input:[\"text\",\"image\"]`` (the vision"
    Add-Line "flag the screenshot loop needs) survive the replace. (``config set --batch-file`` is an"
    Add-Line "equivalent file-based route.) Verify with ``ollama ps``: ``100% GPU`` at your ``num_ctx``."
    Add-Line ""

    Add-Line "### Context window"
    Add-Line ""
    Add-Line "Three numbers are set equal (``$NumCtx``) so they cannot diverge:"
    Add-Line ""
    Add-Line "- ``contextTokens`` -- the effective budget OpenClaw compacts against (schema"
    Add-Line "  field; it takes precedence over ``contextWindow`` at runtime)"
    Add-Line "- ``contextWindow`` -- the model's advertised window"
    Add-Line "- ``params.num_ctx`` -- what Ollama actually allocates in VRAM"
    Add-Line ""
    Add-Line "Keeping all three equal is the zero-risk stance: there is no gap between what"
    Add-Line "OpenClaw thinks it has and what Ollama allocated, so no silent overflow -- letting"
    Add-Line "``contextWindow`` float to the native window is a separate, gateway-verified change."
    Add-Line ""
    Add-Line "Onboarding reported a 262144-token window while ``ollama ps`` showed ``CONTEXT 16384``."
    Add-Line "OpenClaw believed it had 16x the room Ollama had allocated, and the tail of every"
    Add-Line "prompt was silently truncated."
    Add-Line ""
    Add-Line "``doctor --fix`` also *raises* ``num_ctx`` back to the model's full advertised window"
    Add-Line "\"for native Ollama compatibility\". On a 12 GB card that spills the KV cache to CPU"
    Add-Line "or fails to load. The script re-clamps afterwards, then verifies with ``ollama ps``"
    Add-Line "that the model is still ``100% GPU``."
    Add-Line ""
    Add-Line "Symptom of getting this wrong: ``Compacting context...`` before nearly every reply,"
    Add-Line "including the first one."
    Add-Line ""

    Add-Line "### Windows-specific"
    Add-Line ""
    Add-Line "| Symptom | Cause |"
    Add-Line "| --- | --- |"
    Add-Line "| ``spawn npx ENOENT`` although ``npx --version`` works | Node's ``spawn()`` gets no PATHEXT resolution for child processes |"
    Add-Line "| ``spawn EINVAL`` after switching to ``npx.cmd`` | Node cannot spawn ``.cmd`` files directly |"
    Add-Line "| Both | Use ``command: \"cmd.exe\", args: [\"/c\",\"npx\",\"scrcpy-mcp\"]`` |"
    Add-Line "| ``jq: Invalid numeric literal at line 1, column 3`` | PS 5.1's ``>`` redirection writes **UTF-16LE**, not UTF-8 |"
    Add-Line "| ``config set`` reports success but changes nothing / leaves a duplicate | **JSON passed as a command-line argument**: PowerShell 5.1 strips the embedded quotes before the native exe sees it, so the ``id`` is lost. Pipe JSON via ``--stdin`` or ``--batch-file``, never as an arg. (PS 7 handles args differently; stdin/file is robust on both.) |"
    Add-Line "| Skill silently never loads | ``Set-Content -Encoding utf8`` writes a **BOM**; a BOM before ``---`` breaks YAML frontmatter |"
    Add-Line "| ``Unexpected token 'original'`` parse error | An em dash was decoded as three garbage bytes |"
    Add-Line "| Only the first package installs | ``winget install``/``uninstall`` take **one** id per call |"
    Add-Line "| ``\$PSScriptRoot`` empty | It is only populated when running as a file, not when pasting |"
    Add-Line "| Telegram dies after reboot | The gateway is a **Scheduled Task**; it never sees your shell's environment. ``\${TELEGRAM_BOT_TOKEN}`` must be in ``~/.openclaw/.env`` |"
    Add-Line ""
    Add-Line "Every file this script writes uses ``[IO.File]::WriteAllText`` with"
    Add-Line "``UTF8Encoding(\$false)``. The script itself is pure ASCII."
    Add-Line ""

    Add-Line "### Emulator"
    Add-Line ""
    Add-Line "- ``adb devices`` reports ``device`` long before Android has booted. Poll"
    Add-Line "  ``getprop sys.boot_completed`` instead. A screenshot taken too early lands on a"
    Add-Line "  black screen -- indistinguishable from a broken tool."
    Add-Line "- **Never use ``adb wait-for-device`` in a script.** It blocks forever, with no"
    Add-Line "  timeout, if the emulator failed to start."
    Add-Line "- ``emulator.exe`` is only a launcher. The process holding your AVD's files open is"
    Add-Line "  ``qemu-system-x86_64``. Killing the launcher does not release the locks."
    Add-Line "- **Quick boot IS snapshot loading.** You cannot disable snapshots and keep quick"
    Add-Line "  boot. Disabling them is what removes the *Bug report interrupted by snapshot"
    Add-Line "  load* popup at its source; cold boot is the price."
    Add-Line "- The GPU setting exists in two places. Device Manager's *Graphics* dropdown"
    Add-Line "  writes ``hw.gpu.mode`` in ``config.ini`` and persists. The control inside the running"
    Add-Line "  emulator is a runtime override that resets to ``auto`` on reboot."
    Add-Line "- Enabling the three Hyper-V *leaf* features by name keeps the management tools"
    Add-Line "  disabled. Ticking *Hyper-V* in the GUI feature tree enables the whole subtree."
    Add-Line ""

    Add-Line "### Research"
    Add-Line ""
    Add-Line "``ollama launch openclaw`` is real and does the whole onboarding: installs"
    Add-Line "OpenClaw, registers the gateway Scheduled Task, configures the provider, sets"
    Add-Line "the model. Despite ``--yes`` being documented as headless, **it still opens the"
    Add-Line "interactive TUI and blocks** until you exit."
    Add-Line ""
    Add-Line "Ollama's own integration page names the models it recommends for OpenClaw."
    Add-Line "``qwen3.5`` (~11 GB per that page, ~6.6 GB as pulled) has vision and agentic tool"
    Add-Line "use. That was the single highest-leverage change in the whole build."
    Add-Line ""
    Add-Line "The **dashboard is not a separate install.** It is the Control UI, served by the"
    Add-Line "gateway at ``http://127.0.0.1:18789/``. An AI-generated search summary confidently"
    Add-Line "described a ``data.json`` pipeline, a ``cron/jobs.json`` schema, and a top-level"
    Add-Line "``auth`` block -- none of which exist in OpenClaw. They came from unrelated"
    Add-Line "community forks. **Verify against the primary docs.**"
    Add-Line ""

    ## ---------------- security ----------------
    Add-Line "## Security"
    Add-Line ""
    Add-Line "``channels.telegram.allowFrom`` gates **who can message the bot**. It says nothing"
    Add-Line "about **what the bot reads**. From OpenClaw's security docs:"
    Add-Line ""
    Add-Line "> Prompt injection does not require public DMs: even if only you can message the"
    Add-Line "> bot, any untrusted content it reads (web search/fetch results, browser pages,"
    Add-Line "> emails, docs, attachments, pasted logs/code) can carry adversarial"
    Add-Line "> instructions. The content itself is a threat surface, not just the sender."
    Add-Line ""
    Add-Line "This build combines a small local model (the weakest tier for injection"
    Add-Line "resistance), real device-control tools (adb, scrcpy, shell), and web search."
    Add-Line "That is the exact three-way combination the docs warn about."
    Add-Line ""
    Add-Line "If you do not need the agent to search the web, set the search provider to"
    Add-Line "nothing. The Control UI is an admin surface (chat, config, exec approvals) and"
    Add-Line "must stay on loopback."
    Add-Line ""

    ## ---------------- what it builds (from .DESCRIPTION) ----------------
    if ($src -match '(?s)\.DESCRIPTION\s*(.*?)\r?\n\s*\.PARAMETER') {
        Add-Line "## Design notes"
        Add-Line ""
        Add-Line '```'
        foreach ($line in ($matches[1] -split "`n")) { Add-Line ($line -replace '^    ', '') }
        Add-Line '```'
        Add-Line ""
    }

    ## --- settings block ---
    Add-Line "## Settings"
    Add-Line ""
    Add-Line "Edit these at the top of the script before the first run."
    Add-Line ""
    Add-Line "| Variable | Value |"
    Add-Line "| --- | --- |"
    foreach ($v in 'TelegramId','Model','NumCtx','GatewayPort','AvdName','SysImage','EnableDashboard','LicenseHolder','RepoUrl','RepoBranch') {
        $val = (Get-Variable $v -ValueOnly -ErrorAction SilentlyContinue)
        Add-Line "| ```$$v`` | ``$val`` |"
    }
    Add-Line ""

    ## --- menu, introspected ---
    Add-Line "## Menu"
    Add-Line ""
    Add-Line "Items grey out when their preconditions are unmet; the reason is shown under the cursor."
    Add-Line ""
    Add-Line "The numbering is identical in both editions: ``[4]`` is *Install the AVD* in"
    Add-Line "Lite too, just greyed out. Full swaps the real step in by key."
    Add-Line ""
    Add-Line "| # | Step | Group | Edition | Unavailable when |"
    Add-Line "| --- | --- | --- | --- | --- |"
    for ($i = 0; $i -lt $script:Items.Count; $i++) {
        $n = if ($i -lt 9) { "$($i + 1)" } elseif ($i -eq 9) { "0" } else { "-" }
        $raw = if ($script:Items[$i].Why -is [scriptblock]) { & $script:Items[$i].Why } else { $script:Items[$i].Why }
        $why = if ($raw) { ($raw -replace '\|', '\|') } else { "always available" }
        $ed  = if ($script:Items[$i].Key -in @("hyperv","verify","android","agent","xapk")) { "Full" } else { "both" }
        Add-Line "| $n | $($script:Items[$i].Label) | $($script:Items[$i].Group) | $ed | $why |"
    }
    Add-Line ""

    ## --- test suite, scraped from the source ---
    Add-Line "## Test suite"
    Add-Line ""
    Add-Line "Ordered so each layer only matters if the one below passed. This is what"
    Add-Line "separates *the model refused to call a tool* from *no tools were offered*"
    Add-Line "from *no device was attached* -- three failures that look identical from a"
    Add-Line "Telegram window."
    Add-Line ""
    foreach ($m in [regex]::Matches($src, 'Test-Case\s+"([^"]+)"')) {
        Add-Line "- $($m.Groups[1].Value)"
    }
    Add-Line ""

    ## --- notes ---
    if ($src -match '(?s)\.NOTES\s*(.*?)\r?\n\s*\.LINK') {
        Add-Line "## Notes"
        Add-Line ""
        Add-Line '```'
        foreach ($line in ($matches[1] -split "`n")) { Add-Line ($line -replace '^    ', '') }
        Add-Line '```'
        Add-Line ""
    }

    Add-Line "## Full help"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line "Get-Help .\$(Split-Path $self -Leaf) -Full"
    Add-Line '```'
    Add-Line ""
    Add-Line "This is native comment-based help. The script deliberately does not use platyPS:"
    Add-Line "``Microsoft.PowerShell.PlatyPS`` generates external MAML help for module cmdlets and"
    Add-Line "cannot introspect a standalone script whose top level is a menu loop -- you would"
    Add-Line "have to dot-source it, which starts the menu."
    Add-Line ""

    Add-Line "## Status"
    Add-Line ""
    Add-Line "Built and debugged against OpenClaw ``2026.6.11`` on Windows 11 with an RTX 4070"
    Add-Line "(12 GB), Windows PowerShell 5.1."
    Add-Line ""
    Add-Line "Individual steps were exercised during development; a clean end-to-end run on a"
    Add-Line "fresh machine has **not** been done. Treat it as a well-documented starting"
    Add-Line "point, not a turnkey installer. Run the status check and the test suite before"
    Add-Line "trusting any of it."
    Add-Line ""
    Add-Line "Pull requests welcome, especially from anyone with a 24 GB card who can tell us"
    Add-Line "how much of the tuning here stops being necessary."
    Add-Line ""
    Add-Line "Issues: <$RepoUrl/issues>"
    Add-Line ""
    Add-Line "If you hit something not covered in *Findings* above, that is worth an issue."
    Add-Line "Include the output of *Status check* and *Run the test suite* -- between them they"
    Add-Line "capture almost everything needed to diagnose a failure."
    Add-Line ""

    Add-Line "## Repository layout"
    Add-Line ""
    Add-Line "| File | Committed? | Notes |"
    Add-Line "| --- | --- | --- |"
    Add-Line "| ``OpenClaw_Ollama_12GB_VRAM_Lite.ps1`` | yes | base script, and a library |"
    Add-Line "| ``OpenClaw_Ollama_12GB_VRAM_Full.ps1`` | yes | loads Lite, adds Android |"
    Add-Line "| ``README.md`` | yes | generated |"
    Add-Line "| ``LICENSE`` | yes | generated, MIT |"
    Add-Line "| ``.gitignore`` | yes | generated |"
    Add-Line "| ``env.example`` | yes | template, no secret |"
    Add-Line "| ``env`` | **no** | your Telegram bot token |"
    Add-Line "| ``openclaw.json`` | **no** | never in the repo; holds a gateway token |"
    Add-Line ""
    Add-Line "That is the whole repository. ``approve-devices.ps1`` was folded into the menu"
    Add-Line "and rewritten without ``jq``, which removed the last reason to install it."
    Add-Line ""
    Add-Line "``.gitignore`` does nothing for a file git already tracks. If ``env`` was ever"
    Add-Line "committed, ``git rm --cached env`` untracks it going forward, but the token is"
    Add-Line "already in history -- revoke it with ``/revoke`` in @BotFather and issue a new one."
    Add-Line "The generator checks for this and warns."
    Add-Line ""

    Add-Line "## License"
    Add-Line ""
    Add-Line "MIT. See [LICENSE](LICENSE)."
    Add-Line ""
    Add-Line "MIT was chosen because it is short, permissive, and its warranty disclaimer"
    Add-Line "matches the disclaimer above: this software is provided *as is*. If you need"
    Add-Line "different terms -- copyleft, or an explicit patent grant -- replace both the"
    Add-Line "LICENSE file and the ``\$LicenseHolder`` block in the script. Nothing here is legal"
    Add-Line "advice; if the choice matters to you, talk to someone qualified."
    Add-Line ""

    Add-Line "## Links"
    Add-Line ""
    Add-Line "- This repo: <$RepoUrl>"
    Add-Line "- OpenClaw docs: <https://docs.openclaw.ai>"
    Add-Line "- Ollama's OpenClaw integration: <https://docs.ollama.com/integrations/openclaw>"
    Add-Line "- Local models and the hardware floor: <https://docs.openclaw.ai/gateway/local-models>"
    Add-Line "- Security and prompt injection: <https://docs.openclaw.ai/gateway/security>"
    Add-Line ""
    Add-Line "---"
    Add-Line ""
    Add-Line "*No warranty. Run at your own risk. See Disclaimer.*"

    $readme = Join-Path (Split-Path $self) "README.md"
    [IO.File]::WriteAllText($readme, $out.ToString(), (New-Object Text.UTF8Encoding($false)))

    Write-Host "Wrote $readme" -ForegroundColor Green
    Write-Host "$((Get-Item $readme).Length) bytes" -ForegroundColor DarkGray

    ## ---------------- LICENSE ----------------
    ## MIT: short, permissive, and its "AS IS" clause matches this project's
    ## disclaimer. Written verbatim -- do not paraphrase a licence.
    ##
    ## If you forked this, put your own name in $LicenseHolder. An MIT licence
    ## naming someone else is claiming they granted permission they did not.
    if ($LicenseHolder -eq "YOUR NAME HERE" -or [string]::IsNullOrWhiteSpace($LicenseHolder)) {
        Write-Host ""
        Write-Host "WARNING: `$LicenseHolder is unset. An MIT licence with no named" -ForegroundColor Yellow
        Write-Host "copyright holder is ambiguous about who grants the permission." -ForegroundColor Yellow
    }

    $license = @"
MIT License

Copyright (c) $LicenseYear $LicenseHolder

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"@

    $licensePath = Join-Path (Split-Path $self) "LICENSE"
    [IO.File]::WriteAllText($licensePath, $license, (New-Object Text.UTF8Encoding($false)))
    Write-Host "Wrote $licensePath" -ForegroundColor Green

    ## ---------------- .gitignore ----------------
    ## The secret file is named "env", NOT ".env". A .gitignore carrying only
    ## the usual ".env" pattern does not match it, which is precisely how bot
    ## tokens end up in public history. Both are listed below.
    $gitignore = @'
# Secrets -------------------------------------------------------------
# The token file this script reads is named "env" (no leading dot).
# A bare ".env" rule would NOT match it.
env
.env
*.env
!env.example
secrets
secrets.*

# OpenClaw config snapshots this script leaves behind.
# These can contain a plaintext gateway token.
openclaw.json
openclaw.json.*
*.post-ollama-launch
*.rejected.*
*.clobbered.*
*.bak.*
*.last-good

# Android / emulator ---------------------------------------------------
*.apk
*.xapk
*.apks
*.obb

# Logs -----------------------------------------------------------------
# Per-step transcripts written by Invoke-Step. Can capture tokens echoed
# by openclaw/adb output, so never commit them.
logs/
*.log
# Per-run report written by -RunAll (Start-FullTest).
full_test_report.md

# Windows / editors ----------------------------------------------------
Thumbs.db
desktop.ini
.vscode/
.idea/
*.swp
*~
'@

    $gitignorePath = Join-Path (Split-Path $self) ".gitignore"
    [IO.File]::WriteAllText($gitignorePath, $gitignore, (New-Object Text.UTF8Encoding($false)))
    Write-Host "Wrote $gitignorePath" -ForegroundColor Green

    ## A template so the repo documents the shape of the secret file
    ## without carrying the secret.
    $envExample = @'
# Copy this file to "env" (no extension) and fill in your token.
# Get one from @BotFather in Telegram: /newbot
TELEGRAM_BOT_TOKEN=1234567890:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
'@
    $examplePath = Join-Path (Split-Path $self) "env.example"
    [IO.File]::WriteAllText($examplePath, $envExample, (New-Object Text.UTF8Encoding($false)))
    Write-Host "Wrote $examplePath" -ForegroundColor Green

    ## ---------------- already-tracked check ----------------
    ## .gitignore does nothing for a file git is already tracking. If the
    ## token was committed once, it is in history forever and rotating the
    ## token is the only real fix.
    ##
    ## Continue here: 'git ls-files --error-unmatch env' prints "pathspec 'env'
    ## did not match" to stderr in the (good) case where env is untracked, which
    ## is fatal under Stop and would fail the docs step AFTER it already wrote
    ## every file. We drive this check by $LASTEXITCODE, not by stderr.
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $ErrorActionPreference = 'Continue'
        Push-Location (Split-Path $self)
        try {
            git rev-parse --is-inside-work-tree *>$null
            if ($LASTEXITCODE -eq 0) {
                $tracked = git ls-files --error-unmatch env 2>$null
                if ($LASTEXITCODE -eq 0 -and $tracked) {
                    Write-Host ""
                    Write-Host "  ####  'env' IS ALREADY TRACKED BY GIT  ####" -ForegroundColor Red
                    Write-Host "  .gitignore does not untrack it. Run:" -ForegroundColor Yellow
                    Write-Host "      git rm --cached env" -ForegroundColor Gray
                    Write-Host "  If it was ever committed and pushed, the token is public." -ForegroundColor Yellow
                    Write-Host "  Revoke it with /revoke in @BotFather and issue a new one." -ForegroundColor Yellow
                }
            }
        } finally { Pop-Location }
    }
}

## ============================================================
##  Step 0 -- uninstall
## ============================================================
$StepUninstall = {
    Write-Host "This deletes ~/.openclaw and ~/.android (your AVDs)." -ForegroundColor Red
    Write-Host "~/.openclaw is backed up first; ~/.android (AVD disk images) is NOT." -ForegroundColor Red
    Write-Host ""
    ## Unattended answers proceed with the teardown but KEEP the expensive /
    ## machine-wide bits, so -RunAll is repeatable: models stay (no 6.6 GB
    ## re-pull), prereqs stay, Hyper-V stays. openclaw and android are always
    ## removed regardless -- those are what the test is exercising.
    if ((Read-Prompt "Type 'yes' to continue" "yes") -ne 'yes') { Write-Host "Aborted."; return }

    $keepModels  = (Read-Prompt "Keep ~/.ollama (qwen3.5 is 6.6 GB)? (Y/n)" "y") -ne 'n'
    $keepPrereqs = (Read-Prompt "Keep node/git/python/jq/scrcpy/ffmpeg? (Y/n)" "y") -ne 'n'
    $keepHyperV  = (Read-Prompt "Keep Hyper-V (WSL2 and Docker need it too)? (Y/n)" "y") -ne 'n'

    $ErrorActionPreference = 'Continue'   # most of these fail if not installed

    ## Safety net (encodes the manual backup done during live testing): the
    ## deletes below are irreversible, and ~/.openclaw holds the gateway token
    ## and paired-device records -- the one truly irreplaceable part. Copy it to
    ## a timestamped sibling BEFORE anything is stopped or removed. Small and
    ## best-effort; ~/.android is left alone (GBs, and recreatable via step 4).
    $ocDir = "$env:USERPROFILE\.openclaw"
    if (Test-Path $ocDir) {
        $ocBackup = "$ocDir.backup.$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item $ocDir $ocBackup -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "`nBacked up ~/.openclaw -> $ocBackup" -ForegroundColor Cyan
        Write-Host "(holds tokens -- delete it once you no longer need to restore)" -ForegroundColor DarkGray
    }

    ## Stop everything holding file locks BEFORE deleting, or the deletes
    ## silently half-fail.
    Write-Host "`n-- stopping processes --" -ForegroundColor Cyan
    schtasks /Delete /F /TN "OpenClaw Gateway" 2>$null
    schtasks /Delete /F /TN "ClawdBot Gateway" 2>$null
    Get-Process openclaw*     -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process node          -ErrorAction SilentlyContinue | Where-Object { $_.Path -match "openclaw|clawdbot|scrcpy-mcp" } | Stop-Process -Force
    Get-Process qemu-system-* -ErrorAction SilentlyContinue | Stop-Process -Force   # the real AVD process
    Get-Process emulator*     -ErrorAction SilentlyContinue | Stop-Process -Force   # only the launcher
    Get-Process studio64      -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process scrcpy        -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process ollama*       -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Get-Command adb -ErrorAction SilentlyContinue) { adb kill-server 2>$null }
    Start-Sleep 2

    Write-Host "`n-- openclaw --" -ForegroundColor Cyan
    Kill-FileLock -Path "$Home\.openclaw\state\openclaw.sqlite"
    cmd /c "openclaw uninstall --all --yes --non-interactive" 2>$null
    cmd /c "npm uninstall -g openclaw" 2>$null
    cmd /c "npm uninstall -g scrcpy-mcp" 2>$null
    Remove-Item "$env:USERPROFILE\.openclaw" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:USERPROFILE\.clawdbot" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:APPDATA\OpenClaw"      -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\OpenClaw" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "`n-- android --" -ForegroundColor Cyan
    $studioUninstaller = "C:\Program Files\Android\Android Studio\uninstall.exe"
    if (Test-Path $studioUninstaller) { Start-Process $studioUninstaller -Wait }
    Remove-Item "C:\Program Files\Android"                -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:USERPROFILE\.android"               -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:USERPROFILE\.gradle"                -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:USERPROFILE\.m2"                    -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Android"               -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:USERPROFILE\AndroidStudioProjects"  -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:APPDATA\Google\AndroidStudio*"      -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Google\AndroidStudio*" -Recurse -Force -ErrorAction SilentlyContinue

    ## Deleting the folders does not remove what step 4 wrote to the environment
    [Environment]::SetEnvironmentVariable("ANDROID_HOME", $null, "User")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath) {
        $cleaned = ($userPath -split ';' | Where-Object { $_ -and $_ -notmatch '\\Android\\Sdk\\' }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $cleaned, "User")
    }

    Write-Host "`n-- ollama --" -ForegroundColor Cyan
    ## winget uninstall FIRST -- deleting its files first can break the registration
    winget uninstall --id Ollama.Ollama --silent --accept-source-agreements 2>$null
    Remove-Item "$env:LOCALAPPDATA\Ollama" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:APPDATA\Ollama"      -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $keepModels) { Remove-Item "$env:USERPROFILE\.ollama" -Recurse -Force -ErrorAction SilentlyContinue }
    [Environment]::SetEnvironmentVariable("OLLAMA_MODELS", $null, "User")

    if (-not $keepPrereqs) {
        Write-Host "`n-- prerequisites --" -ForegroundColor Cyan
        ## winget uninstall takes ONE id per call
        $packages = @('Git.Git','7zip.7zip','OpenJS.NodeJS','Microsoft.OpenJDK.17','Genymobile.scrcpy','Gyan.FFmpeg')
        foreach ($p in $packages) { winget uninstall --id $p --all-versions --silent --accept-source-agreements 2>$null }
    }

    if (-not $keepHyperV) {
        Write-Host "`n-- hyper-v --" -ForegroundColor Cyan
        ## Disable the dependent (WHPX API) before the hypervisor it talks to
        Disable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform           -NoRestart
        Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Hypervisor -NoRestart
        Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Services   -NoRestart
    }

    Write-Host ""
    Get-PSDrive C | Select-Object Name, @{n="FreeGB";e={[math]::Round($_.Free/1GB,2)}} | Format-Table | Out-Host
    Write-Host "Open a NEW terminal before reinstalling." -ForegroundColor Yellow
    if (-not $keepHyperV) { Write-Host "Reboot to finish disabling Hyper-V." -ForegroundColor Yellow }
}

## ============================================================
##  Menu
## ============================================================
## ============================================================
##  Optional -- open the dashboard (Control UI)
##
##  Nothing to install. The gateway already serves the Control UI at
##  http://127.0.0.1:<port>/ . 'openclaw dashboard' opens a browser and
##  hands over the token safely: it prints a clean, non-tokenized URL and
##  the UI keeps the token in sessionStorage for that tab only.
##
##  The Control UI is an admin surface (chat, config, exec approvals).
##  Do not expose it beyond loopback.
## ============================================================
$StepDashboard = {
    if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
        throw "openclaw not installed. Run step [7] first."
    }

    ## 'openclaw gateway status'/'dashboard' print "Connectivity probe: failed"
    ## to stderr when the gateway is down -- fatal under Stop. We branch on
    ## $LASTEXITCODE instead, so Continue here.
    $ErrorActionPreference = 'Continue'

    openclaw gateway status
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Gateway is not running. Starting it..." -ForegroundColor Yellow
        openclaw gateway restart
        foreach ($i in 1..30) {
            openclaw gateway status *>$null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 2
        }
    }

    Write-Host ""
    Write-Host "The Activity tab shows the live tool-call stream -- the fastest way" -ForegroundColor DarkGray
    Write-Host "to see whether the model is actually calling scrcpy tools, or just" -ForegroundColor DarkGray
    Write-Host "narrating shell commands as text." -ForegroundColor DarkGray
    Write-Host ""

    openclaw dashboard
}

## ============================================================
##  Approve paired devices
##
##  OpenClaw writes ~/.openclaw/devices/paired.json when a device pairs.
##  A freshly paired device gets fewer than the four operator scopes, so
##  it can read but not act. This elevates every pending device.
##
##  Rewritten in pure PowerShell: the old version shelled out to jq, and
##  jq was the only thing keeping that dependency alive.
##
##  Two PS 5.1 traps handled below:
##    - ConvertTo-Json defaults to -Depth 2 and silently flattens deeper
##      objects into "System.Object[]". paired.json nests four levels.
##    - PSCustomObject has no indexer, so absent keys must be created
##      with Add-Member rather than assigned.
## ============================================================
$StepApprove = {
    $pairedPath = "$Home\.openclaw\devices\paired.json"
    $scopes = @("operator.read","operator.admin","operator.pairing","operator.write")

    if (-not (Test-Path $pairedPath)) {
        throw "No $pairedPath yet. Pair a device from the Control UI or Telegram first."
    }

    $raw  = Get-Content $pairedPath -Raw
    $json = $raw | ConvertFrom-Json
    $ids  = @($json.PSObject.Properties.Name)

    if ($ids.Count -eq 0) {
        Write-Host "Zero devices in paired.json. Nothing to do." -ForegroundColor Cyan
        return
    }
    Write-Host "Found $($ids.Count) paired device(s)." -ForegroundColor Cyan
    Write-Host ""

    ## Timestamped, so repeated runs do not clobber the previous backup.
    ## Note this file holds device tokens -- .gitignore excludes *.bak.*
    $backup = "$pairedPath.bak.$(Get-Date -Format yyyyMMddHHmmss)"
    Copy-Item $pairedPath $backup -Force
    Write-Host "Backup: $backup" -ForegroundColor DarkGray
    Write-Host ""

    function Set-Prop($obj, $name, $value) {
        if ($obj.PSObject.Properties.Name -contains $name) { $obj.$name = $value }
        else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
    }

    $updated = 0
    foreach ($id in $ids) {
        $dev = $json.$id
        $approved = @($dev.approvedScopes)

        if ($approved.Count -ge $scopes.Count) {
            Write-Host "  [ ok ] $id" -ForegroundColor DarkGray
            continue
        }

        Write-Host "  [ up ] $id" -ForegroundColor Yellow -NoNewline
        Write-Host "  ($($approved.Count) -> $($scopes.Count) scopes)" -ForegroundColor DarkGray

        Set-Prop $dev "scopes"         $scopes
        Set-Prop $dev "approvedScopes" $scopes

        ## .tokens.operator.scopes may not exist; build the chain
        if (-not $dev.PSObject.Properties.Name.Contains("tokens")) {
            Set-Prop $dev "tokens" ([PSCustomObject]@{})
        }
        if (-not $dev.tokens.PSObject.Properties.Name.Contains("operator")) {
            Set-Prop $dev.tokens "operator" ([PSCustomObject]@{})
        }
        Set-Prop $dev.tokens.operator "scopes" $scopes

        $updated++
    }

    Write-Host ""
    if ($updated -eq 0) {
        Write-Host "All devices already fully approved. File untouched." -ForegroundColor Green
        Remove-Item $backup -ErrorAction SilentlyContinue
        return
    }

    ## -Depth 10: the default of 2 turns nested objects into the literal
    ## string "System.Object[]" and corrupts the file beyond repair.
    $out = $json | ConvertTo-Json -Depth 10

    ## No BOM. A BOM at the head makes JSON parsers choke on the first key.
    [IO.File]::WriteAllText($pairedPath, $out, (New-Object Text.UTF8Encoding($false)))

    Write-Host "Approved $updated device(s)." -ForegroundColor Green
    Write-Host "Restart the gateway for it to re-read them:" -ForegroundColor DarkGray
    Write-Host "  openclaw gateway restart" -ForegroundColor Gray
}

## ============================================================
##  The menu, in run order.
##
##  ONE canonical list, shared by both editions, so a number always means
##  the same step: [4] is "Install the AVD" in Lite and in Full alike.
##
##  Full-only steps are present here as disabled placeholders. Full loads
##  this file, then calls Set-MenuItem to swap in the real Action and
##  Enabled predicate for each. The numbering never shifts.
##
##  Each item:
##    Key      stable identifier, used by Set-MenuItem
##    Enabled  predicate over $script:Env; false greys the row out
##    Why      string or scriptblock explaining a greyed row
## ============================================================
$FullOnly = "Full edition only. This step needs the Android emulator."

$script:Items = @(
    @{ Key="prereqs";  Group="SETUP"; Color="Cyan"; Label="Install prerequisites (winget, dev mode, VCRedist)"
       Action=$StepPrereqs;  Enabled={ $true }; Why="" }

    @{ Key="hyperv";   Group="SETUP"; Color="Cyan"; Label="Enable Hyper-V + WHPX          (reboot after)"
       Action={ throw $FullOnly }; Enabled={ $false }; Why=$FullOnly }

    @{ Key="verify";   Group="SETUP"; Color="Cyan"; Label="Verify Hyper-V / WHPX acceleration"
       Action={ throw $FullOnly }; Enabled={ $false }; Why=$FullOnly }

    @{ Key="android";  Group="SETUP"; Color="Cyan"; Label="Install Android Studio + Pixel_5 AVD (interactive)"
       Action={ throw $FullOnly }; Enabled={ $false }; Why=$FullOnly }

    @{ Key="ollama";   Group="SETUP"; Color="Cyan"; Label="Install Ollama, pull qwen3.5"
       Action=$StepOllama;   Enabled={ $script:Env.Npm -and $script:Env.Ollama }
       Why="Needs node + ollama from step 1. Open a NEW terminal after installing." }

    @{ Key="token";    Group="SETUP"; Color="Cyan"; Label="Set Telegram bot token"
       Action=$StepToken;    Enabled={ $true }; Why="" }

    @{ Key="openclaw"; Group="SETUP"; Color="Cyan"; Label="Install + configure OpenClaw   (opens TUI)"
       Action=$StepOpenClaw
       Enabled={ $script:Env.Npx -and $script:Env.Ollama -and $script:Env.Model -and $script:Env.Token }
       Why="Needs npx, ollama, qwen3.5, and a saved token (step 6)." }

    @{ Key="suite";    Group="USE"; Color="Green"; Label="Run the test suite (diagnostics)"
       Action=$StepSuite;    Enabled={ $script:Env.OpenClaw }
       Why="OpenClaw is not installed (step 7)." }

    @{ Key="agent";    Group="USE"; Color="Green"; Label="Run the three agent tests"
       Action={ throw $FullOnly }; Enabled={ $false }; Why=$FullOnly }

    @{ Key="xapk";     Group="USE"; Color="Green"; Label="Install an .xapk / .apk onto the AVD"
       Action={ throw $FullOnly }; Enabled={ $false }; Why=$FullOnly }

    ## Placed AFTER xapk (index 10, shows as [-]) so it never shifts the [1]-[0]
    ## numbering of the steps above. Full swaps in the real launcher by key.
    @{ Key="launchavd"; Group="USE"; Color="Green"; Label="Launch / relaunch the AVD (cold boot)"
       Action={ throw $FullOnly }; Enabled={ $false }; Why=$FullOnly }

    @{ Key="approve";  Group="USE"; Color="Green"; Label="Approve paired devices"
       Action=$StepApprove
       Enabled={ Test-Path "$Home\.openclaw\devices\paired.json" }
       Why="No paired.json yet. Pair a device from the Control UI or Telegram." }

    @{ Key="status";   Group="USE"; Color="Green"; Label="Status check"
       Action=$StepStatus;   Enabled={ $true }; Why="" }

    @{ Key="dashboard"; Group="USE"; Color="Green"; Label="Open the dashboard (Control UI)"
       Action=$StepDashboard
       Enabled={ $script:Env.OpenClaw -and $script:Env.Cfg -and $script:Env.ControlUi }
       Why={
           if (-not $script:Env.OpenClaw) { "OpenClaw is not installed (step 7)." }
           elseif (-not $script:Env.Cfg)  { "OpenClaw is not configured (step 7)." }
           else { 'controlUi.allowInsecureAuth is absent from openclaw.json, so the Control UI will refuse your token over plain http. Set $EnableDashboard = $true and re-run step 7.' }
       } }

    @{ Key="docs";     Group="USE"; Color="Green"; Label="Generate README.md, LICENSE, .gitignore"
       Action=$StepReadme;   Enabled={ [bool]$PSCommandPath }
       Why="Only works when run as a file, not piped from the web." }

    @{ Key="uninstall"; Group="DANGER"; Color="Red"; Label="Uninstall everything"
       Action=$StepUninstall; Enabled={ $script:Env.Installed }
       Why="Nothing is installed." }
)

## Full uses this to replace a placeholder in place, preserving position.
function Set-MenuItem {
    param(
        [string]$Key,
        [scriptblock]$Action,
        [scriptblock]$Enabled,
        $Why,
        [string]$Label
    )
    $item = $script:Items | Where-Object { $_.Key -eq $Key }
    if (-not $item) { throw "Set-MenuItem: no menu item with key '$Key'" }
    if ($Action)  { $item.Action  = $Action }
    if ($Enabled) { $item.Enabled = $Enabled }
    if ($PSBoundParameters.ContainsKey('Why'))   { $item.Why   = $Why }
    if ($Label)   { $item.Label = $Label }
}

function Show-Menu {
    param([int]$Selected)
    Clear-Host

    ## ASCII only. Box-drawing characters render as mojibake in Windows
    ## PowerShell 5.1 consoles that are not set to a UTF-8 code page.
    Write-Host ""
    Write-Host "  +==============================================================+" -ForegroundColor DarkCyan
    ## Centre the title in the 62-char slot; the edition name changes width
    $title = "OpenClaw + Ollama  --  $script:Edition build"
    $left  = [Math]::Max(0, [int]((62 - $title.Length) / 2))
    $cell  = (" " * $left) + $title
    $cell  = $cell.PadRight(62).Substring(0, 62)
    Write-Host "  |" -ForegroundColor DarkCyan -NoNewline
    Write-Host $cell -ForegroundColor White -NoNewline
    Write-Host "|" -ForegroundColor DarkCyan
    Write-Host "  +==============================================================+" -ForegroundColor DarkCyan
    Write-Host ""

    ## ---- live environment status ----
    $e = $script:Env

    function Stat($label, $good) {
        Write-Host "  " -NoNewline
        if ($good) { Write-Host "[ ok ]" -ForegroundColor Green    -NoNewline }
        else       { Write-Host "[ -- ]" -ForegroundColor DarkGray -NoNewline }
        Write-Host " $label" -ForegroundColor Gray
    }

    Stat "hyper-v"        $e.HyperV
    Stat "adb + avd"      ($e.Adb -and $e.Avd)
    Stat "device online"  $e.Device
    Stat "ollama + model" ($e.Ollama -and $e.Model)
    Stat "openclaw"       ($e.OpenClaw -and $e.Cfg)
    Stat "telegram token" $e.Token

    Write-Host ""
    Write-Host "  model  " -ForegroundColor DarkGray -NoNewline
    Write-Host $Model -ForegroundColor Yellow -NoNewline
    Write-Host "   ctx " -ForegroundColor DarkGray -NoNewline
    Write-Host $NumCtx -ForegroundColor Yellow -NoNewline
    Write-Host "   avd " -ForegroundColor DarkGray -NoNewline
    Write-Host $AvdName -ForegroundColor Yellow -NoNewline
    Write-Host "   dashboard " -ForegroundColor DarkGray -NoNewline
    if ($EnableDashboard) { Write-Host "on" -ForegroundColor Yellow }
    else                  { Write-Host "off" -ForegroundColor DarkGray }
    Write-Host ""

    if (-not (Test-Admin)) {
        Write-Host "  !! not running as Administrator -- most steps will fail" -ForegroundColor Red
        Write-Host ""
    }

    ## ---- items, grouped ----
    $lastGroup = ""
    for ($i = 0; $i -lt $script:Items.Count; $i++) {
        $item = $script:Items[$i]
        $on   = [bool](& $item.Enabled)

        if ($item.Group -ne $lastGroup) {
            Write-Host ""
            switch ($item.Group) {
                "SETUP"  { Write-Rule "setup (run in order, reboot between 2 and 3)" DarkCyan }
                "USE"    { Write-Rule "use" DarkGreen }
                "DANGER" { Write-Rule "danger" DarkRed }
            }
            $lastGroup = $item.Group
        }

        ## The bracket shows a per-step DONE mark, not a number -- navigation is
        ## by arrow keys, and "which steps are already in place" is what you
        ## actually want to see. 'x' = this step's outcome exists (derived from
        ## live $Env); blank = not done or not applicable. (Number keys 1-9/0
        ## still select by position; they just are not displayed.)
        $e = $script:Env
        $done = switch ($item.Key) {
            'prereqs'   { [bool]($e.Npm -and $e.Npx) }
            'hyperv'    { [bool]$e.HyperV }
            'verify'    { [bool]$e.HyperV }
            'android'   { [bool]$e.Avd }
            'ollama'    { [bool]($e.Model -and (-not $Features.Mcp -or $e.ScrcpyMcp)) }
            'token'     { [bool]$e.Token }
            'openclaw'  { [bool]($e.OpenClaw -and $e.Cfg) }
            'launchavd' { [bool]$e.Device }
            'approve'   { [bool](Test-Path "$Home\.openclaw\devices\paired.json") }
            default     { $false }
        }
        $mark = if ($done) { 'x' } else { ' ' }

        if ($i -eq $Selected) {
            if (-not $on) {
                Write-Host "  > [$mark] $($item.Label)".PadRight(64) -ForegroundColor DarkGray -BackgroundColor Black
            } else {
                $bg = if ($item.Group -eq "DANGER") { "DarkRed" } else { "DarkCyan" }
                Write-Host "  > [$mark] $($item.Label)".PadRight(64) -ForegroundColor White -BackgroundColor $bg
            }
        } elseif (-not $on) {
            ## greyed out: dim everything
            Write-Host "    [$mark] $($item.Label)" -ForegroundColor DarkGray
        } else {
            Write-Host "    [" -ForegroundColor DarkGray -NoNewline
            Write-Host $mark -ForegroundColor $(if ($done) { 'Green' } else { $item.Color }) -NoNewline
            Write-Host "] " -ForegroundColor DarkGray -NoNewline
            Write-Host $item.Label -ForegroundColor Gray
        }
    }

    ## ---- why is the highlighted item unavailable? ----
    Write-Host ""
    $sel = $script:Items[$Selected]
    if (-not (& $sel.Enabled)) {
        ## Why may be a plain string or a scriptblock that inspects state
        $why = if ($sel.Why -is [scriptblock]) { & $sel.Why } else { $sel.Why }

        Write-Host "  unavailable: " -ForegroundColor DarkYellow -NoNewline

        ## Wrap at ~62 chars so long reasons do not smear across the console
        $words = $why -split ' '
        $line  = ""
        $first = $true
        foreach ($w in $words) {
            if (($line.Length + $w.Length + 1) -gt 48) {
                if ($first) { Write-Host $line -ForegroundColor Yellow; $first = $false }
                else        { Write-Host "               $line" -ForegroundColor Yellow }
                $line = $w
            } else {
                $line = if ($line) { "$line $w" } else { $w }
            }
        }
        if ($line) {
            if ($first) { Write-Host $line -ForegroundColor Yellow }
            else        { Write-Host "               $line" -ForegroundColor Yellow }
        }
    } else {
        Write-Host ""
    }

    ## ---- config drift warning ----
    if ($script:Env.DashboardDrift) {
        Write-Host ""
        Write-Host "  note: " -ForegroundColor DarkYellow -NoNewline
        if ($EnableDashboard) {
            Write-Host "`$EnableDashboard is on, but openclaw.json has no controlUi" -ForegroundColor DarkGray
            Write-Host "        block. Re-run step 7 to apply it." -ForegroundColor DarkGray
        } else {
            Write-Host "`$EnableDashboard is off, but openclaw.json still has a" -ForegroundColor DarkGray
            Write-Host "        controlUi block from an earlier run." -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "  " -NoNewline
    Write-Host "Up/Down" -ForegroundColor White -NoNewline
    Write-Host " move   " -ForegroundColor DarkGray -NoNewline
    Write-Host "Enter" -ForegroundColor White -NoNewline
    Write-Host " run   " -ForegroundColor DarkGray -NoNewline
    Write-Host "R" -ForegroundColor White -NoNewline
    Write-Host " refresh   " -ForegroundColor DarkGray -NoNewline
    Write-Host "Esc" -ForegroundColor White -NoNewline
    Write-Host " quit" -ForegroundColor DarkGray
    Write-Host ""
}

function Start-Item {
    param([int]$Index)
    $item = $script:Items[$Index]
    if (-not (& $item.Enabled)) {
        ## Refuse, but audibly. A silent no-op looks like a broken key;
        ## the reason is already on screen under the highlighted row.
        [Console]::Beep(400, 120)
        return
    }
    ## Invoke-Step now returns a result object (for Start-FullTest); discard it
    ## here so it does not print after every interactive step.
    [void](Invoke-Step -Name $item.Label -Body $item.Action)
    ## A step almost always changes state; recompute before the next render
    Update-EnvState
}

## ============================================================
##  Start-FullTest -- the -RunAll driver
##
##  Walks every menu item in order, non-interactively, and writes
##  full_test_report.md. Enabled steps run (via Invoke-Step, which is
##  unattended-safe); disabled steps are recorded as expected-skips with the
##  reason the menu would show. This is the automated end-to-end run: it
##  installs, configures, tests, and ENDS IN THE DESTRUCTIVE UNINSTALL, so it
##  is only for a throwaway / VM box. Preconditions gate each step exactly as
##  in the menu, so e.g. step 7 will skip (not fail) until its inputs exist --
##  run -RunAll again after a reboot to continue past Hyper-V/SDK gates.
## ============================================================
function Start-FullTest {
    Write-Host ""
    Write-Host "  ##############################################################" -ForegroundColor Red
    Write-Host "  #  -RunAll: UNATTENDED end-to-end test of every menu option. #" -ForegroundColor Red
    Write-Host "  #  Installs system components AND runs the irreversible      #" -ForegroundColor Red
    Write-Host "  #  uninstall at the end. Throwaway / VM machines only.        #" -ForegroundColor Red
    Write-Host "  ##############################################################" -ForegroundColor Red
    Write-Host ""

    ## Preserve the CURRENT ~/.openclaw before anything runs: the openclaw step
    ## re-onboards over it and the final uninstall deletes it, so the uninstall's
    ## own backup only catches the throwaway re-onboarded copy -- not what you
    ## started with. This pre-run copy is the one that protects your original
    ## token + paired devices. (Encodes the manual pre-run backup from testing.)
    $ocDir = "$env:USERPROFILE\.openclaw"
    if (Test-Path $ocDir) {
        $ocPre = "$ocDir.prerun-backup.$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item $ocDir $ocPre -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  pre-run backup: ~/.openclaw -> $ocPre" -ForegroundColor Cyan
        Write-Host ""
    }

    ## Update-EnvState spawns native probes (adb, ollama, npm) whose benign
    ## stderr is fatal under Stop; a throw here must not abort the run. Guard
    ## every call, and write the report from a finally so a mid-run throw still
    ## leaves a record (this is the bug that lost the first run's report).
    try { Update-EnvState } catch { }
    $started = Get-Date
    $rows = @()

    try {
        for ($i = 0; $i -lt $script:Items.Count; $i++) {
            $item = $script:Items[$i]
            $n = if ($i -lt 9) { "$($i + 1)" } elseif ($i -eq 9) { "0" } else { "-" }

            $enabled = $false
            try { $enabled = [bool](& $item.Enabled) } catch { }
            if (-not $enabled) {
                $why = try { if ($item.Why -is [scriptblock]) { & $item.Why } else { $item.Why } } catch { "" }
                Write-Host ("  [ skip ] [{0}] {1}" -f $n, $item.Label) -ForegroundColor DarkGray
                $rows += [PSCustomObject]@{ N=$n; Step=$item.Label; Result="SKIP"; Secs=0; Note=$why; Log="" }
                continue
            }

            $r = Invoke-Step -Name $item.Label -Body $item.Action
            try { Update-EnvState } catch { }
            $rows += [PSCustomObject]@{
                N=$n; Step=$item.Label
                Result = if ($r.Failed) { "FAIL" } else { "PASS" }
                Secs   = [int]$r.Elapsed.TotalSeconds
                Note   = ""
                Log    = if ($r.Log) { Split-Path $r.Log -Leaf } else { "" }
            }
        }
    } finally {
        ## ---- write the report (UTF-8, no BOM, like every other file) ----
        $passN = @($rows | Where-Object Result -eq "PASS").Count
        $failN = @($rows | Where-Object Result -eq "FAIL").Count
        $skipN = @($rows | Where-Object Result -eq "SKIP").Count

        $sb = New-Object Text.StringBuilder
        [void]$sb.AppendLine("# Full Test report -- $script:Edition edition")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("- Started: $started")
        [void]$sb.AppendLine("- Ended:   $(Get-Date)")
        [void]$sb.AppendLine("- Host: PowerShell $($PSVersionTable.PSVersion), $([Environment]::MachineName), admin=$([bool](Test-Admin))")
        [void]$sb.AppendLine("- Result: $passN passed, $failN failed, $skipN skipped (expected); $($rows.Count)/$($script:Items.Count) steps recorded")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| # | Step | Result | Secs | Note / skip reason | Log |")
        [void]$sb.AppendLine("| --- | --- | --- | --- | --- | --- |")
        foreach ($row in $rows) {
            $note = ($row.Note -replace '\|', '\|')
            [void]$sb.AppendLine("| $($row.N) | $($row.Step) | $($row.Result) | $($row.Secs) | $note | $($row.Log) |")
        }
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Per-step console transcripts are in ``logs/`` (gitignored).")

        $reportPath = Join-Path $BaseDir "full_test_report.md"
        [IO.File]::WriteAllText($reportPath, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))

        Write-Host ""
        Write-Host "  $passN passed, $failN failed, $skipN skipped" -ForegroundColor (@('Green','Red')[[int]($failN -gt 0)])
        Write-Host "  report: $reportPath" -ForegroundColor Cyan
    }
}

## ------------------------------------------------------------
##  Self-elevation
##
##  Almost every step needs Administrator: winget, DISM, the registry
##  key, the Scheduled Task. Relaunching is friendlier than a warning
##  the user reads after step 1 already failed.
##
##  Only possible when running as a file. Piped from the web there is
##  nothing to relaunch, so fall through with a warning.
## ------------------------------------------------------------
function Request-Elevation {
    if (Test-Admin) { return $true }
    if ($NoElevate) { return $false }

    ## $PSCommandPath inside a function is the SCRIPT's path, but if Full
    ## loaded us that is Lite -- relaunching it would drop the Android
    ## features. Use whichever script was actually invoked.
    $entry = $global:OC_EntryScript
    if (-not $entry) {
        Write-Host "Not elevated, and there is no file to relaunch." -ForegroundColor Yellow
        Write-Host "Open an Administrator PowerShell and run the script again." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        return $false
    }

    Write-Host "This needs Administrator." -ForegroundColor Yellow
    Write-Host "Will relaunch: $entry" -ForegroundColor DarkGray
    if ((Read-Host "Relaunch elevated? (Y/n)") -eq 'n') { return $false }

    ## Forward the arguments the entry script was given, so an override
    ## like -NumCtx 32768 survives the relaunch.
    $argv = @("-ExecutionPolicy","Bypass","-File","`"$entry`"")
    if ($global:OC_EntryArgs) {
        foreach ($kv in $global:OC_EntryArgs.GetEnumerator()) {
            if ($kv.Value -is [switch]) {
                if ($kv.Value.IsPresent) { $argv += "-$($kv.Key)" }
            } else {
                $argv += @("-$($kv.Key)", "`"$($kv.Value)`"")
            }
        }
    }

    try {
        Start-Process powershell -Verb RunAs -ArgumentList $argv -ErrorAction Stop
        exit 0          ## the elevated copy takes over
    } catch {
        ## User clicked No on the UAC prompt
        Write-Host "Elevation declined. Continuing unelevated." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return $false
    }
}

function Start-Menu {
    [void](Request-Elevation)

    ## -RunAll bypasses the interactive menu entirely and drives every step
    ## unattended. Same entry point in both editions, so Full's Start-Menu call
    ## routes here too.
    if ($RunAll) { Start-FullTest; return }

    ## -StartAvd: just launch/relaunch the AVD and exit. Runs the launchavd menu
    ## item (Full's real launcher; Lite's placeholder throws FullOnly).
    if ($StartAvd) {
        Update-EnvState
        $item = $script:Items | Where-Object Key -eq 'launchavd'
        [void](Invoke-Step -Name $item.Label -Body $item.Action)
        return
    }

    Write-Host "Checking environment..." -ForegroundColor DarkGray
    Update-EnvState

    $selected = 0
    while ($true) {
        Show-Menu -Selected $selected
        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'UpArrow'   { $selected = ($selected - 1 + $script:Items.Count) % $script:Items.Count }
            'DownArrow' { $selected = ($selected + 1) % $script:Items.Count }
            'Home'      { $selected = 0 }
            'End'       { $selected = $script:Items.Count - 1 }
            'Enter'     { Start-Item -Index $selected }
            'Escape'    { Clear-Host; Write-Host "Bye."; return }
            'R'         { Write-Host "  refreshing..." -ForegroundColor DarkGray; Update-EnvState }
            default {
                $c = $key.KeyChar
                $idx = -1
                if     ($c -match '[1-9]') { $idx = [int]"$c" - 1 }
                elseif ($c -eq '0')        { $idx = 9 }
                if ($idx -ge 0 -and $idx -lt $script:Items.Count) {
                    $selected = $idx
                    Start-Item -Index $selected
                }
            }
        }
    }
}

## ============================================================
##  Auto-start, unless we were loaded as a library.
##
##  The Full script sets $global:OC_NoAutoStart before dot-sourcing this
##  file, appends its own menu items, then calls Start-Menu itself. That
##  is the whole extension mechanism -- no code here is duplicated there.
## ============================================================
if (-not $global:OC_NoAutoStart) {
    Start-Menu
}
