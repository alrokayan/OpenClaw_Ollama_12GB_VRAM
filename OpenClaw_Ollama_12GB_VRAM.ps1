#Requires -Version 5.1

<#
.SYNOPSIS
    OpenClaw + Ollama. A local AI agent on Telegram, backed by a
    model served from your own GPU, that drives an Android emulator.

.DESCRIPTION
    This single, self-contained script installs and configures:

      - Ollama serving qwen3.5:latest, context capped to 65536
      - The OpenClaw gateway, bound to loopback
      - A Telegram bot, DM-allowlisted to one user id
      - DuckDuckGo web search (key-free)
      - The Control UI dashboard
      - An Android emulator (Android Studio, SDK, Pixel_5 AVD, Hyper-V)
      - mobile-mcp as an MCP server, plus a device-control skill so the
        agent can drive the emulator

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
    powershell -ExecutionPolicy Bypass -File .\OpenClaw_Ollama_12GB_VRAM.ps1

    Opens the menu.

.EXAMPLE
    .\OpenClaw_Ollama_12GB_VRAM.ps1 -NumCtx 32768 -NoDashboard

    Overrides. -NumCtx is range-validated, so a typo fails at parse time
    rather than halfway through configuring the gateway.

.EXAMPLE
    $f = "$env:TEMP\OpenClaw.ps1"
    irm https://raw.githubusercontent.com/alrokayan/OpenClaw_Ollama_12GB_VRAM/main/OpenClaw_Ollama_12GB_VRAM.ps1 -OutFile $f
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
##      .\OpenClaw_Ollama_12GB_VRAM.ps1 -NumCtx 32768 -NoDashboard
## ============================================================
[CmdletBinding()]
param(
    ## Your numeric Telegram user id. Message @userinfobot to find it.
    [string]$TelegramId = "6420885035",

    ## Name the presence pings greet you by ("Hey <name>, I'm back online").
    ## Defaults to the Windows username; set to "" for a nameless "Hey, ...".
    [string]$OwnerName = $env:USERNAME,

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

    ## Run every menu step in order, non-interactively, writing
    ## full_test_report.md. Implies -Unattended. Ends in the DESTRUCTIVE
    ## uninstall -- only for a throwaway/VM box. See Start-FullTest.
    [switch]$RunAll,

    ## Launch/relaunch the AVD (cold boot) and exit, without opening the menu.
    ## A CLI shortcut for the menu's "Launch / relaunch the AVD" item.
    [switch]$StartAvd
)

$ErrorActionPreference = "Stop"

## ------------------------------------------------------------
##  Who is the entry point?
##
##  Record the invoked script + its args once, so an elevated relaunch
##  (below) re-runs the same file with the same arguments.
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
##  One unified script: Android, the MCP, and the device skill are always
##  on. These flags are the single switch left from the old Lite/Full split
##  -- set one to $false (before launch, via $global:OC_Features) for an
##  Android-less run. Shared steps consult them rather than being rewritten.
## ============================================================
if (-not (Get-Variable -Name OC_Features -Scope Global -ErrorAction SilentlyContinue)) {
    $global:OC_Features = @{
        Android   = $true   # Android Studio, SDK, the Pixel_5 AVD, Hyper-V/WHPX
        Mcp       = $true   # mobile-mcp registered as an MCP server
        MobileMcpSkill = $true   # the mobile-mcp device-control skill
    }
}
$Features = $global:OC_Features

## Shown in the banner.
if (-not $script:Edition) { $script:Edition = "Android" }

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

    $s.MobileMcp = $false
    if ($s.Npm) {
        $s.MobileMcp = [bool](npm list -g --depth=0 2>$null | Select-String '@mobilenext/mobile-mcp')
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
## ============================================================
##  Ensure a 'python3' binary exists on PATH.
##
##  Windows Python ships 'python.exe' but NOT 'python3.exe', so the bare name
##  'python3' never resolves. Skills that declare a python3 requirement (e.g.
##  @freeter226/base64-toolkit -- the one that lets the model handle inline
##  base64 screenshot data) therefore stay INELIGIBLE. openclaw checks bins
##  live (PATH + PATHEXT) but caches skill eligibility at gateway start, so the
##  binary must exist BEFORE the gateway ever evaluates -- hence this runs in
##  prereqs, the first step.
##
##  The fix is a REAL python3.exe (a copy of python.exe in the same, on-PATH
##  dir). A .cmd/.bat shim would satisfy a shell 'where' but NOT Node's direct
##  spawn (PATHEXT is not applied to spawned children -- the same trap that
##  forces the cmd.exe wrapper for npx). We reuse an existing Python if present
##  (so a user's 3.14 is not double-installed) and only winget-install 3.12 when
##  none is found.
## ============================================================
function Ensure-Python3 {
    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        Write-Host "python3 already resolves on PATH." -ForegroundColor DarkGray
        return $true
    }

    ## An existing real python.exe on PATH? (skip the WindowsApps Store stub)
    $py = (Get-Command python -ErrorAction SilentlyContinue |
           Where-Object { $_.Source -and ($_.Source -notmatch 'WindowsApps') } |
           Select-Object -First 1).Source

    ## Not on PATH -- probe the standard per-user / machine install dirs (covers a
    ## python that is installed but whose PATH entry has not reached this session).
    if (-not $py) {
        $py = (Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
                             "$env:ProgramFiles\Python3*\python.exe",
                             "${env:ProgramFiles(x86)}\Python3*\python.exe" -ErrorAction SilentlyContinue |
               Sort-Object FullName -Descending | Select-Object -First 1).FullName
    }

    ## Still nothing -- install a stable Python (winget takes ONE id per call).
    if (-not $py) {
        Write-Host "python not found -- installing Python 3.12 via winget..." -ForegroundColor Yellow
        $ErrorActionPreference = 'Continue'
        winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
        $ErrorActionPreference = 'Stop'
        $py = (Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
                             "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue |
               Sort-Object FullName -Descending | Select-Object -First 1).FullName
    }
    if (-not $py) {
        Write-Host "Could not locate python.exe. Install Python 3 manually, then re-run prereqs." -ForegroundColor Yellow
        return $false
    }

    ## Create python3.exe beside python.exe (real exe -> satisfies 'where' AND spawn).
    $dir = Split-Path $py -Parent
    $py3 = Join-Path $dir 'python3.exe'
    if (Test-Path $py3) {
        Write-Host "python3.exe already present: $py3" -ForegroundColor DarkGray
    } else {
        Copy-Item $py $py3 -Force
        Write-Host "Created python3.exe -> $py3" -ForegroundColor Green
    }

    ## Make it resolvable now (this session) and persistently for the user, so
    ## the logon-triggered gateway inherits it after the next sign-in.
    if (($env:PATH -split ';') -notcontains $dir) { $env:PATH = "$dir;$env:PATH" }
    $userPath = [Environment]::GetEnvironmentVariable('PATH','User')
    if (-not $userPath -or (($userPath -split ';') -notcontains $dir)) {
        $newUserPath = (@($userPath.TrimEnd(';'), $dir) | Where-Object { $_ }) -join ';'
        [Environment]::SetEnvironmentVariable('PATH', $newUserPath, 'User')
        Write-Host "Added $dir to the user PATH (new shells + gateway after next logon)." -ForegroundColor DarkGray
    }

    return [bool](Get-Command python3 -ErrorAction SilentlyContinue)
}

$StepPrereqs = {
    ## Store python stubs shadow a real install
    Remove-Item "$env:LOCALAPPDATA\Microsoft\WindowsApps\python.exe"  -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Microsoft\WindowsApps\python3.exe" -ErrorAction SilentlyContinue

    ## winget install takes ONE id per call. Passing several silently
    ## installs only the first.
    ##
    ## No jq: config goes through "openclaw config patch" and paired.json
    ## through ConvertFrom-Json. Python is provisioned separately below
    ## (Ensure-Python3) -- it needs a 'python3.exe' shim, not just the package.
    $packages = @('Git.Git','7zip.7zip','OpenJS.NodeJS','Ollama.Ollama')
    if ($Features.Android) {
        ## the JDK is for Android Studio
        $packages += @('Microsoft.OpenJDK.17')
    }
    foreach ($p in $packages) {
        Write-Host "installing $p" -ForegroundColor DarkGray
        winget install -e --id $p --accept-source-agreements --accept-package-agreements
    }

    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v "AllowDevelopmentWithoutDevLicense" /d "1"
    winget install Microsoft.VCRedist.2015+.x64 --accept-source-agreements --accept-package-agreements

    ## Provide a real 'python3' binary. base64-toolkit (and other python skills)
    ## require it; Windows Python only ships 'python.exe'. Done here, before the
    ## gateway ever caches skill eligibility, so those skills are eligible from
    ## the first run. See Ensure-Python3 for the why.
    Ensure-Python3

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
##  Step 5 -- mobile-mcp + Ollama + model
## ============================================================
$StepOllama = {
    ## npm and ollama stream progress/warnings to stderr, which is fatal under
    ## the global Stop preference even when the command succeeds ("pulling
    ## manifest ..." tripped this on the first -RunAll). Drive them by
    ## $LASTEXITCODE, not by stderr. Explicit 'throw' still fails the step.
    $ErrorActionPreference = 'Continue'

    if ($Features.Mcp) {
        npm install -g @mobilenext/mobile-mcp@latest
        if ($LASTEXITCODE -ne 0) { throw "npm install -g @mobilenext/mobile-mcp failed." }
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

    ## Preflight. The mobile-mcp skill needs adb on PATH; missing
    ## either and the skill is silently ineligible -- the agent never learns it
    ## can drive the phone.
    $needed = @("npx","ollama")
    if ($Features.Android) { $needed += @("adb") }
    foreach ($bin in $needed) {
        if (-not (Get-Command $bin -ErrorAction SilentlyContinue)) {
            throw "$bin not on PATH. Open a NEW terminal."
        }
    }
    if ($Features.Mcp) {
        if (-not (npm list -g --depth=0 2>$null | Select-String '@mobilenext/mobile-mcp')) {
            throw "mobile-mcp missing. Install it first."
        }
        ## No attached device looks exactly like "the model refused to call tools"
        if ((adb shell getprop sys.boot_completed 2>$null | Out-String).Trim() -ne "1") {
            Write-Host "WARNING: AVD not booted. mobile-mcp tools will fail." -ForegroundColor Yellow
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
        #ollama launch openclaw --model qwen3.5 --yes
    }

    ## 'openclaw config file' can return a ~-prefixed path. PowerShell cmdlets
    ## (Test-Path, Copy-Item, Get-Content) expand ~, but the .NET [IO.File] APIs
    ## below do NOT -- they resolve ~ against the current directory, so the .env
    ## write lands at <cwd>\~\.openclaw\.env and fails. Expand ~ to $Home once,
    ## here, so every later use (Split-Path, WriteAllLines) is an absolute path.
    openclaw doctor --fix 2>$null
    $cfg = (openclaw config file 2>$null).Trim()
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

    ## The channel config alone is NOT enough: the telegram PLUGIN must be enabled
    ## in plugins.entries or the channel never loads (this was the "bot never
    ## replies" bug). session.dmScope "per-channel-peer" keeps each DM peer's
    ## session isolated. channels.telegram.enabled makes the channel live;
    ## dmPolicy allowlist + allowFrom gates DMs; groupAllowFrom gates who the bot
    ## obeys in groups; groups["*"].requireMention keeps it silent in groups unless
    ## @-mentioned. commands.* scopes owner-only commands. botToken pulls the token
    ## from ~/.openclaw/.env (never inlined here).
    Patch "telegram" @"
{ plugins: { entries: { telegram: { enabled: true } } },
  session: { dmScope: "per-channel-peer" },
  channels: { telegram: {
    enabled: true,
    botToken: "`${TELEGRAM_BOT_TOKEN}",
    dmPolicy: "allowlist", allowFrom: ["$TelegramId"],
    groupAllowFrom: ["$TelegramId"],
    groups: { "*": { requireMention: true } },
    streaming: { mode: "progress" } } },
  commands: {
    allowFrom: { telegram: ["$TelegramId"] },
    ownerAllowFrom: ["telegram:$TelegramId"] } }
"@

    if ($Features.Mcp) {
        ## cmd.exe wrapper: Node's spawn() throws ENOENT on bare 'npx' (no PATHEXT
        ## for child processes) and EINVAL on 'npx.cmd' (cannot spawn .cmd directly).
        ## --no-probe: the gateway is not running yet at this point in the setup.
        openclaw mcp add mobile --command cmd.exe --arg /c --arg npx --arg -y --arg @mobilenext/mobile-mcp@latest --no-probe
        if ($LASTEXITCODE -ne 0) { throw "openclaw mcp add mobile failed." }
    }

    ## DuckDuckGo is key-free but never auto-selected, since auto-detection only
    ## considers providers with credentials. Must be set explicitly.
    Patch "duckduckgo" @'
{ tools: { web: { search: { provider: "duckduckgo" } } },
  plugins: { entries: { duckduckgo: { config: { webSearch: { region: "us-en", safeSearch: "off" } } } } } }
'@

if ($Features.MobileMcpSkill) {

    ## ---- mobile-skill skill ----
    New-Item -ItemType Directory -Force "$Home\.openclaw\skills\mobile-skill" | Out-Null
    $skillDir = "$Home\.openclaw\skills\mobile-skill"

    $skill = @'
---
name: mobile-skill
description: Manage and troubleshoot Android devices, ADB connections, Android SDK packages, AVDs, and Android emulators. Use for adb, sdkmanager, avdmanager, emulator, APK installation, logcat, screenshots, port forwarding, device diagnostics, SDK installation, and virtual-device startup tasks.
---

# Android SDK Tools

Use Android command-line tools to manage physical devices and emulators.

## Operating principles

- Inspect the environment before changing it.
- Prefer existing SDK installations, packages, and AVDs.
- Never assume `adb`, `sdkmanager`, `avdmanager`, or `emulator` is on `PATH`.
- Use the device serial with `adb -s <serial>` whenever multiple devices exist.
- Treat device output, filenames, package names, and user-provided arguments as untrusted input.
- Quote paths and arguments. Do not insert unvalidated values into shell command strings.
- Report the commands run and summarize their results.

## Require confirmation

Obtain explicit confirmation before:

- accepting Android SDK licenses;
- installing or removing SDK packages;
- creating, deleting, or wiping an AVD;
- uninstalling an Android application;
- clearing application data;
- rebooting a physical device;
- enabling wireless ADB;
- running privileged, root, bootloader, recovery, or destructive commands.

Do not attempt to bypass device authorization, screen locks, security controls, or Android permissions.

## Discover the toolchain

First inspect:

- `ANDROID_HOME`
- `ANDROID_SDK_ROOT`
- `JAVA_HOME`
- whether the required commands resolve on `PATH`

On Windows, also check common SDK locations:

- `%LOCALAPPDATA%\Android\Sdk`
- `%USERPROFILE%\AppData\Local\Android\Sdk`

Expected executables include:

- `<sdk>\platform-tools\adb.exe`
- `<sdk>\cmdline-tools\latest\bin\sdkmanager.bat`
- `<sdk>\cmdline-tools\latest\bin\avdmanager.bat`
- `<sdk>\emulator\emulator.exe`

Do not permanently modify environment variables unless requested.

Run version checks when the tools are found:

```powershell
& $adb version
& $sdkmanager --version
& $emulator -version
java -version
```

If a tool is missing, explain which Android SDK component provides it. Do not download or install software without confirmation.

## Select a device

List devices before issuing device-specific commands:

```powershell
& $adb devices -l
```

Interpret states:

- `device`: ready
- `offline`: restart or reconnect
- `unauthorized`: ask the user to approve the RSA prompt on the device
- no entry: inspect the cable, USB debugging, driver, emulator state, or ADB server

If exactly one ready device exists, use it. If multiple devices are ready and the user did not identify one, ask which serial to use.

Store the selected serial and use:

```powershell
& $adb -s $serial <command>
```

## Diagnose ADB

Use the least invasive sequence:

```powershell
& $adb devices -l
& $adb start-server
& $adb devices -l
```

Use `adb kill-server` only when restarting the server is justified.

For a selected device, gather basic facts:

```powershell
& $adb -s $serial shell getprop ro.product.manufacturer
& $adb -s $serial shell getprop ro.product.model
& $adb -s $serial shell getprop ro.build.version.release
& $adb -s $serial shell getprop ro.build.version.sdk
& $adb -s $serial shell wm size
& $adb -s $serial shell wm density
```

Do not dump sensitive device data unnecessarily.

## Work with SDK packages

Inspect installed and available packages:

```powershell
& $sdkmanager --list
```

Before installing, state the exact package identifiers and expected purpose.

Typical packages include:

```text
platform-tools
emulator
cmdline-tools;latest
platforms;android-<api>
build-tools;<version>
system-images;android-<api>;google_apis;x86_64
```

After receiving confirmation, install exact identifiers:

```powershell
& $sdkmanager "platform-tools" "emulator"
```

Do not automatically select the newest API level when project files specify a required `compileSdk`, `targetSdk`, build-tools version, or emulator image.

## Manage AVDs

List existing AVDs and compatible targets:

```powershell
& $emulator -list-avds
& $avdmanager list avd
& $avdmanager list device
& $sdkmanager --list
```

Prefer an existing compatible AVD.

Before creating an AVD, confirm:

- AVD name
- API level
- image flavor
- architecture
- hardware profile

After confirmation, create it using exact values:

```powershell
"no" | & $avdmanager create avd `
  --name $avdName `
  --package $systemImage `
  --device $deviceProfile
```

Validate names and package identifiers against command output before execution.

## Start an emulator

Start an existing AVD without wiping its state:

```powershell
& $emulator -avd $avdName
```

Use additional flags only when needed:

```text
-no-snapshot-load
-no-boot-anim
-no-window
-gpu auto
-port <even-number>
```

Do not use `-wipe-data` without explicit confirmation.

Wait for the emulator to appear in `adb devices`, then check boot completion:

```powershell
& $adb -s $serial wait-for-device
& $adb -s $serial shell getprop sys.boot_completed
```

Continue only when the result is `1`. Use a bounded timeout and report failure rather than waiting forever.

## Install and inspect applications

Verify an APK exists before installation:

```powershell
& $adb -s $serial install -r -- $apkPath
```

Do not add `-d`, `-g`, or `-t` unless the task requires it and their effects are explained.

Inspect a package:

```powershell
& $adb -s $serial shell pm path $packageName
& $adb -s $serial shell dumpsys package $packageName
```

Validate package names using this pattern before placing them in commands:

```text
^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$
```

## Collect diagnostics

Use bounded log collection instead of leaving `logcat` running indefinitely:

```powershell
& $adb -s $serial logcat -d -t 500
```

Filter by a known tag, PID, or package when possible. Avoid exposing tokens, account data, personal messages, or unrelated application logs.

Capture a screenshot when useful:

```powershell
& $adb -s $serial exec-out screencap -p > $outputPath
```

Verify the output file exists and is non-empty.

## Verify completion

After making a change:

1. Re-run the relevant listing or status command.
2. Confirm the expected device, package, SDK component, or AVD exists.
3. Report the selected SDK path and device serial.
4. Mention warnings, authorization prompts, reboots, or manual steps.
5. Never claim success based only on a command exit code when state can be checked.
'@

    ## A BOM before the opening --- breaks YAML frontmatter and the skill never
    ## loads. Set-Content -Encoding utf8 writes a BOM on PS 5.1; this does not.
    [IO.File]::WriteAllText("$skillDir\SKILL.md", $skill,
        (New-Object Text.UTF8Encoding($false)))

    ## maxSkillsInPrompt 10 (was 5): with a mobile device the agent needs the
    ## mobile-skill skill to actually land in the prompt.
    ## maxSkillsPromptChars 8000
    Patch "skills" @'
{ skills: {
    allowBundled: [],
    load: { extraDirs: ["~/.openclaw/skills"] },
    limits: { maxSkillsInPrompt: 10, maxSkillsPromptChars: 8000 } } }
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

    Write-Host "`n=== 3. MCP tools discovered? (must list mobile TOOLS) ===" -ForegroundColor Cyan
    openclaw mcp status --verbose
    openclaw mcp doctor --probe

    Write-Host "`n=== 4. mobile-skill skill loaded? ===" -ForegroundColor Cyan
    openclaw skills info mobile-skill

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
    }
    if ($Features.Mcp) {
        Test-Case "mobile-mcp installed globally" {
            [bool](npm list -g --depth=0 2>$null | Select-String '@mobilenext/mobile-mcp')
        } "npm install -g @mobilenext/mobile-mcp@latest"
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

    if ($Features.Mcp -or $Features.MobileMcpSkill) {
        Write-Rule "tools" DarkCyan
    }

    if ($Features.Mcp) {
        Test-Case "mobile MCP server started" {
            $out = openclaw mcp status --verbose 2>$null | Out-String
            ($out -match 'mobile') -and ($out -notmatch 'failed to start')
        } "ENOENT on 'npx', EINVAL on 'npx.cmd'. Use cmd.exe /c npx -y @mobilenext/mobile-mcp@latest."
    }

    if ($Features.MobileMcpSkill) {
        Test-Case "mobile-skill skill loaded" {
            openclaw skills info mobile-skill *>$null
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
## The three agent tests drive the device over the MCP bridge.
$StepTest = {
    if (-not $Features.Mcp) { throw "Agent device tests need the MCP bridge (Features.Mcp)." }

    ## 'openclaw agent' streams to stderr (and node prints gateway diagnostics
    ## there); fatal under Stop even when a prompt completes. Continue so all
    ## three prompts run and you can judge tool-calls vs narration from output.
    $ErrorActionPreference = 'Continue'

    Write-Host "Each test FIRES a prompt to your Telegram (as if you texted the bot)" -ForegroundColor Yellow
    Write-Host "and reports SENT -- watch the chat for the agent's reply. The adb probe" -ForegroundColor Yellow
    Write-Host "under each test shows the ACTUAL device state, pass or fail." -ForegroundColor Yellow

    $adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    if (-not (Test-Path $adb)) { $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source }

    ## Run one agent prompt with --json (for the local PASS/FAIL parse) and also
    ## --deliver the reply to Telegram (--reply-channel/--reply-to $TelegramId), so
    ## each test answers you IN THE CHAT -- as if you had texted the bot -- not only
    ## in this terminal. Then run a $Probe that shows the ACTUAL device state via adb,
    ## so each test shows the model's answer AND what really happened on the screen.
    function Invoke-AgentTest {
        param([string]$Title, [string]$Message, [scriptblock]$Probe)
        Write-Host "`n===== $Title =====" -ForegroundColor Magenta
        Write-Host "  prompt: $Message" -ForegroundColor DarkGray
        ## Fresh session per test: a bloated context (e.g. a giant screenshot
        ## base64 from an earlier run) must never carry over and choke the model.
        ## Telegram /reset clears the DM session, NOT this CLI 'test' session, so
        ## we make a new one each call instead of reusing a fixed key.
        $sessionKey = "test-" + (Get-Date -Format 'HHmmssfff')
        ## --json drives the local check; --deliver routes the reply to your Telegram.
        $agentArgs = @('agent','--session-key',$sessionKey,'--message',$Message,'--json')
        if ($TelegramId) {
            $agentArgs += @('--deliver','--reply-channel','telegram','--reply-to',$TelegramId)
            Write-Host "  (reply delivered to Telegram chat $TelegramId)" -ForegroundColor DarkGray
        }
        $raw = (openclaw @agentArgs 2>&1 | Out-String).Trim()
        ## Outcome is SENT, not PASS: the reply is delivered to Telegram, so the
        ## CLI cannot judge whether the agent actually succeeded -- only that the
        ## prompt was dispatched. Watch the chat (and the adb probe) for the truth.
        if ($TelegramId) {
            if ($LASTEXITCODE -eq 0) { Write-Host "  [SENT] fired to your Telegram -- watch the chat for the reply" -ForegroundColor Green }
            else                     { Write-Host "  [NOT SENT] Telegram delivery failed (exit $LASTEXITCODE)" -ForegroundColor Red }
        } else {
            Write-Host "  [CLI ONLY] no -TelegramId set, nothing delivered" -ForegroundColor Yellow
        }
        $shown = $false
        try {
            $o = $raw | ConvertFrom-Json
            foreach ($f in 'text','answer','result','message','output','content','reply') {
                $v = $o.$f
                if (($v -is [string]) -and $v.Trim()) { Write-Host "  model: $($v.Trim())" -ForegroundColor Gray; $shown = $true; break }
            }
            ## surface tool calls when the JSON exposes them
            foreach ($tc in @($o.toolCalls) + @($o.tools)) {
                if ($tc -and $tc.name) { Write-Host "  tool:  $($tc.name)" -ForegroundColor Cyan }
            }
        } catch { }
        if (-not $shown) {
            $trim = if ($raw.Length -gt 600) { $raw.Substring(0,600) + " ..." } else { $raw }
            Write-Host "  result (raw): $trim" -ForegroundColor DarkGray
        }
        Write-Host "  -- adb probe (what actually happened) --" -ForegroundColor DarkCyan
        if ($Probe -and $adb) { & $Probe }
    }

    ## 1. Screenshot -- ask in plain language so the agent uses mobile-mcp's
    ##    mobile_save_screenshot tool to capture and deliver the screen.
    Invoke-AgentTest "1. Screenshot" `
        'Send me a screenshot of the current phone screen.' `
        {
            $shot = Join-Path $LogDir "agent-screenshot.png"
            & $adb shell screencap -p /sdcard/agent-shot.png 2>$null
            & $adb pull /sdcard/agent-shot.png $shot 2>$null | Out-Null
            $sz = if (Test-Path $shot) { (Get-Item $shot).Length } else { 0 }
            if ($sz -gt 1000) { Write-Host "  screenshot: $shot ($([int]($sz/1KB)) KB) -- non-blank, display renders" -ForegroundColor Green }
            else { Write-Host "  screenshot near-empty ($sz B) -- display not rendering (check the iGPU pin)" -ForegroundColor Red }
        }

    ## 2. Home key
    Invoke-AgentTest "2. Home key" `
        'Press the device Home button (via adb shell input keyevent HOME) to reset to a known state' `
        {
            $fw = & $adb shell dumpsys window 2>$null | Select-String 'mCurrentFocus' | Select-Object -First 1
            $focus = if ($fw) { $fw.Line.Trim() } else { "n/a" }
            Write-Host "  focused window: $focus" -ForegroundColor Gray
            if ($focus -match 'launcher') { Write-Host "  -> home screen (launcher focused)" -ForegroundColor Green }
        }

    ## 3. Built-in Messages app (com.google.android.apps.messaging ships on the
    ##    stock image; Telegram is not preinstalled, so a Telegram test can never
    ##    complete the send).
    Invoke-AgentTest "3. Messages" `
        'Open the built-in Messages app (com.google.android.apps.messaging), start a new conversation, type Hi in the message field, then send' `
        {
            $fw = & $adb shell dumpsys window 2>$null | Select-String 'mCurrentFocus' | Select-Object -First 1
            $focus = if ($fw) { $fw.Line.Trim() } else { "n/a" }
            Write-Host "  focused window: $focus" -ForegroundColor Gray
            if ($focus -match 'messaging') { Write-Host "  -> Messages app in the foreground" -ForegroundColor Green }
        }
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
    Row "mobile-mcp" $(if ($e.MobileMcp) { "installed" } else { "missing" }) $e.MobileMcp
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
    Write-Rule "mobile-skill skill" DarkCyan
    $skillPath = "$Home\.openclaw\skills\mobile-skill\SKILL.md"
    if (Test-Path $skillPath) {
        Row "SKILL.md" "present" $true
        ## A BOM here silently breaks the YAML frontmatter
        $bytes = [IO.File]::ReadAllBytes($skillPath)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Row "no BOM" $(if ($hasBom) { "HAS BOM" } else { "clean" }) (-not $hasBom)
        if ($e.OpenClaw) {
            openclaw skills info mobile-skill *>$null
            Row "loaded by openclaw" $(if ($LASTEXITCODE -eq 0) { "yes" } else { "no" }) ($LASTEXITCODE -eq 0)
        }
    } else {
        Row "SKILL.md" "missing" $false
    }

    ## ---- readiness verdict ----
    Write-Host ""
    Write-Rule "" DarkGray
    $ready = $e.HyperV -and $e.Adb -and $e.Device -and $e.Ollama -and $e.Model -and
             $e.OpenClaw -and $e.Cfg -and $e.Token -and $e.MobileMcp
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
        if (-not $e.MobileMcp) { Write-Host "    mobile-mcp        (step 5)" -ForegroundColor DarkYellow }
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
    Add-Line "                       +-->  MCP: mobile-mcp  -->  adb  -->  Pixel_5 AVD"
    Add-Line "                       |"
    Add-Line "                       +-->  skill: mobile-skill (inspect / reason / act)"
    Add-Line '```'
    Add-Line ""
    Add-Line "The emulator renders in hardware (``-gpu host``) but is pinned to the **integrated**"
    Add-Line "GPU (via the Windows per-app graphics preference), so on a 12 GB card every"
    Add-Line "megabyte of the discrete card's VRAM stays with the model. Software rendering"
    Add-Line "(``swiftshader_indirect``) was the original plan but drew a blank/white framebuffer"
    Add-Line "on the build host, so hardware GL on the iGPU is the reliable way to the same goal."
    Add-Line ""

    ## ---------------- install ----------------
    Add-Line "## Install"
    Add-Line ""
    Add-Line "This is a single, self-contained script. It installs Ollama + qwen3.5, the"
    Add-Line "OpenClaw gateway with your Telegram bot, web search, and the Control UI"
    Add-Line "dashboard, plus an Android emulator (Android Studio + a Pixel_5 AVD) that the"
    Add-Line "agent drives over mobile-mcp -- so the bot can see the screen and tap, type,"
    Add-Line "and swipe on it."
    Add-Line ""
    Add-Line "One-liner install:"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line "\$f = \"\$env:TEMP\OpenClaw.ps1\"; irm $RepoRaw/OpenClaw_Ollama_12GB_VRAM.ps1 -OutFile \$f; Unblock-File \$f; & \$f"
    Add-Line '```'
    Add-Line ""
    Add-Line "Or run straight from memory. It uses the script's **default parameters** (you"
    Add-Line "cannot pass ``-NumCtx``/``-TelegramId`` through it) and the *Generate README*"
    Add-Line "step is unavailable (no file on disk):"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line "& ([scriptblock]::Create((irm $RepoRaw/OpenClaw_Ollama_12GB_VRAM.ps1)))"
    Add-Line '```'
    Add-Line ""
    Add-Line "``scriptblock::Create`` is **not** ``iex``: the ``param()`` block still binds (to its"
    Add-Line "defaults), so this runs and still prompts to self-elevate -- you just cannot pass"
    Add-Line "``-NumCtx``/``-TelegramId`` through it. To override parameters or use the docs"
    Add-Line "generator, use the file-based one-liner above (or clone the repo)."
    Add-Line ""
    Add-Line "**Not** ``irm ... | iex``. The script declares ``#Requires`` and a ``param()`` block,"
    Add-Line "and neither survives being piped through ``Invoke-Expression``: parameters cannot"
    Add-Line "bind, and the version check is skipped. Saving to a file first also means"
    Add-Line "``\$PSCommandPath`` is set, so self-elevation and the docs generator both work."
    Add-Line ""
    Add-Line "> **Read this before running.** These download code and execute it"
    Add-Line "> immediately, with no review, no signature, and no checksum. Whoever controls"
    Add-Line "> that URL controls your machine, and the script will ask for Administrator."
    Add-Line "> The convenience is real; so is the risk. The file lands in ``\$env:TEMP`` -- open"
    Add-Line "> it and read it before you let it run."
    Add-Line ""
    Add-Line "The script offers to relaunch itself elevated, forwarding whatever"
    Add-Line "arguments you gave it."
    Add-Line ""

    ## ---------------- parameters ----------------
    Add-Line "## Parameters"
    Add-Line ""
    Add-Line "Override on the command line rather than editing the file:"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line ".\OpenClaw_Ollama_12GB_VRAM.ps1 -NumCtx 32768 -TelegramId 123456789"
    Add-Line ".\OpenClaw_Ollama_12GB_VRAM.ps1 -NoDashboard -NoElevate"
    Add-Line '```'
    Add-Line ""
    Add-Line "| Parameter | Default | Notes |"
    Add-Line "| --- | --- | --- |"
    Add-Line "| ``-TelegramId`` | ``$TelegramId`` | message @userinfobot to find yours |"
    Add-Line "| ``-Model`` | ``$Model`` | |"
    Add-Line "| ``-NumCtx`` | ``$NumCtx`` | drop to 32768 if ``ollama ps`` stops saying 100% GPU |"
    Add-Line "| ``-GatewayPort`` | ``$GatewayPort`` | loopback only |"
    Add-Line "| ``-AvdName`` | ``$AvdName`` | |"
    Add-Line "| ``-SysImage`` | (Android 37.1 ps16k x86_64) | |"
    Add-Line "| ``-NoDashboard`` | off | omit the controlUi block from openclaw.json |"
    Add-Line "| ``-LicenseHolder`` | ``$LicenseHolder`` | written into LICENSE |"
    Add-Line "| ``-NoElevate`` | off | skip the Administrator relaunch prompt |"
    Add-Line "| ``-Unattended`` | off | never block on a human: prompts take their default, no 'press any key', the onboarding TUI is launched detached and killed once it writes config. Set OC_UNATTENDED=1 in the environment to force it |"
    Add-Line "| ``-AutoXapkPath`` | (none) | package the .xapk step installs when unattended, skipping the file picker |"
    Add-Line "| ``-RunAll`` | off | drive every menu step end-to-end, non-interactively, writing ``full_test_report.md``. Implies ``-Unattended`` and ends in the **destructive uninstall** -- VM/throwaway only |"
    Add-Line "| ``-StartAvd`` | off | launch/relaunch the AVD (cold boot) and exit, without the menu |"
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
    Add-Line ".\OpenClaw_Ollama_12GB_VRAM.ps1 -StartAvd"
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
    Add-Line "5. Relaunch: ``.\OpenClaw_Ollama_12GB_VRAM.ps1 -StartAvd``."
    Add-Line ""
    Add-Line "Equivalent to the manual steps, done in one line (what the script runs), for each exe:"
    Add-Line ""
    Add-Line '```powershell'
    Add-Line "New-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' ``"
    Add-Line "  -Name `"`$env:LOCALAPPDATA\Android\Sdk\emulator\emulator.exe`" ``"
    Add-Line "  -Value 'GpuPreference=1;' -PropertyType String -Force   # 1 = iGPU, 2 = dGPU"
    Add-Line '```'
    Add-Line ""
    Add-Line "Both emulator executables pinned to **Power Saving (the integrated GPU)** in"
    Add-Line "Windows Graphics settings:"
    Add-Line ""
    Add-Line "![emulator.exe pinned to the Intel iGPU](images/iGPU-1.png)"
    Add-Line ""
    Add-Line "![qemu-system-x86_64.exe pinned to the Intel iGPU](images/iGPU-2.png)"
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
    Add-Line "# Run as Administrator:"
    Add-Line "powershell -ExecutionPolicy Bypass -File .\OpenClaw_Ollama_12GB_VRAM.ps1"
    Add-Line '```'
    Add-Line ""
    Add-Line "Then work down the menu. Steps 1-7 run in order on a fresh machine, with a"
    Add-Line "**reboot required between step 2 and step 3**. Steps grey out until their"
    Add-Line "preconditions are met, and the reason is printed under the cursor."
    Add-Line ""
    Add-Line "Step 2 (Hyper-V / WHPX) needs hardware virtualization **enabled in your"
    Add-Line "BIOS/UEFI** (Intel VT-x / AMD-V). If step 2 or the emulator reports no"
    Add-Line "acceleration, turn it on in firmware first -- Microsoft's guide walks through it:"
    Add-Line "[Enable virtualization on Windows](https://support.microsoft.com/en-us/windows/experience/enable-virtualization-on-windows)."
    Add-Line ""
    Add-Line "Step 3 opens **Android Studio**; complete the first-run setup wizard, then use"
    Add-Line "its **SDK Manager** to install the platform + system image (the step waits for"
    Add-Line "the SDK to appear, then creates the ``$AvdName`` AVD):"
    Add-Line ""
    Add-Line "![Android Studio SDK Manager -- SDK Platforms](images/sdk-manager-1.png)"
    Add-Line ""
    Add-Line "![Android Studio SDK Manager -- SDK Tools](images/sdk-manager-2.png)"
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
    Add-Line "      adb screenshot --out screenshot.png"
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
    Add-Line "| Both | Use ``command: \"cmd.exe\", args: [\"/c\",\"npx\",\"-y\",\"@mobilenext/mobile-mcp@latest\"]`` |"
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
    Add-Line "resistance), real device-control tools (adb, shell), and web search."
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
    Add-Line "Navigate with the arrow keys; each row is a plain ``-`` bullet. Items grey out"
    Add-Line "when their preconditions are unmet **or** the step is already done, with the"
    Add-Line "reason shown under the cursor (e.g. *Already enabled.* for Hyper-V once it is on)."
    Add-Line "The ``#`` column below is each step's stable menu position."
    Add-Line ""
    Add-Line "![The interactive menu](images/menu.png)"
    Add-Line ""
    Add-Line "| # | Step | Group | Unavailable when |"
    Add-Line "| --- | --- | --- | --- |"
    for ($i = 0; $i -lt $script:Items.Count; $i++) {
        $n = if ($i -lt 9) { "$($i + 1)" } elseif ($i -eq 9) { "0" } else { "-" }
        $raw = if ($script:Items[$i].Why -is [scriptblock]) { & $script:Items[$i].Why } else { $script:Items[$i].Why }
        $why = if ($raw) { ($raw -replace '\|', '\|') } else { "always available" }
        Add-Line "| $n | $($script:Items[$i].Label) | $($script:Items[$i].Group) | $why |"
    }
    Add-Line ""
    Add-Line "*Status check* output (host, GPUs, virtualization, toolchain, model, device,"
    Add-Line "OpenClaw configuration, readiness):"
    Add-Line ""
    Add-Line "![Status check](images/status.png)"
    Add-Line ""

    ## --- test suite, scraped from the source ---
    Add-Line "## Test suite"
    Add-Line ""
    Add-Line "Ordered so each layer only matters if the one below passed. This is what"
    Add-Line "separates *the model refused to call a tool* from *no tools were offered*"
    Add-Line "from *no device was attached* -- three failures that look identical from a"
    Add-Line "Telegram window."
    Add-Line ""
    Add-Line "![The agent tests: model result + adb probe per test](images/tests.png)"
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
    Add-Line "| ``OpenClaw_Ollama_12GB_VRAM.ps1`` | yes | the single, self-contained script |"
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
    $keepPrereqs = (Read-Prompt "Keep node/git/python/jq? (Y/n)" "y") -ne 'n'
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
    Get-Process node          -ErrorAction SilentlyContinue | Where-Object { $_.Path -match "openclaw|clawdbot|mobile-mcp" } | Stop-Process -Force
    Get-Process qemu-system-* -ErrorAction SilentlyContinue | Stop-Process -Force   # the real AVD process
    Get-Process emulator*     -ErrorAction SilentlyContinue | Stop-Process -Force   # only the launcher
    Get-Process studio64      -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process ollama*       -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Get-Command adb -ErrorAction SilentlyContinue) { adb kill-server 2>$null }
    Start-Sleep 2

    Write-Host "`n-- openclaw --" -ForegroundColor Cyan
    Kill-FileLock -Path "$Home\.openclaw\state\openclaw.sqlite"
    cmd /c "openclaw uninstall --all --yes --non-interactive" 2>$null
    cmd /c "npm uninstall -g openclaw" 2>$null
    cmd /c "npm uninstall -g @mobilenext/mobile-mcp" 2>$null
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
        $packages = @('Git.Git','7zip.7zip','OpenJS.NodeJS','Microsoft.OpenJDK.17')
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
    Write-Host "to see whether the model is actually calling adb tools, or just" -ForegroundColor DarkGray
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
##  Presence pings  (Telegram "back online" / "be right back")
##
##  Two notifications, sent STRAIGHT through the Telegram Bot API (not via the
##  gateway) so they work even while the gateway is down. The bot token is read
##  at runtime from ~/.openclaw/.env (never baked into the generated scripts or
##  logs); the chat id is injected from -TelegramId at registration.
##
##    "OpenClaw Presence"        logon task, persistent watcher. TCP-polls the
##                               gateway port every 2s and fires on BOTH edges:
##                               down->up => "back online" (OS boot + gateway
##                               restart return), up->down => "be right back"
##                               (a gateway stop/restart while OS + net are up).
##    "OpenClaw Shutdown Notify" fires on System event 1074 (OS shutdown/restart
##                               initiated) and sends "be right back". BEST-
##                               EFFORT: 1074 fires early in shutdown, but the OS
##                               may cut the network before the POST lands. This
##                               is the OS-shutdown case the watcher can't catch
##                               (it gets killed too fast to poll the edge).
##
##  Greeting name: -OwnerName (defaults to the Windows username) -> "Hey <name>".
## ============================================================
function Register-PresenceNotify {
    param([string]$ChatId, [string]$OwnerName)
    $dir = "$Home\.openclaw"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    ## Build the two messages, then double single quotes so they drop safely into
    ## a single-quoted string in the generated scripts. Injection below uses
    ## String.Replace (literal) -- safe for any name and any message content.
    $who    = if ($OwnerName) { "$OwnerName, " } else { "" }
    $online = ("Hey {0}I'm back online" -f $who)               -replace "'", "''"
    $brb    = ("Hey {0}I'll be right back shortly .." -f $who) -replace "'", "''"

    ## Watcher: polls the gateway port every 2s and fires on BOTH edges --
    ## down->up => "back online" (boot / restart return), up->down => "be right
    ## back" (a gateway stop/restart while the OS + network are still up). Single-
    ## quoted here-string == literal; placeholders injected after; token at runtime.
    $watcher = @'
$ErrorActionPreference = 'Continue'
$chatId  = '__CHATID__'
$online  = '__ONLINE__'
$brb     = '__BRB__'
$envFile = Join-Path $HOME '.openclaw\.env'
$port = 18789
try { $pp = (openclaw config get gateway.port) 2>$null; if ("$pp" -match '\d+') { $port = [int]$Matches[0] } } catch {}
## Track the LISTENER's process id, not just up/down. A fast `gateway restart`
## can close+reopen the port between 2s polls (we never observe "down"), but the
## node pid changes -- so we still fire "back online". down->up / up->down cover
## the boot and stop cases. Send-Ping retries (boot network may not be ready).
function Get-GwPid { try { (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess } catch { $null } }
function Send-Ping($text) {
    if (-not (Test-Path $envFile)) { return }
    $tok = ((Get-Content $envFile | Where-Object { $_ -match '^TELEGRAM_BOT_TOKEN=' } | Select-Object -First 1) -replace '^TELEGRAM_BOT_TOKEN=','').Trim()
    if (-not $tok) { return }
    $uri = "https://api.telegram.org/bot$tok/sendMessage"
    for ($i = 0; $i -lt 6; $i++) {
        try { Invoke-RestMethod -Method Post -Uri $uri -Body @{ chat_id = $chatId; text = $text } | Out-Null; return }
        catch { Start-Sleep -Seconds 5 }
    }
}
$lastPid = $null
$lastUp  = $false
while ($true) {
    $curPid = Get-GwPid
    $up = [bool]$curPid
    if     ($up -and -not $lastUp)                      { Start-Sleep -Seconds 2; Send-Ping $online }
    elseif ((-not $up) -and $lastUp)                    { Send-Ping $brb }
    elseif ($up -and $lastUp -and $curPid -ne $lastPid) { Send-Ping $online }
    $lastUp = $up; $lastPid = $curPid
    Start-Sleep -Seconds 2
}
'@
    $watcher = $watcher.Replace('__CHATID__', $ChatId).Replace('__ONLINE__', $online).Replace('__BRB__', $brb)
    $watcherPs = Join-Path $dir 'presence-watch.ps1'
    [IO.File]::WriteAllText($watcherPs, $watcher, (New-Object Text.UTF8Encoding($false)))

    ## Shutdown: event 1074 => "be right back" (one shot, best-effort).
    $shut = @'
$ErrorActionPreference = 'Continue'
$chatId  = '__CHATID__'
$msg     = '__BRB__'
$envFile = Join-Path $HOME '.openclaw\.env'
if (Test-Path $envFile) {
    $tok = ((Get-Content $envFile | Where-Object { $_ -match '^TELEGRAM_BOT_TOKEN=' } | Select-Object -First 1) -replace '^TELEGRAM_BOT_TOKEN=','').Trim()
    if ($tok) { try { Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$tok/sendMessage" -Body @{ chat_id = $chatId; text = $msg } | Out-Null } catch {} }
}
'@
    $shut = $shut.Replace('__CHATID__', $ChatId).Replace('__BRB__', $brb)
    $shutPs = Join-Path $dir 'presence-shutdown.ps1'
    [IO.File]::WriteAllText($shutPs, $shut, (New-Object Text.UTF8Encoding($false)))

    ## Hidden launcher for the persistent watcher (no console flash at logon).
    $vbs = Join-Path $dir 'presence-watch.vbs'
    $vbsBody = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $watcherPs + '""", 0, False'
    [IO.File]::WriteAllText($vbs, $vbsBody, (New-Object Text.UTF8Encoding($false)))

    $princ = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

    ## Watcher task -- at logon.
    $wAction  = New-ScheduledTaskAction    -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbs)
    $wTrigger = New-ScheduledTaskTrigger    -AtLogOn -User $env:USERNAME
    $wSet     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'OpenClaw Presence' -Action $wAction -Trigger $wTrigger -Principal $princ -Settings $wSet -Force | Out-Null

    ## Shutdown task -- on System event 1074. New-ScheduledTaskTrigger has no
    ## -AtEvent, so build an MSFT_TaskEventTrigger via CIM with an XPath query.
    $sAction  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $shutPs)
    $evtClass = Get-CimClass -Namespace root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskEventTrigger
    $sTrigger = New-CimInstance -CimClass $evtClass -ClientOnly
    $sTrigger.Enabled      = $true
    $sTrigger.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''User32''] and (EventID=1074)]]</Select></Query></QueryList>'
    $sSet = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'OpenClaw Shutdown Notify' -Action $sAction -Trigger $sTrigger -Principal $princ -Settings $sSet -Force | Out-Null
}

function Unregister-PresenceNotify {
    foreach ($t in 'OpenClaw Presence', 'OpenClaw Shutdown Notify') {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
        }
    }
    Remove-Item "$Home\.openclaw\presence-watch.ps1", "$Home\.openclaw\presence-watch.vbs", `
                "$Home\.openclaw\presence-shutdown.ps1" -ErrorAction SilentlyContinue
}

## ============================================================
##  Auto-start on boot  (toggle)
##
##  Two OS-level Scheduled Tasks bring the local stack up when Windows starts:
##
##    "OpenClaw Gateway"  Created by OpenClaw's own onboarding (step 7). A
##                        logon-triggered task that runs ~/.openclaw/gateway.vbs
##                        hidden. The gateway spawns mobile-mcp as a *child* MCP
##                        server, so enabling the gateway task covers the MCP
##                        too -- there is nothing separate to toggle for it.
##
##    "Ollama Serve"      Created HERE. A logon-triggered task that runs
##                        'ollama serve' hidden, via a tiny .vbs launcher -- the
##                        same WScript window-hiding trick OpenClaw uses for its
##                        gateway, so the daemon does not flash a console at
##                        logon. Ollama's winget install does not always leave a
##                        Run-key, so we own this one explicitly.
##
##  Both fire at LOGON, not at boot-before-login: the gateway is an interactive
##  task that needs a user session. A *remote* reboot therefore brings the stack
##  up only after someone signs in; for a fully-headless boot you would also
##  need Windows auto-login, which stores a credential at rest and is
##  deliberately NOT configured here.
##
##  This step is a single toggle: it reports current state, then enables or
##  disables BOTH tasks together. Enabling requires the pieces to exist (run
##  step 7 for the gateway task, step 5 for ollama) -- it never creates the
##  gateway task itself; that is OpenClaw's job.
## ============================================================
$StepAutoStart = {
    $gwTask = "OpenClaw Gateway"
    $olTask = "Ollama Serve"

    ## Scheduled-task cmdlets are CIM-based and do not emit native stderr, so the
    ## global Stop preference is safe here; -EA SilentlyContinue covers "absent".
    function Get-AutoStartState($name) {
        $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if (-not $t)                    { return "absent" }
        if ($t.State -eq 'Disabled')    { return "disabled" }
        return "enabled"
    }

    $gwState = Get-AutoStartState $gwTask
    $olState = Get-AutoStartState $olTask
    $color   = { param($s) if ($s -eq 'enabled') { 'Green' } elseif ($s -eq 'absent') { 'DarkGray' } else { 'Yellow' } }

    Write-Host "Current auto-start-on-boot state:" -ForegroundColor Cyan
    Write-Host ("  OpenClaw gateway (+ mobile-mcp)  : {0}" -f $gwState) -ForegroundColor (& $color $gwState)
    Write-Host ("  Ollama serve                   : {0}" -f $olState) -ForegroundColor (& $color $olState)
    Write-Host ""

    $anyOn   = ($gwState -eq 'enabled') -or ($olState -eq 'enabled')
    $default = if ($anyOn) { 'disable' } else { 'enable' }
    $ans     = Read-Prompt "Enable or disable auto-start on boot? (enable/disable)" $default
    ## Anything not starting with 'd' means enable -- keeps the default sensible.
    $enable  = ($ans -notmatch '^\s*[dD]')

    if ($enable) {
        ## ---- OpenClaw gateway (+ mobile-mcp child) ----
        if ($gwState -eq 'absent') {
            Write-Host "  [gateway] task not found -- run step [7] (OpenClaw onboarding) to create it." -ForegroundColor Yellow
        } else {
            Enable-ScheduledTask -TaskName $gwTask | Out-Null
            Write-Host "  [gateway] auto-start ENABLED (logon trigger; mobile-mcp follows as its child)." -ForegroundColor Green
        }

        ## ---- Ollama serve ----
        $ollamaExe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
        if (-not $ollamaExe) {
            Write-Host "  [ollama] ollama not on PATH -- run step [5] first." -ForegroundColor Yellow
        } else {
            ## Hidden launcher (WScript Run style 0 = hidden), mirroring OpenClaw's
            ## gateway.vbs, so 'ollama serve' never flashes a console at logon.
            $dir = "$Home\.openclaw"
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $vbs     = Join-Path $dir 'ollama-serve.vbs'
            $vbsBody = 'CreateObject("WScript.Shell").Run """' + $ollamaExe + '"" serve", 0, False'
            [IO.File]::WriteAllText($vbs, $vbsBody, (New-Object Text.UTF8Encoding($false)))

            $action  = New-ScheduledTaskAction   -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbs)
            $trigger = New-ScheduledTaskTrigger   -AtLogOn -User $env:USERNAME
            $princ   = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
            $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
            Register-ScheduledTask -TaskName $olTask -Action $action -Trigger $trigger -Principal $princ -Settings $set -Force | Out-Null
            Write-Host "  [ollama] auto-start ENABLED (logon trigger, hidden via $vbs)." -ForegroundColor Green
        }

        ## ---- presence pings: "back online" (boot/restart) + "be right back" ----
        $who = if ($OwnerName) { $OwnerName } else { $env:USERNAME }
        Register-PresenceNotify -ChatId $TelegramId -OwnerName $who
        Write-Host "  [presence] 'Hey $who, I'm back online' ping ENABLED (on boot + gateway up/down)." -ForegroundColor Green
        Write-Host "  [presence] 'Hey $who, I'll be right back shortly ..' ping ENABLED (gateway down + OS shutdown; best-effort)." -ForegroundColor Green

        Write-Host ""
        Write-Host "Tasks fire at LOGON (gateway/ollama) and on shutdown (the be-right-back" -ForegroundColor DarkGray
        Write-Host "ping). A headless remote reboot brings the stack up only after a user" -ForegroundColor DarkGray
        Write-Host "signs in; for fully-unattended boot you would also need Windows auto-login" -ForegroundColor DarkGray
        Write-Host "(a credential-at-rest trade-off, not set by this script)." -ForegroundColor DarkGray
    }
    else {
        ## Gateway: keep the task (OpenClaw owns it) but disable the trigger.
        if ($gwState -ne 'absent') {
            Disable-ScheduledTask -TaskName $gwTask | Out-Null
            Write-Host "  [gateway] auto-start DISABLED (task kept, trigger off)." -ForegroundColor Yellow
        } else {
            Write-Host "  [gateway] no task present." -ForegroundColor DarkGray
        }
        ## Ollama: this task is ours, so remove it outright.
        if ($olState -ne 'absent') {
            Unregister-ScheduledTask -TaskName $olTask -Confirm:$false
            Write-Host "  [ollama] auto-start task REMOVED." -ForegroundColor Yellow
        } else {
            Write-Host "  [ollama] no auto-start task to remove." -ForegroundColor DarkGray
        }
        ## Presence pings: remove both tasks + the generated scripts.
        Unregister-PresenceNotify
        Write-Host "  [presence] 'back online' + 'be right back' pings REMOVED." -ForegroundColor Yellow
    }
}

## ============================================================
##  Install optional add-ons  (skills / MCPs / plugins sub-menu)
##
##  A small in-step catalog of extras the agent can use. Each entry is fully
##  self-describing (Name, Kind, Desc, Install scriptblock), so growing the list
##  is a one-liner. The step prints the catalog, asks which to install, and runs
##  the selected Install blocks. Unattended (-RunAll) selects "all" via the
##  Read-Prompt default, so nothing blocks.
##
##  Current catalog:
##    mobile-mcp       MCP server -- mobile automation (Android + iOS)
##                     (returns PNGs as proper MCP image content blocks).
##    context7         Skill @thesethrose/context7 -- on-demand, version-accurate
##                     library/API docs for the agent.
##    base64-toolkit   Skill @freeter226/base64-toolkit -- encode/decode base64,
##                     so the model can actually handle inline base64 (e.g. a
##                     screenshot tool result) instead of choking on the string.
##
##  ClawHub skill installs shell out and print to stderr, so each helper runs
##  under Continue and gates on $LASTEXITCODE (a re-run of an already-installed
##  skill exits non-zero -- reported, not fatal).
## ============================================================
function Install-ClawSkill {
    param([string]$Ref)
    $ErrorActionPreference = 'Continue'
    Write-Host "  openclaw skills install $Ref" -ForegroundColor DarkGray
    openclaw skills install $Ref
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) {
        Write-Host "  (exited $code -- may already be installed; 'openclaw skills list' to check)" -ForegroundColor DarkGray
    }
}

$StepSkills = {
    if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
        throw "openclaw not installed. Run step [7] first."
    }

    $catalog = @(
        [PSCustomObject]@{
            Name = "mobile-mcp"; Kind = "MCP server"
            Desc = "Mobile automation and screen control (Android + iOS) via @mobilenext/mobile-mcp."
            Install = {
                ## Register via the official CLI. It probes the server before saving.
                ## cmd.exe wrapper: Node's spawn() throws on bare 'npx'/'npx.cmd'.
                openclaw mcp add mobile --command cmd.exe --arg /c --arg npx --arg -y --arg @mobilenext/mobile-mcp@latest
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  (exited $LASTEXITCODE -- may already be registered; 'openclaw mcp list' to check)" -ForegroundColor DarkGray
                }
            }
        }
        [PSCustomObject]@{
            Name = "context7"; Kind = "skill (@thesethrose/context7)"
            Desc = "On-demand, version-accurate library/API docs for the agent."
            Install = { Install-ClawSkill '@thesethrose/context7' }
        }
        [PSCustomObject]@{
            Name = "base64-toolkit"; Kind = "skill (@freeter226/base64-toolkit)"
            Desc = "Encode/decode base64 -- lets the model handle inline base64 (e.g. screenshot data) instead of choking on the raw string."
            Install = {
                Install-ClawSkill '@freeter226/base64-toolkit'
                ## This skill requires a 'python3' binary; Windows ships only
                ## 'python'. Provision it (same helper prereqs uses) so the skill
                ## becomes eligible. Restart the gateway to clear its cached
                ## eligibility if it was already running (see notes below).
                if (Ensure-Python3) {
                    Write-Host "  python3 ready -- restart the gateway so it re-checks: openclaw gateway restart" -ForegroundColor DarkGray
                } else {
                    Write-Host "  base64-toolkit still needs python3; install Python 3, then re-run." -ForegroundColor Yellow
                }
            }
        }
    )

    Write-Host "Optional add-ons (skills / MCPs / plugins):" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $catalog.Count; $i++) {
        $c = $catalog[$i]
        Write-Host ("  [{0}] {1,-15}{2}" -f ($i + 1), $c.Name, $c.Kind) -ForegroundColor Green
        Write-Host ("      {0}" -f $c.Desc) -ForegroundColor DarkGray
    }
    Write-Host ""

    ## Selection: numbers ("1 3"), "all", or "none". Default (and unattended) = all.
    $ans = Read-Prompt "Install which? (e.g. '1 3', 'all', 'none')" "all"
    $pick =
        if     ($ans -match '^\s*none\s*$')                                    { @() }
        elseif ($ans -match '^\s*all\s*$' -or [string]::IsNullOrWhiteSpace($ans)) { 1..$catalog.Count }
        else   { @($ans -split '[\s,]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) }

    if ($pick.Count -eq 0) { Write-Host "Nothing selected." -ForegroundColor Yellow; return }

    foreach ($n in ($pick | Sort-Object -Unique)) {
        if ($n -lt 1 -or $n -gt $catalog.Count) { continue }
        $c = $catalog[$n - 1]
        Write-Host ""
        Write-Host ("Installing [{0}] {1} ({2})..." -f $n, $c.Name, $c.Kind) -ForegroundColor Cyan
        try   { & $c.Install; Write-Host ("  {0}: done." -f $c.Name) -ForegroundColor Green }
        catch { Write-Host ("  {0}: {1}" -f $c.Name, $_.Exception.Message) -ForegroundColor Yellow }
    }

    Write-Host ""
    Write-Host "Verify skills:  openclaw skills list" -ForegroundColor DarkGray
    Write-Host "Verify MCPs:    mcp.servers in openclaw.json (openclaw config get mcp)" -ForegroundColor DarkGray
}

## ============================================================
##  The menu, in run order.
##
##  ONE canonical list. A number always means the same step: [4] is
##  "Install the AVD".
##
##  Each item:
##    Key      stable identifier
##    Enabled  predicate over $script:Env; false greys the row out
##    Why      string or scriptblock explaining a greyed row
## ============================================================
## ============================================================
##  Android steps: Hyper-V/WHPX, Android Studio + Pixel_5 AVD,
##  .xapk install, and AVD launch. (Merged in from the old Full edition.)
## ============================================================
## ============================================================
##  Hyper-V
## ============================================================
$StepHyperV = {
    ## Enabling the leaf features directly keeps the management tools
    ## Disabled. Checking "Hyper-V" in the GUI feature tree does not.
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Hypervisor -NoRestart
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Services   -NoRestart
    Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform           -NoRestart

    Write-Host ""
    Write-Host "REBOOT REQUIRED before the emulator can use WHPX." -ForegroundColor Yellow
    Write-Host "Also enable virtualization (VT-x / AMD-V) in BIOS if you have not." -ForegroundColor Yellow
}

## ============================================================
##  Verify Hyper-V / WHPX
## ============================================================
$StepVerifyHyperV = {
    Get-WindowsOptionalFeature -Online |
        Where-Object FeatureName -like '*Hyper*' |
        Select-Object FeatureName, State | Format-Table -AutoSize | Out-Host

    Write-Host "Expect Enabled : HypervisorPlatform, Microsoft-Hyper-V-All," -ForegroundColor DarkGray
    Write-Host "                 Microsoft-Hyper-V, -Hypervisor, -Services"  -ForegroundColor DarkGray
    Write-Host "Expect Disabled: -Tools-All, -Management-PowerShell, -Management-Clients" -ForegroundColor DarkGray
    Write-Host ""

    if (Get-Command emulator -ErrorAction SilentlyContinue) {
        $accel = emulator -accel-check 2>&1 | Out-String
        Write-Host $accel
        if ($accel -notmatch 'WHPX') { throw "No WHPX acceleration. Check the reboot and BIOS." }
        Write-Host "WHPX acceleration confirmed." -ForegroundColor Green
    } else {
        Write-Host "emulator not on PATH yet -- run step [4], then re-check." -ForegroundColor Yellow
    }
}

## ============================================================
##  Pin the emulator's renderer to the INTEGRATED GPU
##
##  Windows routes each app to a GPU via a per-exe preference in
##  HKCU\...\DirectX\UserGpuPreferences: "GpuPreference=1" = power saving =
##  the integrated GPU, "=2" = high performance = the discrete card. Pinning
##  emulator.exe AND its real renderer qemu-system-x86_64.exe to the iGPU is
##  what lets the AVD render hardware-accelerated on the Intel/AMD iGPU while
##  the discrete GPU's VRAM stays 100% for the model -- the whole point on a
##  12 GB card. On a machine with no iGPU, "power saving" maps to the only GPU:
##  harmless. This is the OS-level half of "use hardware GL"; '-gpu host' +
##  hw.gpu.mode=host is the emulator half.
## ============================================================
function Set-EmulatorGpuPreference {
    $emuDir = "$env:LOCALAPPDATA\Android\Sdk\emulator"
    $exes = @("$emuDir\emulator.exe",
              "$emuDir\qemu\windows-x86_64\qemu-system-x86_64.exe")
    $key = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    foreach ($exe in $exes) {
        if (Test-Path $exe) {
            New-ItemProperty -Path $key -Name $exe -Value 'GpuPreference=1;' -PropertyType String -Force | Out-Null
            Write-Host ">>> Pinned to integrated GPU: $(Split-Path $exe -Leaf)" -ForegroundColor DarkGray
        }
    }
}

## ============================================================
##  Android Studio, SDK, Pixel_5 AVD
##
##  Android 37 system images exist only as 16KB page-size variants:
##  google_apis_ps16k, not plain google_apis.
##  avdmanager creates the AVD AND its .ini pointer; do not hand-write them.
##  "emulator" only launches AVDs; "avdmanager" creates them.
## ============================================================
$StepAndroid = {
    ## adb prints to stderr constantly ("daemon not running; starting now",
    ## "no devices/emulators found" during the boot poll), which is fatal under
    ## the global Stop preference and once failed this step mid-boot even though
    ## the AVD came up fine. sdkmanager/avdmanager failures are still caught by
    ## their explicit $LASTEXITCODE checks, and the boot poll has its own
    ## deadline + throw, so Continue is safe here.
    $ErrorActionPreference = 'Continue'

    $studioExe = "C:\Program Files\Android\Android Studio\bin\studio64.exe"
    $sdkPath   = "$env:LOCALAPPDATA\Android\Sdk"
    $sdkManagerBat = "$sdkPath\cmdline-tools\latest\bin\sdkmanager.bat"

    if (Test-Path $studioExe) {
        Write-Host ">>> Android Studio already installed." -ForegroundColor Green
    } else {
        winget install Google.AndroidStudio --accept-package-agreements --accept-source-agreements --wait
    }

    ## The SDK + command-line tools come from the Studio setup wizard -- a GUI
    ## with no headless entry point, and the ONE thing that needs a human. On a
    ## re-run the tools are already installed, so skip the wizard entirely.
    if (Test-Path $sdkManagerBat) {
        Write-Host ">>> SDK command-line tools already present; skipping the setup wizard." -ForegroundColor Green
    } else {
        if (Test-Path $studioExe) {
            Write-Host ">>> Launching Android Studio to complete SDK setup..." -ForegroundColor Cyan
            Start-Process -FilePath $studioExe -Verb RunAs
        }
        Write-Host ""
        Write-Host "==========================================================" -ForegroundColor Yellow
        Write-Host "ACTION REQUIRED: finish the Android Studio Setup Wizard." -ForegroundColor Yellow
        Write-Host "Then SDK Manager > SDK Tools, enable:" -ForegroundColor Yellow
        Write-Host "    Android SDK Command-line Tools (latest)" -ForegroundColor Yellow
        Write-Host "    Google USB Driver" -ForegroundColor Yellow
        Write-Host "==========================================================" -ForegroundColor Yellow
        if ($Unattended) {
            ## Unattended still can't click the GUI, but a human can while the run
            ## waits. Read-Host would need an interactive console (a background /
            ## -RunAll run has none), so POLL for the SDK to appear instead. This
            ## keeps the run going hands-off everywhere else while pausing here for
            ## you to finish the wizard. Generous deadline; throws if it never lands.
            Write-Host ">>> [auto] Waiting up to 45 min for the SDK command-line tools to appear" -ForegroundColor DarkGray
            Write-Host ">>>        (finish the wizard + SDK Tools > Command-line Tools)..." -ForegroundColor DarkGray
            $deadline = (Get-Date).AddMinutes(45)
            while ((Get-Date) -lt $deadline -and -not (Test-Path $sdkManagerBat)) { Start-Sleep -Seconds 10 }
            if (-not (Test-Path $sdkManagerBat)) {
                throw "SDK command-line tools never appeared at $sdkManagerBat. Finish the Studio wizard (SDK Tools > Command-line Tools), then re-run."
            }
            Write-Host ">>> SDK command-line tools detected; continuing." -ForegroundColor Green
        } else {
            Read-Host "Press Enter once SDK setup is complete"
        }
    }

    if (-not (Test-Path $sdkPath)) { throw "Android SDK not found at $sdkPath. Finish the wizard, then re-run." }

    $platformTools = "$sdkPath\platform-tools"
    $cmdlineTools  = "$sdkPath\cmdline-tools\latest\bin"
    $emulatorPath  = "$sdkPath\emulator"

    [Environment]::SetEnvironmentVariable("ANDROID_HOME", $sdkPath, "User")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    foreach ($dir in ($platformTools, $cmdlineTools, $emulatorPath)) {
        if ($userPath -notlike "*$dir*") { $userPath = "$userPath;$dir" }
    }
    [Environment]::SetEnvironmentVariable("Path", $userPath, "User")

    ## Update this process too, so adb/emulator resolve immediately
    $env:ANDROID_HOME = $sdkPath
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + $userPath

    ## Resolve by explicit path: a freshly-set PATH may not reach child processes
    $sdkManager = "$cmdlineTools\sdkmanager.bat"
    $avdManager = "$cmdlineTools\avdmanager.bat"
    if (-not (Test-Path $sdkManager)) {
        throw "sdkmanager missing. SDK Manager > SDK Tools > Android SDK Command-line Tools (latest)."
    }

    $acceptLicenses = (1..20 | ForEach-Object { "y" })

    Write-Host ">>> Updating SDK tooling..." -ForegroundColor Cyan
    & $sdkManager --update

    Write-Host ">>> Downloading system image and tools..." -ForegroundColor Cyan
    $acceptLicenses | & $sdkManager "emulator" "platform-tools" "platforms;android-37.1" $SysImage
    if ($LASTEXITCODE -ne 0) { throw "SDK component download failed." }

    Write-Host ">>> Creating the $AvdName AVD..." -ForegroundColor Cyan
    ## -d is the device profile. Do NOT use -b: that flag is --abi.
    "no" | & $avdManager create avd -n $AvdName -d "pixel_5" -k $SysImage --force
    if ($LASTEXITCODE -ne 0) { throw "avdmanager failed to create the AVD." }

    ## Opt out of emulator metrics persistently. -no-metrics covers the running
    ## instance; this skips the one-time prompt. Best effort: ignored if the key
    ## names change, and it will not break the launch.
    $androidCfgDir = "$env:USERPROFILE\.android"
    New-Item -ItemType Directory -Path $androidCfgDir -Force | Out-Null
    Set-Content -Path "$androidCfgDir\analytics.settings" `
        -Value '{"userId":"","hasOptedIn":false,"debugDisablePings":true}' -Encoding ascii

    Write-Host ">>> Writing config.ini..." -ForegroundColor Cyan
    $configPath = "$env:USERPROFILE\.android\avd\$AvdName.avd\config.ini"
    $configContent = @(
        "AvdId=$AvdName",
        'PlayStore.enabled=false',
        'abi.type=x86_64',
        'avd.ini.displayname=Pixel 5',
        'avd.ini.encoding=UTF-8',
        'disk.dataPartition.size=16G',
        # Snapshots fully disabled. "Quick boot" IS snapshot loading, so it cannot
        # coexist with this. Cold boot every time; that also removes the
        # "Bug report interrupted by snapshot load" popup at its source.
        'fastboot.chosenSnapshotFile=',
        'fastboot.forceChosenSnapshotBoot=no',
        'fastboot.forceColdBoot=yes',
        'fastboot.forceFastBoot=no',
        'hw.accelerometer=yes',
        'hw.arc=false',
        'hw.audioInput=yes',
        'hw.battery=yes',
        'hw.camera.back=virtualscene',
        'hw.camera.front=emulated',
        'hw.cpu.arch=x86_64',
        # 4 cores: software GL is CPU-bound.
        'hw.cpu.ncore=4',
        'hw.dPad=no',
        'hw.device.hash2=MD5:12ab7fcb681cafc1697d019f385bf3b9',
        'hw.device.manufacturer=Google',
        'hw.device.name=pixel_5',
        'hw.gps=yes',
        # Hardware rendering (Device Manager "Graphics" = Hardware - GLES).
        # Software 'swiftshader_indirect' rendered a BLANK/white framebuffer on
        # the build host (RTX 4070 Ti + i7-13700K) -- the OS booted but nothing
        # painted, breaking the vision loop. Hardware GL renders reliably, and
        # Set-EmulatorGpuPreference below pins it to the INTEGRATED GPU so the
        # discrete card's VRAM stays entirely for the model. The in-emulator
        # Settings > Advanced control is a RUNTIME override that resets to auto
        # on reboot; config.ini plus the -gpu launch flag persist.
        'hw.gpu.enabled=yes',
        'hw.gpu.mode=host',
        'hw.gyroscope=yes',
        'hw.initialOrientation=portrait',
        'hw.keyboard=yes',
        'hw.keyboard.charmap=qwerty2',
        'hw.keyboard.lid=yes',
        'hw.lcd.density=440',
        'hw.lcd.height=2340',
        'hw.lcd.width=1080',
        'hw.mainKeys=no',
        'hw.ramSize=3072',
        'hw.sdCard=yes',
        'hw.sensors.light=yes',
        'hw.sensors.magnetic_field=yes',
        'hw.sensors.orientation=yes',
        'hw.sensors.pressure=yes',
        'hw.sensors.proximity=yes',
        'hw.trackBall=no',
        'image.sysdir.1=system-images\android-37.1\google_apis_ps16k\x86_64\',
        'runtime.network.latency=none',
        'runtime.network.speed=full',
        'sdcard.size=512M',
        # No skin: no need for the bezel art
        'showDeviceFrame=no',
        'tag.display=Google APIs',
        'tag.id=google_apis_ps16k',
        'target=android-37.1',
        'vm.heapSize=256'
    )
    Set-Content -Path $configPath -Value $configContent

    ## Start-Process, not "& emulator.exe": a console-attached launch ties the
    ## emulator's lifetime to this window.
    Set-EmulatorGpuPreference   # render on the iGPU, keep the dGPU for the model
    Write-Host ">>> Launching $AvdName (detached)..." -ForegroundColor Green
    Start-Process -FilePath "$emulatorPath\emulator.exe" `
        -ArgumentList '-avd',$AvdName,'-gpu','host',
                      '-no-snapshot','-no-snapshot-save','-no-snapshot-load',
                      '-no-boot-anim','-no-metrics' `
        -WindowStyle Hidden

    ## Do NOT use 'adb wait-for-device': it blocks forever with no timeout if
    ## the emulator failed to start. Poll instead -- adb shell against no device
    ## errors, 2>$null eats it, and the loop times out cleanly.
    adb start-server
    Write-Host ">>> Waiting for Android to finish booting..." -ForegroundColor Cyan
    $booted = ""
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $booted = (adb shell getprop sys.boot_completed 2>$null | Out-String).Trim()
        if ($booted -eq "1") { break }
        Start-Sleep -Seconds 5
    }
    if ($booted -ne "1") { throw "AVD never finished booting. Check the emulator window." }
    Write-Host ">>> AVD booted." -ForegroundColor Green
    adb devices
}


## ============================================================
##  Install an .xapk / .apks onto the AVD
##
##  An .xapk is a ZIP holding a base APK plus split config APKs
##  (per-ABI / per-density / per-language). Plain 'adb install' cannot
##  handle splits, so extract everything and use 'adb install-multiple'.
##  Games often ship an .obb alongside; that has to be pushed separately
##  or the app installs and then crashes looking for its assets.
## ============================================================
$StepXapk = {
    ## adb (install / install-multiple / push / devices) writes to stderr, fatal
    ## under the global Stop preference; real failures are caught by the explicit
    ## $LASTEXITCODE checks below, so Continue.
    $ErrorActionPreference = 'Continue'

    ## Unattended takes the package from -AutoXapkPath (relative paths resolve
    ## against the script dir), skipping the GUI picker entirely.
    $XapkPath = $null
    if ($Unattended) {
        if ([string]::IsNullOrWhiteSpace($AutoXapkPath)) {
            throw "Unattended .xapk install needs -AutoXapkPath (e.g. -AutoXapkPath .\Tinder.xapk)."
        }
        $XapkPath = if ([IO.Path]::IsPathRooted($AutoXapkPath)) { $AutoXapkPath } else { Join-Path $BaseDir $AutoXapkPath }
        Write-Host ">>> [auto] Package: $XapkPath" -ForegroundColor DarkGray
    }
    ## A GUI picker beats typing a Windows path. Falls back to Read-Host if
    ## WinForms is unavailable (Server Core, PS in a non-STA host, etc).
    elseif ($true) {
      try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title  = "Pick an .xapk / .apks / .apk"
        $dlg.Filter = "Android packages (*.xapk;*.apks;*.apk)|*.xapk;*.apks;*.apk|All files (*.*)|*.*"
        $dlg.InitialDirectory = [Environment]::GetFolderPath('UserProfile') + "\Downloads"
        $dlg.Multiselect = $false

        Write-Host "Opening file picker..." -ForegroundColor DarkGray
        ## Force the dialog in front of the console window
        $dlg.ShowHelp = $false
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $XapkPath = $dlg.FileName
        } else {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }
      } catch {
        Write-Host "File picker unavailable; type or drag-and-drop the path." -ForegroundColor DarkGray
        $XapkPath = Read-Host "Full path to the .xapk / .apks / .apk"
      }
    }

    ## Drag-and-drop into a console wraps the path in quotes
    $XapkPath = $XapkPath.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($XapkPath)) { throw "No file selected." }
    if (-not (Test-Path $XapkPath)) { throw "File not found: $XapkPath" }
    Write-Host ">>> Package: $(Split-Path $XapkPath -Leaf)" -ForegroundColor Cyan

    $adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    if (-not (Test-Path $adb)) { $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source }
    if (-not $adb) { throw "adb not found. Run step [4] or add adb to PATH." }

    ## @(...) forces an array, so a single device stays a string rather than
    ## becoming an indexable char sequence.
    $devices = @(& $adb devices | Select-Object -Skip 1 |
        Where-Object { $_ -match '\sdevice$' } |
        ForEach-Object { ($_ -split '\s+')[0] })
    if (-not $devices) { throw "No running device. Start the AVD first (step [4])." }
    if ($devices.Count -gt 1) {
        Write-Host "Attached: $($devices -join ', ')" -ForegroundColor Yellow
        $serial = Read-Host "Which serial"
    } else {
        $serial = $devices[0]
    }
    Write-Host ">>> Target: $serial" -ForegroundColor Cyan

    ## Plain .apk needs no unpacking
    if ([IO.Path]::GetExtension($XapkPath) -eq ".apk") {
        & $adb -s $serial install -r $XapkPath
        if ($LASTEXITCODE -ne 0) { throw "Install failed (exit $LASTEXITCODE)." }
        Write-Host ">>> Success." -ForegroundColor Green
        return
    }

    $work = Join-Path $env:TEMP ("xapk_" + [IO.Path]::GetFileNameWithoutExtension($XapkPath))
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    try {
        Write-Host ">>> Extracting..." -ForegroundColor Cyan
        ## Expand-Archive only accepts a .zip extension
        $zipCopy = Join-Path $work "package.zip"
        Copy-Item $XapkPath $zipCopy -Force
        Expand-Archive -Path $zipCopy -DestinationPath $work -Force
        Remove-Item $zipCopy -Force -ErrorAction SilentlyContinue

        $apks = @(Get-ChildItem $work -Recurse -Filter *.apk | Select-Object -ExpandProperty FullName)
        if (-not $apks) { throw "No .apk inside. Is this a valid package?" }
        Write-Host ">>> Found $($apks.Count) APK(s):" -ForegroundColor Cyan
        $apks | ForEach-Object { Write-Host "    $(Split-Path $_ -Leaf)" -ForegroundColor DarkGray }

        Write-Host ">>> Installing..." -ForegroundColor Cyan
        if ($apks.Count -eq 1) {
            & $adb -s $serial install -r $apks[0]
        } else {
            & $adb -s $serial install-multiple -r @apks
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host ">>> Install failed (exit $LASTEXITCODE)." -ForegroundColor Red
            Write-Host ">>> Common cause: ABI mismatch. This AVD is x86_64; an arm64-v8a-only" -ForegroundColor Yellow
            Write-Host "    split will not install." -ForegroundColor Yellow
            return
        }
        Write-Host ">>> APKs installed." -ForegroundColor Green

        ## OBB assets. The original script skipped these, so games would install
        ## and then crash on first launch looking for missing data.
        $obbs = @(Get-ChildItem $work -Recurse -Filter *.obb -ErrorAction SilentlyContinue)
        if ($obbs) {
            foreach ($obb in $obbs) {
                ## OBB filenames look like main.<version>.<package.name>.obb
                $parts = $obb.Name -split '\.'
                if ($parts.Count -lt 4) {
                    Write-Host ">>> Cannot parse package name from $($obb.Name); skipping." -ForegroundColor Yellow
                    continue
                }
                $pkg = ($parts[2..($parts.Count - 2)]) -join '.'
                $dest = "/sdcard/Android/obb/$pkg"
                Write-Host ">>> Pushing $($obb.Name) -> $dest" -ForegroundColor Cyan
                & $adb -s $serial shell mkdir -p $dest
                & $adb -s $serial push $obb.FullName "$dest/$($obb.Name)"
            }
        }
        Write-Host ">>> Success." -ForegroundColor Green
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

## ============================================================
##  Launch / relaunch the AVD (cold boot)
##
##  Kills any running instance -- qemu-system-x86_64 holds the AVD's file
##  locks, NOT the emulator.exe launcher, so both are stopped -- then re-pins to
##  the integrated GPU and cold-boots fresh. This is the fix when the emulator
##  hangs on a white boot screen. Plain cold boot, no data wipe; if a boot is
##  truly stuck, add '-wipe-data' to the args below. Launch (iGPU pin + -gpu
##  host + flags) mirrors StepAndroid's.
## ============================================================
$StepLaunchAvd = {
    $ErrorActionPreference = 'Continue'   # adb/emulator stderr is benign; gate on results
    $sdk = "$env:LOCALAPPDATA\Android\Sdk"
    $emu = "$sdk\emulator\emulator.exe"
    if (-not (Test-Path $emu)) { throw "emulator not found at $emu. Run step [4] first." }
    $adb = "$sdk\platform-tools\adb.exe"
    if (-not (Test-Path $adb)) { $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source }
    if (-not $adb) { throw "adb not found. Run step [4] or add adb to PATH." }

    Write-Host ">>> Stopping any running AVD (qemu-system + launcher)..." -ForegroundColor Cyan
    Get-Process qemu-system-* -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process emulator*     -ErrorAction SilentlyContinue | Stop-Process -Force
    & $adb kill-server  2>$null
    & $adb start-server 2>$null
    Start-Sleep -Seconds 2

    Set-EmulatorGpuPreference   # render on the iGPU, keep the dGPU for the model
    Write-Host ">>> Cold-booting $AvdName..." -ForegroundColor Green
    Start-Process -FilePath $emu `
        -ArgumentList '-avd',$AvdName,'-gpu','host',
                      '-no-snapshot','-no-snapshot-save','-no-snapshot-load',
                      '-no-boot-anim','-no-metrics' `
        -WindowStyle Hidden

    ## Poll getprop, never 'adb wait-for-device' (blocks forever with no timeout).
    Write-Host ">>> Waiting for Android to finish booting..." -ForegroundColor Cyan
    $booted = ""; $deadline = (Get-Date).AddMinutes(8)
    while ((Get-Date) -lt $deadline) {
        $booted = (& $adb shell getprop sys.boot_completed 2>$null | Out-String).Trim()
        if ($booted -eq "1") { break }
        Start-Sleep -Seconds 5
    }
    if ($booted -ne "1") {
        throw "AVD did not finish booting in 8 min. If it hangs on a white screen, relaunch with -wipe-data."
    }
    Write-Host ">>> AVD booted." -ForegroundColor Green
    & $adb devices
}

$script:Items = @(
    @{ Key="prereqs";  Group="SETUP"; Color="Cyan"; Label="Install prerequisites (winget, dev mode, VCRedist)"
       Action=$StepPrereqs;  Enabled={ $true }; Why="" }

    @{ Key="hyperv";   Group="SETUP"; Color="Cyan"; Label="Enable Hyper-V + WHPX          (reboot after)"
       Action=$StepHyperV; Enabled={ -not $script:Env.HyperV }; Why="Already enabled." }

    @{ Key="verify";   Group="SETUP"; Color="Cyan"; Label="Verify Hyper-V / WHPX acceleration"
       Action=$StepVerifyHyperV; Enabled={ $script:Env.HyperV }; Why="Run step 2, then reboot." }

    @{ Key="android";  Group="SETUP"; Color="Cyan"; Label="Install Android Studio + Pixel_5 AVD (interactive)"
       Action=$StepAndroid; Enabled={ $script:Env.HyperV }
       Why="Needs Hyper-V (step 2) and a reboot, or the AVD has no acceleration." }

    @{ Key="ollama";   Group="SETUP"; Color="Cyan"; Label="Install mobile-mcp + Ollama, pull qwen3.5"
       Action=$StepOllama;   Enabled={ $script:Env.Npm -and $script:Env.Ollama }
       Why="Needs node + ollama from step 1. Open a NEW terminal after installing." }

    @{ Key="token";    Group="SETUP"; Color="Cyan"; Label="Set Telegram bot token"
       Action=$StepToken;    Enabled={ $true }; Why="" }

    @{ Key="openclaw"; Group="SETUP"; Color="Cyan"; Label="Install + configure OpenClaw   (opens TUI)"
       Action=$StepOpenClaw
       Enabled={ $script:Env.Adb -and $script:Env.Npx -and $script:Env.Ollama -and $script:Env.Model -and $script:Env.MobileMcp -and $script:Env.Token }
       Why="Needs adb, npx, ollama, qwen3.5, mobile-mcp, and a saved token." }

    @{ Key="suite";    Group="USE"; Color="Green"; Label="Run the test suite (diagnostics)"
       Action=$StepSuite;    Enabled={ $script:Env.OpenClaw }
       Why="OpenClaw is not installed (step 7)." }

    @{ Key="agent";    Group="USE"; Color="Green"; Label="Run the three agent tests"
       Action=$StepTest; Enabled={ $script:Env.OpenClaw -and $script:Env.Cfg -and $script:Env.Device }
       Why="Needs OpenClaw configured (step 7) and a running AVD." }

    @{ Key="xapk";     Group="USE"; Color="Green"; Label="Install an .xapk / .apk onto the AVD"
       Action=$StepXapk; Enabled={ $script:Env.Adb -and $script:Env.Device }
       Why="No device attached. Start the AVD (step 4)." }

    @{ Key="launchavd"; Group="USE"; Color="Green"; Label="Launch / relaunch the AVD (cold boot)"
       Action=$StepLaunchAvd; Enabled={ $script:Env.Avd }
       Why="No AVD yet. Create it with step 4." }

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

    @{ Key="autostart"; Group="USE"; Color="Green"; Label="Auto-start on boot: Ollama + gateway (on/off)"
       Action=$StepAutoStart
       Enabled={ $script:Env.OpenClaw -or $script:Env.Ollama }
       Why="Install OpenClaw (step 7) or Ollama (step 5) first -- there is nothing to auto-start yet." }

    @{ Key="skills";   Group="USE"; Color="Green"; Label="Install skills / MCPs / plugins (sub-menu)"
       Action=$StepSkills
       Enabled={ $script:Env.OpenClaw }
       Why="OpenClaw is not installed (step 7)." }

    @{ Key="docs";     Group="USE"; Color="Green"; Label="Generate README.md, LICENSE, .gitignore"
       Action=$StepReadme;   Enabled={ [bool]$PSCommandPath }
       Why="Only works when run as a file, not piped from the web." }

    @{ Key="uninstall"; Group="DANGER"; Color="Red"; Label="Uninstall everything"
       Action=$StepUninstall; Enabled={ $script:Env.Installed }
       Why="Nothing is installed." }
)

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

        ## A plain "-" bullet in front of every row -- no done/checkbox marker
        ## (the old "[x]"/"[ ]" read as confusing). Navigation is by arrow keys;
        ## number keys 1-9/0 still select the first ten by position, just not
        ## displayed. Availability is shown by dimming greyed rows and by the
        ## "unavailable: <why>" line under the cursor.
        if ($i -eq $Selected) {
            if (-not $on) {
                Write-Host "  > - $($item.Label)".PadRight(64) -ForegroundColor DarkGray -BackgroundColor Black
            } else {
                $bg = if ($item.Group -eq "DANGER") { "DarkRed" } else { "DarkCyan" }
                Write-Host "  > - $($item.Label)".PadRight(64) -ForegroundColor White -BackgroundColor $bg
            }
        } elseif (-not $on) {
            ## greyed out: dim everything
            Write-Host "    - $($item.Label)" -ForegroundColor DarkGray
        } else {
            Write-Host "    - " -ForegroundColor DarkGray -NoNewline
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
        [void]$sb.AppendLine("# Full Test report")
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

    ## Relaunch whichever script was actually invoked (recorded at the top),
    ## forwarding its original arguments.
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
    ## unattended.
    if ($RunAll) { Start-FullTest; return }

    ## -StartAvd: just launch/relaunch the AVD and exit. Runs the launchavd menu
    ## item without opening the menu.
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
##  Set $global:OC_NoAutoStart before dot-sourcing this file to load its
##  functions and menu without opening the menu (used by the headless docs
##  regeneration).
## ============================================================
if (-not $global:OC_NoAutoStart) {
    Start-Menu
}
