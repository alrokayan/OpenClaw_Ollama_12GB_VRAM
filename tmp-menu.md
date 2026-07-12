# Menu spec -- OpenClaw + Ollama + Android (single script)
#
# NAVIGATION (decided): number-driven, NOT arrow keys.
#   - The screen is drawn ONCE; you type a number + Enter to pick an item.
#     Arrow-key highlighting redraws the whole screen on every keypress -- that
#     is the flashing/clunk in Windows PowerShell 5.1. Numbers draw once.
#   - Esc  = jump back to the MAIN menu from anywhere; Esc at the main menu = exit.
#     (blank + Enter does the same, in case a terminal swallows Esc.)
#   - Submenus work identically: number to pick, Esc to the main menu.
#   - Each item carries a state tag where it helps:
#       [installed] / [-] ,  [running] / [stopped] ,  green when done.
#
# DESIGN PRINCIPLE (decided): keep it SIMPLE and copy-pasteable.
#   - Each menu action is a plain, self-contained function whose body is the
#     REAL commands (winget install ..., openclaw config patch ..., adb ...),
#     with comments -- so you can copy any block out and run it by hand to test.
#   - Minimise clever PowerShell: no deep wrapper indirection around the actual
#     work. A thin menu dispatch (number -> call function) and small obvious
#     helpers only. Readability over DRY.
#
# PRECONDITIONS used below:
#   installed  = binary/package on disk
#   running    = daemon up (Ollama daemon / OpenClaw gateway / the AVD)
#   configured = ~/.openclaw has a valid openclaw.json + env
#
# CONFIG = single source of truth, prepared BY HAND before you run the script:
#   the repo tracks openclaw.template.json + env.example. YOU copy them to
#   openclaw.json + .env in the repo (both gitignored) and fill in your data.
#   Then Install step 10 simply COPIES those two files into ~/.openclaw -- the
#   script does not generate them. Config flows repo -> ~/.openclaw only; runtime
#   state (sessions/, devices/) stays in ~/.openclaw and is never mirrored back.
#   (file is .env WITH the dot, matching ~/.openclaw/.env; .gitignore ignores
#    .env and openclaw.json)

============================================================
[1] INSTALL            (each item turns green when already installed)
============================================================
 1. Enable / re-enable Hyper-V + Windows Hypervisor Platform   (reboot after)
 2. Enable Developer Mode
 3. Install / reinstall Prerequisites (nodejs, python, VCRedist)
 4. Install / reinstall Ollama (qwen3.5:latest)
 5. Install / reinstall Android Studio + Android SDK Manager
 6. Create / recreate the Android Virtual Device (AVD)
        grey unless SDK Manager installed AND Hyper-V enabled
 7. Set iGPU for the AVD (recommended)               grey unless the AVD exists
 8. Install an APK / XAPK onto the AVD (optional)    grey unless the AVD is running
 9. Install / reinstall OpenClaw
10. Create / recreate config -- copy the repo's openclaw.json + .env -> ~/.openclaw/
        grey unless OpenClaw installed AND repo openclaw.json + .env exist
        (you prepare those from the templates by hand first -- see CONFIG note;
         token stays the literal ${TELEGRAM_BOT_TOKEN})
11. Configure OpenClaw          grey unless OpenClaw installed
        1. MCP:   Mobile-MCP       (install / reinstall)
        2. MCP:   Context7         (install / reinstall)
        3. SKILL: Base64-toolkit   (install / reinstall)
        4. SKILL: Mobile Skill     (install / reinstall; skill id = mobile-skill)
        5. Set / reset Telegram Bot Token + User ID     -> writes ./env
        6. Set / reset Context7 API key
        7. Set / reset Agent Thinking     -> config: thinking / thinkingDefault
        8. Set / reset Agent Fast Mode    -> config: fastModeDefault
        9. Enable / disable Memory        -> config: memory.*

============================================================
[2] OPERATION
============================================================
 1. Status                 instant yes/no per component (booleans, no reasoning)
 2. Clear all cache        system-wide toolchain caches (NOT logs, NOT data):
        ~/.npm/_npx + `npm cache clean`, ~/.gradle/caches,
        ~/.android/{cache,build-cache}, AVD snapshots/, %TEMP% + %LOCALAPPDATA%\Temp
        (do not run mid-install -- it wipes %TEMP%)
 3. Session Management                  grey unless OpenClaw running
        1. List all sessions                    -> openclaw sessions list
        2. Check Telegram context/token status  -> openclaw sessions list --json
        3. Compact Telegram session (agent:main:telegram) -> openclaw sessions compact
        4. Reset Telegram session (agent:main:telegram)
               -> delete its store entry, then openclaw gateway restart
        5. Delete ALL sessions except agent:main:telegram
               -> session-store cleanup, then openclaw gateway restart
 4. Approve all pending devices         grey unless OpenClaw running
 5. List active skills and MCPs         grey unless OpenClaw running
 6. Open Dashboard GUI                  grey unless OpenClaw running
 7. Open TUI                            grey unless OpenClaw running
 8. Restart OpenClaw Gateway            quick bounce of just the gateway
 9. Service Control   (one panel; a row per service, action by letter)
        #              Running?   [s]tart   st[o]p   [r]estart   [a]uto-boot
        #   AVD         yes/no
        #   Ollama      yes/no
        #   OpenClaw    yes/no     (st[o]p here = the whole gateway, heavier
        #                           than item 8 which only bounces it)
        # ! MCPs are not services -- per-session subprocesses. Toggle them in
        #   Configure OpenClaw, not here.
10. Change AVD configuration            (future -- greyed)
11. Change Ollama model                 (future -- greyed)

============================================================
[3] MAINTENANCE
============================================================
 1. Script self-check           parse clean + ASCII-only + menu loads (fast)
 2. Show log
        1. Tail script log      -> ./logs/<latest>.txt
        2. Tail Ollama log      -> %LOCALAPPDATA%\Ollama\server.log
        3. Tail Android log     -> adb logcat
        4. Tail OpenClaw log    -> openclaw logs
 3. Reset script                restore to the as-downloaded state; move current
                                files to Trash/<timestamp>/ (Trash/ is gitignored),
                                never delete
 4. OpenClaw configuration check   grey unless OpenClaw running  -> openclaw doctor
 5. Installation Diagnosis      deep, per-component; may take minutes
 6. Configuration Diagnosis     deep, per-component; may call `doctor --fix`.
                                kept SEPARATE from 5 so a known-good install is
                                not re-diagnosed for minutes
 7. Local Agent Tests           grey unless Ollama running
        1. Ping local agent (model responds via the gateway)
        2. Context window / token test
        3. ADB test             (also needs a running device)

   # Status (Operation 1) vs Diagnosis (here): Status = instant booleans;
   # Diagnosis = slow, stacked checks with fixes. Deliberately separate.

============================================================
[4] UNINSTALL           (each item grey unless installed)
============================================================
 1. Uninstall MCP:   Mobile-MCP
 2. Uninstall MCP:   Context7
 3. Uninstall SKILL: Base64-toolkit
 4. Uninstall SKILL: Mobile Skill
 5. Uninstall Android Studio + Android SDK Manager
 6. Uninstall OpenClaw
 7. Uninstall Ollama
 8. Uninstall Prerequisites (nodejs, python, ...)          (Hyper-V left enabled)
 9. Full reset OpenClaw configuration    -> openclaw reset (re-init to defaults,
                                            keeps the binary installed)
10. Delete data / config files
        1. Delete OpenClaw config  (~/.openclaw: openclaw.json, env, sessions, devices)
        2. Delete AVD
        3. Delete Ollama models    (~/.ollama -- the 6.6 GB pull)
        4. Delete all
        # note: 9 re-initialises config in place; 10.1 removes ~/.openclaw wholesale.
11. Disable Hyper-V + Windows Hypervisor Platform

============================================================
Decided:
  - Prerequisites: NO 7zip / git (were for a removed feature).
  - Config: repo templates (openclaw.template.json + env.example) -> filled,
    gitignored openclaw.json + env in the repo = single source of truth,
    pushed to ~/.openclaw by Install 10.
  - Navigation: numbered, Esc -> main menu / exit (no arrow-key redraw).
  - Service Control: one panel (AVD / Ollama / OpenClaw); MCPs excluded.
  - Build style: each action a self-contained, copy-pasteable function.
  - OpenClaw installs as a plain npm global (`npm install -g openclaw`) -- NO
    blocking Ollama TUI. Config comes from Copy-Config (repo -> ~/.openclaw).
============================================================

============================================================
DEFERRED -- build the CORE first, come back to these (they cost real time):
============================================================
CORE now (non-Android happy path): Install prereqs -> Ollama + model ->
  npm i -g openclaw -> Copy-Config -> start gateway -> Telegram agent replies.
  Plus Operations: Status, Restart gateway, Service Control (Ollama/OpenClaw),
  Session Management; and Configure: settings + Context7.

Deferred (with why):
  1. Android Studio + SDK + AVD automation (Install 5/6). The Studio SETUP WIZARD
     is a GUI human step with no headless entry; the SDK download is minutes; AVD
     create+boot is involved. Testing needs a real wizard run. -> keep Install-Studio
     / Install-Avd as stubs; port the old StepAndroid later, or install Android by
     hand meanwhile.
  2. Install APK/XAPK (Install 8). Needs a booted AVD. -> after Android.
  3. Mobile-MCP + Mobile Skill install (Configure). Android-dependent. -> after
     Android. (Context7 MCP + Base64-toolkit are NOT Android-gated -- can do now.)
  4. AVD-related state/coloring uses Test-Studio/Test-Avd already; fine.
  5. fix.ps1 Local Agent Tests -> ADB test needs a device. -> after Android.
  6. Deep Installation/Configuration Diagnosis (may run `doctor --fix`, minutes).
     -> start with quick Status; add the slow deep diagnosis later.
  7. Reset script -> Trash/ (fix.ps1). -> later; low priority.
============================================================

============================================================
NOTES for the cross-platform (.sh) port + architecture:
============================================================
- ROOT CAUSE of "connection refused by the provider endpoint" (both OS): after
  the install reboot the gateway comes back but the OLLAMA daemon does NOT, so
  :11434 is dead. FIX = auto-start Ollama on boot, THEN (re)start the gateway.
  Windows (built in run.ps1 Enable-AutoStart): a logon Scheduled Task runs
  oc-autostart.ps1 = start `ollama serve`, wait for :11434, `openclaw gateway
  restart`.
  Mac (.sh equivalent, TODO): use `brew services start ollama` (persistent
  launchd) OR a ~/Library/LaunchAgents/*.plist running `ollama serve`, then
  `openclaw gateway restart`. A plain `ollama serve` from a script does NOT
  survive reboot -- that is the Mac repro.
- Bare metal (NOT Docker): Ollama needs the host GPU (Docker has NO GPU on Mac;
  finicky WSL2 passthrough on Windows), and the AVD needs host virtualization +
  simple adb. Those two cannot be cleanly containerized, and Docker would not fix
  the service-lifecycle bug above.
- Linux-only skills/add-ons (the reason Docker was tempting): most OpenClaw
  skills/MCPs are Node (cross-platform). For the few that assume Linux, provide
  the needed bin on the host (we already shim `python3`), or run just THAT skill's
  dependency via WSL2 on Windows -- a targeted fix, not a whole-stack container.
============================================================
