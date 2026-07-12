# install.ps1 -- [1] INSTALL. Needs Administrator (Hyper-V, DevMode, winget).
# Run standalone:  powershell -ExecutionPolicy Bypass -File .\install.ps1
# Or reach it from start_here.ps1.
#
# Every action is a plain function whose body is the real commands -- copy any
# one out and run it by hand to test.

# Standalone args (arg > config.json > default): .\install.ps1 -Model x -NumCtx 65536
# Self-referencing defaults so a dot-source from start_here.ps1 does NOT blank them.
param(
    [string]$Model = $Model, [int]$NumCtx = $NumCtx, [string]$AvdName = $AvdName,
    [string]$KeepAlive = $KeepAlive, [string]$KvCacheType = $KvCacheType, [string]$FlashAttn = $FlashAttn
)
$OC_Args = @{} + $PSBoundParameters
if (-not (Get-Command Say -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\common.ps1" }
Set-ArgOverrides $OC_Args

function Install-HyperV {
    Say ">>> Enabling Hyper-V + Windows Hypervisor Platform..." Cyan
    # Use dism.exe (native) -- Enable-WindowsOptionalFeature is slow/flaky under
    # PS 7. Enable the leaf features + WHPX; /norestart so we reboot once.
    dism.exe /online /enable-feature /featurename:Microsoft-Hyper-V-Hypervisor /norestart
    dism.exe /online /enable-feature /featurename:Microsoft-Hyper-V-Services   /norestart
    dism.exe /online /enable-feature /featurename:HypervisorPlatform           /norestart
    Warn "Reboot required before the AVD has hardware acceleration."
    Pause
}

function Install-DevMode {
    Say ">>> Enabling Developer Mode..." Cyan
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v "AllowDevelopmentWithoutDevLicense" /d "1"
    Ok "Developer Mode enabled."
    Pause
}

function Install-Prereqs {
    Say ">>> Installing prerequisites (node, python, JDK, VCRedist)..." Cyan
    # Store-app python stubs shadow a real install -- remove them first.
    Remove-Item "$env:LOCALAPPDATA\Microsoft\WindowsApps\python.exe"  -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Microsoft\WindowsApps\python3.exe" -ErrorAction SilentlyContinue

    # winget installs ONE id per call -- loop, never pass a list.
    foreach ($id in 'OpenJS.NodeJS','Python.Python.3.12','Microsoft.OpenJDK.17','Microsoft.VCRedist.2015+.x64') {
        Say "  installing $id" DarkGray
        winget install -e --id $id --accept-source-agreements --accept-package-agreements
    }

    # base64-toolkit (a python skill) needs a real 'python3' binary; Windows
    # Python only ships 'python.exe'. Make a python3 copy next to it.
    Update-Path   # so 'python'/'node' resolve in this session for the next lines
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if ($py) {
        $py3 = Join-Path (Split-Path $py) 'python3.exe'
        if (-not (Test-Path $py3)) { Copy-Item $py $py3 }
        Ok "python3 provisioned."
    }
    Ok "PATH refreshed for this session -- no need to reopen the terminal."
    Pause
}

function Install-Ollama {
    Say ">>> Installing Ollama + pulling $Model..." Cyan
    $ErrorActionPreference = 'Continue'   # ollama streams progress to stderr
    winget install -e --id Ollama.Ollama --accept-source-agreements --accept-package-agreements
    Update-Path   # so 'ollama' resolves in this session
    Get-Process ollama* -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Process ollama -ArgumentList 'serve' -WindowStyle Hidden
    foreach ($i in 1..30) { if (Test-OllamaUp) { break }; Start-Sleep 2 }
    if (-not (Test-OllamaUp)) { $ErrorActionPreference = 'Stop'; Die "Ollama daemon never came up on :11434" }
    ollama pull $Model
    if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = 'Stop'; Die "ollama pull $Model failed." }
    ollama list
    $ErrorActionPreference = 'Stop'
    Pause
}

function Install-Studio {
    # Installs Android Studio, then the SDK: cmdline-tools (via the Studio wizard --
    # the ONE step that needs a human) + emulator + platform-tools + the system image.
    # The system-image download is what pulls kernel-ranchu + ramdisk.img; a partial
    # copy that has only system.img/vendor.img makes the emulator PANIC "missing
    # kernel file". AVD creation + launch is the separate Install-Avd step.
    Say ">>> Installing Android Studio + SDK..." Cyan
    $ErrorActionPreference = 'Continue'   # winget/sdkmanager stream progress to stderr

    $studioExe = "C:\Program Files\Android\Android Studio\bin\studio64.exe"
    $cmdlineTools = "$SdkPath\cmdline-tools\latest\bin"
    $sdkMgr = "$cmdlineTools\sdkmanager.bat"

    # 1) Android Studio itself (bundles the SDK Manager + AVD Manager GUIs).
    if (Test-Path $studioExe) { Ok "Android Studio already installed." }
    else { winget install -e --id Google.AndroidStudio --accept-source-agreements --accept-package-agreements --wait }

    # 2) SDK command-line tools -- only obtainable through the Studio setup wizard
    #    (a GUI with no headless entry point). On a re-run they already exist, so
    #    skip the wizard entirely.
    if (Test-Path $sdkMgr) {
        Ok "SDK command-line tools already present; skipping the setup wizard."
    } else {
        if (Test-Path $studioExe) {
            Say ">>> Launching Android Studio to complete SDK setup..." Cyan
            Start-Process -FilePath $studioExe -Verb RunAs
        }
        Say ""
        Say "==========================================================" Yellow
        Say "ACTION REQUIRED: finish the Android Studio Setup Wizard." Yellow
        Say "Then: More Actions > SDK Manager > Languages & Frameworks" Yellow
        Say "Android SDK > SDK Tools > Android SDK Command-line Tools" Yellow
        Say "Tick the box then OK (Check README.md for more  info)" Yellow
        Say "==========================================================" Yellow
        [void](Read-Host "  -- Press Enter once Android SDK Command-line Tools is installed --")
        if (-not (Test-Path $sdkMgr)) { $ErrorActionPreference = 'Stop'; Die "sdkmanager still missing at $sdkMgr. Finish the wizard (SDK Tools > Command-line Tools), then re-run." }
    }

    # 3) Persist ANDROID_HOME + PATH (User scope) so adb/emulator/sdkmanager resolve
    #    in new shells; refresh THIS process too so the download below can run now.
    $platformTools = "$SdkPath\platform-tools"
    $emulatorPath  = "$SdkPath\emulator"
    [Environment]::SetEnvironmentVariable("ANDROID_HOME", $SdkPath, "User")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    foreach ($d in $platformTools, $cmdlineTools, $emulatorPath) { if ($userPath -notlike "*$d*") { $userPath = "$userPath;$d" } }
    [Environment]::SetEnvironmentVariable("Path", $userPath, "User")
    $env:ANDROID_HOME = $SdkPath
    Update-Path   # re-reads Machine+User from the registry (now includes the dirs above)

    # 4) Download the emulator, platform-tools, the platform, and the system image.
    #    sdkmanager reads license prompts from stdin -- feed 'y'. Gate on exit code
    #    (native stderr is non-fatal under Continue).
    Say ">>> Updating SDK tooling..." Cyan
    & $sdkMgr --update

    # A partial system-image dir (system.img present but NO package.xml -- a manual
    # copy or an interrupted download) makes sdkmanager install the COMPLETE image
    # into a sibling 'x86_64-2', leaving the AVD's config.ini pointed at the
    # kernel-less 'x86_64' -> emulator PANIC. Remove any such incomplete dir first
    # so the download lands in the expected location.
    $imgDir = "$SdkPath\system-images\android-37.1\google_apis_ps16k\x86_64"
    if ((Test-Path "$imgDir\system.img") -and -not (Test-Path "$imgDir\package.xml")) {
        Warn "removing an incomplete system image at $imgDir (it would misdirect the download to x86_64-2)"
        Remove-Item $imgDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Say ">>> Downloading emulator + platform-tools + system image ($SysImage)..." Cyan
    (1..20 | ForEach-Object { 'y' }) | & $sdkMgr "emulator" "platform-tools" "platforms;android-37.1" $SysImage
    if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = 'Stop'; Die "SDK component download failed." }

    $ErrorActionPreference = 'Stop'
    Ok "Android Studio + SDK ready."
    Pause
}

function Install-Avd {
    # Create the AVD, write a tuned config.ini, launch it detached, and poll for
    # boot. avdmanager creates the AVD AND its .ini pointer -- never hand-write
    # those. 'emulator' only launches AVDs; 'avdmanager' creates them.
    Say ">>> Creating the $AvdName AVD..." Cyan
    $ErrorActionPreference = 'Continue'   # avdmanager/adb/emulator spew to stderr

    $avdMgr = "$SdkPath\cmdline-tools\latest\bin\avdmanager.bat"
    $emu    = "$SdkPath\emulator\emulator.exe"
    $adb    = "$SdkPath\platform-tools\adb.exe"
    if (-not (Test-Path $avdMgr)) { $ErrorActionPreference = 'Stop'; Die "avdmanager not found -- run '5) Install Android Studio + SDK' first." }
    if (-not (Test-Path "$SdkPath\system-images\android-37.1\google_apis_ps16k\x86_64\kernel-ranchu")) {
        Warn "system image looks incomplete (no kernel-ranchu). '5) Install Android Studio + SDK' pulls it -- the emulator will PANIC without it."
    }
    $env:ANDROID_HOME = $SdkPath
    Update-Path   # so adb/emulator resolve if this runs in a fresh session

    # -d = device profile. "no" answers the "create a custom hardware profile?" prompt.
    "no" | & $avdMgr create avd -n $AvdName -d "pixel_5" -k $SysImage --force
    if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = 'Stop'; Die "avdmanager failed to create the AVD." }

    # Opt out of emulator metrics so no first-run prompt blocks the headless launch.
    $androidCfg = "$HOME\.android"
    New-Item -ItemType Directory -Force $androidCfg | Out-Null
    Set-Content "$androidCfg\analytics.settings" '{"userId":"","hasOptedIn":false,"debugDisablePings":true}' -Encoding ascii

    # Tuned config.ini: cold boot every time (snapshots off -- "quick boot" IS
    # snapshot loading and cannot coexist), hardware GL (software rendered a BLANK
    # framebuffer on this class of host, breaking the vision loop), 4 cores, 3 GB
    # RAM. '7) Set iGPU' pins hw.gpu.mode=host to the integrated GPU so the dGPU's
    # VRAM stays entirely for the model.
    Say ">>> Writing config.ini..." Cyan
    $configPath = "$androidCfg\avd\$AvdName.avd\config.ini"
    $config = @(
        "AvdId=$AvdName"
        'PlayStore.enabled=false'
        'abi.type=x86_64'
        'avd.ini.displayname=Pixel 5'
        'avd.ini.encoding=UTF-8'
        'disk.dataPartition.size=16G'
        'fastboot.chosenSnapshotFile='
        'fastboot.forceChosenSnapshotBoot=no'
        'fastboot.forceColdBoot=yes'
        'fastboot.forceFastBoot=no'
        'hw.accelerometer=yes'
        'hw.arc=false'
        'hw.audioInput=yes'
        'hw.battery=yes'
        'hw.camera.back=virtualscene'
        'hw.camera.front=emulated'
        'hw.cpu.arch=x86_64'
        'hw.cpu.ncore=4'
        'hw.dPad=no'
        'hw.device.hash2=MD5:12ab7fcb681cafc1697d019f385bf3b9'
        'hw.device.manufacturer=Google'
        'hw.device.name=pixel_5'
        'hw.gps=yes'
        'hw.gpu.enabled=yes'
        'hw.gpu.mode=host'
        'hw.gyroscope=yes'
        'hw.initialOrientation=portrait'
        'hw.keyboard=yes'
        'hw.keyboard.charmap=qwerty2'
        'hw.keyboard.lid=yes'
        'hw.lcd.density=440'
        'hw.lcd.height=2340'
        'hw.lcd.width=1080'
        'hw.mainKeys=no'
        'hw.ramSize=3072'
        'hw.sdCard=yes'
        'hw.sensors.light=yes'
        'hw.sensors.magnetic_field=yes'
        'hw.sensors.orientation=yes'
        'hw.sensors.pressure=yes'
        'hw.sensors.proximity=yes'
        'hw.trackBall=no'
        'image.sysdir.1=system-images\android-37.1\google_apis_ps16k\x86_64\'
        'runtime.network.latency=none'
        'runtime.network.speed=full'
        'sdcard.size=512M'
        'showDeviceFrame=no'
        'tag.display=Google APIs'
        'tag.id=google_apis_ps16k'
        'target=android-37.1'
        'vm.heapSize=256'
    )
    Set-Content -Path $configPath -Value $config

    # Start-Process, not "& emulator.exe": a console-attached launch ties the
    # emulator's lifetime to this window. Cold boot, no snapshots, no metrics.
    Say ">>> Launching $AvdName (detached) + waiting for boot (up to 5 min)..." Cyan
    Start-Process -FilePath $emu -WindowStyle Hidden -ArgumentList `
        '-avd',$AvdName,'-gpu','host','-no-snapshot','-no-snapshot-save','-no-snapshot-load','-no-boot-anim','-no-metrics'

    # Never 'adb wait-for-device' (blocks forever if the emulator died). Poll with a
    # deadline; adb stderr against no device is eaten by 2>$null.
    & $adb start-server 2>$null
    $booted = ''
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $booted = (& $adb shell getprop sys.boot_completed 2>$null | Out-String).Trim()
        if ($booted -eq '1') { break }
        Start-Sleep 5
    }
    $ErrorActionPreference = 'Stop'
    if ($booted -ne '1') { Warn "AVD did not report boot_completed within 5 min -- check the emulator window, then retry." }
    else { & $adb devices; Ok "$AvdName created and booted." }
    Pause
}

function Set-AvdIgpu {
    Say ">>> Pinning the emulator to the integrated GPU..." Cyan
    # DirectX per-app GPU preference: 1 = power-saving (iGPU). Keeps the AVD off
    # the dGPU so the model keeps the VRAM.
    $emuDir = "$SdkPath\emulator"
    $key = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    foreach ($exe in "$emuDir\emulator.exe", "$emuDir\qemu\windows-x86_64\qemu-system-x86_64.exe") {
        if (Test-Path $exe) {
            New-ItemProperty -Path $key -Name $exe -Value 'GpuPreference=1;' -PropertyType String -Force | Out-Null
            Ok "pinned $(Split-Path $exe -Leaf) to the iGPU"
        }
    }
    Pause
}

function Install-OpenClaw {
    Say ">>> Installing OpenClaw..." Cyan
    $ErrorActionPreference = 'Continue'   # npm streams progress to stderr
    # npm blocks package install scripts by default on this box (its allow-scripts
    # policy), which would SKIP OpenClaw's postinstall-bundled-plugins.mjs -> an
    # incomplete install (no bundled plugins). Allowlist the packages whose scripts
    # the install needs, user-scope, before EITHER install path runs. If npm's
    # "allow-scripts" warning later lists new packages, add them here.
    npm config set allow-scripts=openclaw,@google/genai,protobufjs,tree-sitter-bash --location=user
    if ($UseOllama) {
        # Local model path: let Ollama install + launch OpenClaw wired to the model.
        # This runs OpenClaw's proper setup (incl. bundled plugins) -- a bare
        # `npm install -g openclaw` skips the postinstall scripts.
        ollama launch openclaw --model $Model --yes
        if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = 'Stop'; Die "ollama launch openclaw failed." }
    } else {
        # Cloud path: the official web installer, no onboarding (provider = cloud,
        # set in openclaw.json). Run as a scriptblock so we can pass -NoOnboard.
        & ([scriptblock]::Create((iwr -useb https://openclaw.ai/install.ps1))) -NoOnboard
    }
    Update-Path
    $ErrorActionPreference = 'Stop'
    if (Have openclaw) { Ok "OpenClaw installed ($(openclaw --version 2>$null))" }
    else { Warn "openclaw not on PATH yet -- reopen the terminal or re-run." }
    Pause
}

function Update-Config {
    # MERGE the repo's .openclaw\ config into ~/.openclaw -- never overwrite.
    # openclaw.json is layered on via `config patch` (keeps the live gateway token +
    # ollama base); .env keys are merged (repo wins on conflicts). Then doctor --fix
    # + gateway restart so the changes take effect. Token stays ${TELEGRAM_BOT_TOKEN}
    # in openclaw.json; the value lives only in .env.
    $tpl     = Join-Path $RepoDir '.openclaw'
    $srcJson = Join-Path $tpl 'openclaw.json'
    $srcEnv  = Join-Path $tpl '.env'
    if ((Test-Path $srcJson) -and (Test-Path $srcEnv)) {
        New-Item -ItemType Directory -Force $ClawDir | Out-Null
        $ErrorActionPreference = 'Continue'
        # openclaw.json: MERGE (patch), don't overwrite -- keeps the live gateway
        # token. (config patch REPLACES arrays, so the repo models list must carry
        # every model or it errors "would remove <id>".)
        Get-Content $srcJson -Raw | openclaw config patch --stdin *> $null
        Ok "openclaw.json updated"
        # .env: merge keys (live + repo, repo wins) -- never clobber other vars.
        $dst = Join-Path $ClawDir '.env'; $map = [ordered]@{}
        foreach ($f in @($dst, $srcEnv)) {
            if (Test-Path $f) { foreach ($ln in Get-Content $f) { if ($ln -match '^\s*([^#=]+?)\s*=\s*(.*)$') { $map[$Matches[1]] = $Matches[2] } } }
        }
        [IO.File]::WriteAllText($dst, (($map.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
        Ok ".env updated"
        openclaw doctor --fix        # visible -- shows what it repaired
        openclaw gateway restart     # visible -- confirms it came back up
        $ErrorActionPreference = 'Stop'
        Ok "OpenClaw configured + restarted."
    } else {
        Warn "openclaw.json + .env are missing in the .openclaw folder of this repo"
        if (Yes "Create and update them from the templates now so you can fill them in?") {
            if (-not (Test-Path $srcJson)) { Copy-Item (Join-Path $tpl 'openclaw.template.json') $srcJson }
            if (-not (Test-Path $srcEnv))  { Copy-Item (Join-Path $tpl 'env.example')            $srcEnv }
            Ok "created -- edit these, then re-run this step to update them in:"
            Say "    $srcJson" Green
            Say "    $srcEnv   <- put your @BotFather token here" Green
        }
    }
    Pause
}

function Menu-Install {
    if (-not (Ensure-Admin)) { return }   # Install needs Administrator
    while ($true) {
        Clear-Host
        Say "== INSTALL ==" Cyan
        Write-Host ""
        Line  1 "Enable Hyper-V + WHPX (reboot after)"     (Test-HyperV)
        Line  2 "Enable Developer Mode"                    (Test-DevMode)
        Line  3 "Install Prerequisites (node/python)"      (Test-Prereqs)
        if ($UseOllama)  { Line 4 "Install Ollama + pull $Model" (Test-Ollama) }
        if ($UseAndroid) {
            Line 5 "Install Android Studio + SDK"           (Test-Studio)
            Line 6 "Create AVD ($AvdName)"                  (Test-Avd)
            Line 7 "Set iGPU for the AVD (recommended)"     (Test-Igpu)
        }
        Line  8 ("Install OpenClaw" + $(if ($UseOllama) { '' } else { ' (cloud)' })) (Test-OpenClaw)
        Line  9 "Configure and restart OpenClaw (openclaw.json and .env)"       (Test-Configured)
        Footer
        $c = Read-Choice 9
        if ($null -eq $c) { return }
        switch ($c) {
            '1'  { Install-HyperV }
            '2'  { Install-DevMode }
            '3'  { Install-Prereqs }
            '4'  { if ($UseOllama)  { Install-Ollama } }
            '5'  { if ($UseAndroid) { Install-Studio } }
            '6'  { if ($UseAndroid) { Install-Avd } }
            '7'  { if ($UseAndroid) { Set-AvdIgpu } }
            '8'  { Install-OpenClaw }
            '9'  { Update-Config }
        }
    }
}

# Run standalone -> show this menu. start_here.ps1 sets OC_Sourced to skip this.
if (-not $global:OC_Sourced) {
    $global:OC_Entry = $PSCommandPath
    Menu-Install
}
