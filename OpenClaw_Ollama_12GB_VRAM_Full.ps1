#Requires -Version 5.1

<#
.SYNOPSIS
    OpenClaw + Ollama, Full. Everything in Lite, plus an Android emulator
    the agent can see and control.

.DESCRIPTION
    This script is thin on purpose. It loads
    OpenClaw_Ollama_12GB_VRAM_Lite.ps1, turns on three feature flags,
    defines the four Android-only steps, rebuilds the menu, and starts it.

    Every shared step -- prerequisites, Ollama, the Telegram token, the
    OpenClaw configuration, the test suite, status, uninstall, the docs
    generator -- lives in Lite and is used here unchanged. The flags are
    what make those steps do more:

      $OC_Features.Android     install the SDK and AVD; check Hyper-V/WHPX
      $OC_Features.Mcp         register scrcpy-mcp as an MCP server
      $OC_Features.DroidClaw   write and load the DroidClaw skill

    WHAT FULL ADDS

      Emulator  A Pixel_5 AVD with software rendering
                (swiftshader_indirect), 4 vCPUs, 3 GB RAM, 16 GB disk, no
                skin, snapshots fully disabled. Software rendering is
                deliberate: on a 12 GB card the GPU belongs to the model.
                Cold boot is the price of disabling snapshots, and
                disabling them is what removes the "Bug report interrupted
                by snapshot load" popup at its source. Quick boot IS
                snapshot loading; the two cannot coexist.

      Bridge    scrcpy-mcp, spawned via cmd.exe. Node's spawn() throws
                ENOENT on a bare "npx" (no PATHEXT resolution for child
                processes) and EINVAL on "npx.cmd" (it cannot spawn .cmd
                files directly). "cmd.exe /c npx scrcpy-mcp" avoids both.

      Skill     DroidClaw: a perception-reason-act loop over the scrcpy
                tools. Written UTF-8 with no BOM, because a BOM ahead of
                the opening --- breaks the YAML frontmatter and the skill
                is silently never loaded.

      Installer An .xapk / .apks / .apk installer that handles split APKs
                (adb install-multiple) and pushes any .obb assets, which a
                plain "adb install" cannot do.

.PARAMETER None
    No parameters. Edit the settings block in the Lite script.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\OpenClaw_Ollama_12GB_VRAM_Full.ps1

    Uses the Lite script sitting next to it. Preferred: you can read both
    files first.

.EXAMPLE
    .\OpenClaw_Ollama_12GB_VRAM_Full.ps1 -NumCtx 32768 -AvdName Pixel_7

    Arguments are forwarded to Lite when it is dot-sourced, and forwarded
    again if the script relaunches itself elevated.

.EXAMPLE
    $f = "$env:TEMP\OpenClaw_Full.ps1"
    irm https://raw.githubusercontent.com/alrokayan/OpenClaw_Ollama_12GB_VRAM/main/OpenClaw_Ollama_12GB_VRAM_Full.ps1 -OutFile $f
    Unblock-File $f
    & $f

    One-liner install. NOT "irm ... | iex": #Requires and param() do not
    survive Invoke-Expression. With no Lite next to it, this fetches Lite
    into $env:TEMP as well and dot-sources that.

    Two pieces of remote code, executed as Administrator, with no review
    and no integrity check. Both land in $env:TEMP. Read them first.

.NOTES
    DISCLAIMER
              Run at your own risk. No warranty of any kind. On top of
              everything Lite does, this enables Hyper-V, which changes
              virtualization machine-wide: VirtualBox and VMware slow
              down, HAXM stops loading. Disabling it later also breaks
              WSL2, Docker Desktop, and Windows Sandbox.

              The uninstall step irreversibly deletes ~/.android -- your
              AVDs and their disk images.

              The agent gets shell access and control of a connected
              Android device, while web search feeds it untrusted content.
              OpenClaw's own security docs call that combination out.

    Reboot    Required between "Enable Hyper-V" and "Verify Hyper-V".

    Blocking  Two steps wait on a human: the Android Studio setup wizard,
              and the OpenClaw TUI that "ollama launch openclaw" opens
              despite --yes being documented as headless.

.LINK
    https://github.com/alrokayan/OpenClaw_Ollama_12GB_VRAM
.LINK
    https://docs.openclaw.ai
#>

## ============================================================
##  Parameters -- forwarded to Lite when it is loaded
## ============================================================
[CmdletBinding()]
param(
    [string]$TelegramId = "6420885035",
    [string]$Model      = "qwen3.5:latest",

    [ValidateRange(4096, 262144)]
    [int]$NumCtx = 65536,

    [ValidateRange(1024, 65535)]
    [int]$GatewayPort = 18789,

    [string]$AvdName  = "Pixel_5",
    [string]$SysImage = "system-images;android-37.1;google_apis_ps16k;x86_64",

    [switch]$NoDashboard,
    [string]$LicenseHolder = "Mohammed Alrokayan",
    [switch]$NoElevate
)

$ErrorActionPreference = "Stop"

## ============================================================
##  0. Claim the entry point.
##
##     Lite records $PSCommandPath as the script to relaunch when it
##     elevates. If we did not claim it first, it would relaunch LITE and
##     the Android features would vanish without a word.
## ============================================================
$global:OC_EntryScript = $PSCommandPath
$global:OC_EntryArgs   = $PSBoundParameters

## ============================================================
##  1. Turn on the features BEFORE loading Lite.
##     Lite reads $global:OC_Features when it defines its steps, so
##     setting these afterwards would build the Android-less variants.
## ============================================================
$global:OC_Features = @{
    Android   = $true
    Mcp       = $true
    DroidClaw = $true
}

## Stop Lite from starting its own menu. We extend it first.
$global:OC_NoAutoStart = $true

## ============================================================
##  2. Load Lite.
##
##     Dot-sourcing runs it in this scope, so its parameters, helpers,
##     step scriptblocks, Show-Menu, and Start-Menu all land here. Our
##     own arguments are forwarded, so -NumCtx 32768 reaches Lite.
##
##     Prefer the file next to us. Otherwise fetch it to a temp file and
##     dot-source that. NOT Invoke-Expression: Lite has a param() block,
##     and parameters cannot be bound through iex.
## ============================================================
$LiteName = "OpenClaw_Ollama_12GB_VRAM_Lite.ps1"
$LiteUrl  = "https://raw.githubusercontent.com/alrokayan/OpenClaw_Ollama_12GB_VRAM/main/$LiteName"

$liteLocal = if ($PSScriptRoot) { Join-Path $PSScriptRoot $LiteName } else { $null }

if ($liteLocal -and (Test-Path $liteLocal)) {
    Write-Host "Loading $LiteName from disk..." -ForegroundColor DarkGray
} else {
    Write-Host "No local $LiteName. Fetching from:" -ForegroundColor Yellow
    Write-Host "  $LiteUrl" -ForegroundColor Yellow
    Write-Host "About to execute remote code as Administrator. Ctrl+C to abort." -ForegroundColor Yellow
    Start-Sleep -Seconds 3

    $liteLocal = Join-Path $env:TEMP $LiteName
    try {
        Invoke-WebRequest -Uri $LiteUrl -OutFile $liteLocal -UseBasicParsing -ErrorAction Stop
    } catch {
        throw "Could not fetch $LiteName. Clone the repo and run both files from disk. ($($_.Exception.Message))"
    }
    ## Downloaded files carry a mark-of-the-web stream and will not run
    Unblock-File $liteLocal -ErrorAction SilentlyContinue
    Write-Host "Saved to $liteLocal -- read it before continuing if you like." -ForegroundColor DarkGray
}

## Forward only what was actually passed, so Lite's defaults still apply
. $liteLocal @PSBoundParameters

if (-not (Get-Command Start-Menu -ErrorAction SilentlyContinue)) {
    throw "$LiteName loaded but Start-Menu is missing. Version mismatch?"
}

$script:Edition = "Full"

## ============================================================
##  3. Android-only steps.
##     These are the ONLY steps that do not exist in Lite.
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
##  Android Studio, SDK, Pixel_5 AVD
##
##  Android 37 system images exist only as 16KB page-size variants:
##  google_apis_ps16k, not plain google_apis.
##  avdmanager creates the AVD AND its .ini pointer; do not hand-write them.
##  "emulator" only launches AVDs; "avdmanager" creates them.
## ============================================================
$StepAndroid = {
    $studioExe = "C:\Program Files\Android\Android Studio\bin\studio64.exe"

    if (Test-Path $studioExe) {
        Write-Host ">>> Android Studio already installed." -ForegroundColor Green
    } else {
        winget install Google.AndroidStudio --accept-package-agreements --accept-source-agreements --wait
    }

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
    Read-Host "Press Enter once SDK setup is complete"

    $sdkPath = "$env:LOCALAPPDATA\Android\Sdk"
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
        # 4 cores: software GL is CPU-bound, and scrcpy's H.264 stream is
        # encoded on the device -- here, the emulator's virtual CPUs.
        'hw.cpu.ncore=4',
        'hw.dPad=no',
        'hw.device.hash2=MD5:12ab7fcb681cafc1697d019f385bf3b9',
        'hw.device.manufacturer=Google',
        'hw.device.name=pixel_5',
        'hw.gps=yes',
        # Software rendering. This is the Device Manager "Graphics" setting.
        # The in-emulator Settings > Advanced control is a RUNTIME override that
        # resets to auto on reboot; config.ini plus the -gpu launch flag persist.
        'hw.gpu.enabled=yes',
        'hw.gpu.mode=swiftshader_indirect',
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
        # No skin: scrcpy does not need the bezel art
        'showDeviceFrame=no',
        'tag.display=Google APIs',
        'tag.id=google_apis_ps16k',
        'target=android-37.1',
        'vm.heapSize=256'
    )
    Set-Content -Path $configPath -Value $configContent

    ## Start-Process, not "& emulator.exe": a console-attached launch ties the
    ## emulator's lifetime to this window.
    Write-Host ">>> Launching $AvdName (detached)..." -ForegroundColor Green
    Start-Process -FilePath "$emulatorPath\emulator.exe" `
        -ArgumentList '-avd',$AvdName,'-gpu','swiftshader_indirect',
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
    ## A GUI picker beats typing a Windows path. Falls back to Read-Host if
    ## WinForms is unavailable (Server Core, PS in a non-STA host, etc).
    $XapkPath = $null
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
##  4. Swap the placeholders for the real steps.
##
##     The menu list itself lives in Lite and is NOT rebuilt here. That
##     keeps the numbering identical across editions: [4] is "Install the
##     AVD" in both, greyed out in Lite, live here.
## ============================================================
Set-MenuItem -Key "hyperv" `
    -Action $StepHyperV `
    -Enabled { -not $script:Env.HyperV } `
    -Why "Already enabled."

Set-MenuItem -Key "verify" `
    -Action $StepVerifyHyperV `
    -Enabled { $script:Env.HyperV } `
    -Why "Run step 2, then reboot."

Set-MenuItem -Key "android" `
    -Action $StepAndroid `
    -Enabled { $script:Env.HyperV } `
    -Why "Needs Hyper-V (step 2) and a reboot, or the AVD has no acceleration."

## Full also installs scrcpy-mcp in this step; the shared body reads
## $Features.Mcp, so only the label changes.
Set-MenuItem -Key "ollama" `
    -Label "Install scrcpy-mcp + Ollama, pull qwen3.5"

## Step 7 needs more on Full: adb, scrcpy, and the MCP bridge.
Set-MenuItem -Key "openclaw" `
    -Enabled { $script:Env.Adb -and $script:Env.Scrcpy -and $script:Env.Npx -and
               $script:Env.Ollama -and $script:Env.Model -and $script:Env.ScrcpyMcp -and
               $script:Env.Token } `
    -Why "Needs adb, scrcpy, npx, ollama, qwen3.5, scrcpy-mcp, and a saved token."

Set-MenuItem -Key "agent" `
    -Action $StepTest `
    -Enabled { $script:Env.OpenClaw -and $script:Env.Cfg -and $script:Env.Device } `
    -Why "Needs OpenClaw configured (step 7) and a running AVD."

Set-MenuItem -Key "xapk" `
    -Action $StepXapk `
    -Enabled { $script:Env.Adb -and $script:Env.Device } `
    -Why "No device attached. Start the AVD (step 4)."

## ============================================================
##  5. Go.
## ============================================================
Start-Menu
