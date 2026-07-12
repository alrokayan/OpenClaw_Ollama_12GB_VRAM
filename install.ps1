# install.ps1 -- [1] INSTALL. Needs Administrator (Hyper-V, DevMode, winget).
# Run standalone:  powershell -ExecutionPolicy Bypass -File .\install.ps1
# Or reach it from start_here.ps1.
#
# Every action is a plain function whose body is the real commands -- copy any
# one out and run it by hand to test.

if (-not (Get-Command Say -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\common.ps1" }

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
    # TODO(port): winget install Google.AndroidStudio; the human runs the Studio
    # setup wizard (SDK Command-line Tools); then sdkmanager downloads emulator +
    # platform-tools + $SysImage. Real commands are in the old StepAndroid.
    Warn "TODO: install Android Studio + SDK. Not wired yet."
    Pause
}

function Install-Avd {
    # TODO(port): avdmanager create avd -n $AvdName -d pixel_5 -k $SysImage --force
    Warn "TODO: create the $AvdName AVD. Not wired yet."
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

function Install-Apk {
    # TODO(port): pick an .apk/.xapk, then adb install (or install-multiple for a
    # split .xapk). Real logic in the old StepXapk.
    Warn "TODO: install an APK/XAPK onto the AVD. Not wired yet."
    Pause
}

function Install-OpenClaw {
    Say ">>> Installing OpenClaw..." Cyan
    $ErrorActionPreference = 'Continue'   # npm streams progress to stderr
    if ($UseOllama) {
        # Local model path: OpenClaw is a plain npm global -- NO Ollama TUI, no
        # onboarding. Config comes from Copy-Config (step 10); provider = Ollama.
        npm install -g openclaw@latest
        if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = 'Stop'; Die "npm install -g openclaw failed." }
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

function Copy-Config {
    # OPTIONAL fast path: if you filled openclaw.json + .env in the repo (from the
    # templates), copy them straight into ~/.openclaw -- no onboarding. Token stays
    # the literal ${TELEGRAM_BOT_TOKEN} in openclaw.json; value only in .env.
    $srcJson = Join-Path $RepoDir 'openclaw.json'
    $srcEnv  = Join-Path $RepoDir '.env'
    if ((Test-Path $srcJson) -and (Test-Path $srcEnv)) {
        Say ">>> Found repo openclaw.json + .env; copying into $ClawDir..." Cyan
        New-Item -ItemType Directory -Force $ClawDir | Out-Null
        Copy-Item $srcJson (Join-Path $ClawDir 'openclaw.json') -Force
        Copy-Item $srcEnv  (Join-Path $ClawDir '.env')          -Force
        Ok "config copied."
    } else {
        Warn "No filled openclaw.json + .env in the repo."
        Say "  Tip: copy openclaw.template.json -> openclaw.json and env.example -> .env," DarkGray
        Say "  fill them, and re-run to skip onboarding entirely." DarkGray
        # TODO(port): interactive fallback -- prompt for token and run onboarding.
        Warn "Interactive onboarding fallback not wired yet."
    }
    Pause
}

function Menu-Configure {
    # TODO(port): submenu -- install Mobile-MCP / Context7 / Base64-toolkit /
    # Mobile Skill, and set token / context7 key / thinking / fast / memory.
    Warn "TODO: Configure OpenClaw submenu. Not wired yet."
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
            Line 7 "Set iGPU for the AVD (recommended)"
            Line 8 "Install APK / XAPK onto the AVD (optional)"
        }
        Line  9 ("Install OpenClaw" + $(if ($UseOllama) { '' } else { ' (cloud)' })) (Test-OpenClaw)
        Line 10 "Create config (copy -> ~/.openclaw)"       (Test-Configured)
        Line 11 "Configure OpenClaw"
        Footer
        $c = Read-Choice 11
        if ($null -eq $c) { return }
        switch ($c) {
            '1'  { Install-HyperV }
            '2'  { Install-DevMode }
            '3'  { Install-Prereqs }
            '4'  { if ($UseOllama)  { Install-Ollama } }
            '5'  { if ($UseAndroid) { Install-Studio } }
            '6'  { if ($UseAndroid) { Install-Avd } }
            '7'  { if ($UseAndroid) { Set-AvdIgpu } }
            '8'  { if ($UseAndroid) { Install-Apk } }
            '9'  { Install-OpenClaw }
            '10' { Copy-Config }
            '11' { Menu-Configure }
        }
    }
}

# Run standalone -> show this menu. start_here.ps1 sets OC_Sourced to skip this.
if (-not $global:OC_Sourced) {
    $global:OC_Entry = $PSCommandPath
    Menu-Install
}
