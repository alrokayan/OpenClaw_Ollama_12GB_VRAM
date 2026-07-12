# AVD — snapshots

Loaded on demand from `avd-management/SKILL.md`. The contract and safety gates in `android-common.md` apply.

List snapshots offline, or use emulator-console commands against a ready exact serial:

~~~powershell
& $emulator -avd $avdName -snapshot-list
& $adb -s $serial emu avd snapshot list
& $adb -s $serial emu avd snapshot save $snapshotName
& $adb -s $serial emu avd snapshot load $snapshotName
& $adb -s $serial emu avd snapshot delete $snapshotName
~~~

- Validate snapshot names conservatively.
- Save only from a stable, fully booted AVD, after considering whether the state contains accounts, tokens, or private app data; confirm the save when it captures sensitive state.
- Confirm every load (it restores older machine/guest state over current state) and every delete.
- Do not snapshot during boot, shutdown, disk repair, config editing, or concurrent same-AVD use.
- After emulator, image, hardware, or config changes, cold-boot before trusting snapshots.
- If Quick Boot is corrupt, try `-no-snapshot-load` first, then `-no-snapshot`. Do not delete snapshot storage automatically.
