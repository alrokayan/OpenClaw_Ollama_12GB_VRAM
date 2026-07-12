# AVD — lifecycle: move, clone, parallel, wipe, delete

Loaded on demand from `avd-management/SKILL.md`. The contract and safety gates in `android-common.md` apply. All operations here require stopping the exact AVD and verifying locks released first.

## Move, rename, clone, parallel

Use supported commands rather than editing pointer files:

~~~powershell
& $avdmanager move avd --name $oldName --rename $newName
& $avdmanager move avd --name $name --path $newPath
~~~

- Show source/destination names and paths and confirm before acting; verify listings, pointer, content dir, config, and boot afterward.
- Prefer Device Manager Duplicate or a newly created AVD for cloning — never raw-copy an active directory.
- Prefer one uniquely named writable AVD per parallel worker. If current help supports same-AVD `-read-only` instances, allow one writable owner, allocate distinct even ports, and assume read-only changes will not persist.
- Never configure, snapshot, move, wipe, or delete an AVD while any instance uses it.

## Wipe

A cold boot preserves userdata; `-wipe-data` resets installed apps, settings, and writable guest data. Before wiping: map and stop every instance, show the name/path and data-loss effect, offer a safe snapshot/export if useful, confirm, then:

~~~powershell
& $emulator -avd $avdName -wipe-data -no-snapshot-load
~~~

Verify factory-first-boot state. `-wipe-data` does not remove a separate SD-card image.

## Delete

Before deleting: stop the exact AVD and verify no owning process remains, show the exact name/pointer/content dir/image and the irreversible effect, and confirm. Then:

~~~powershell
& $avdmanager delete avd --name $avdName
~~~

Verify absence from `avdmanager list avd` and `emulator -list-avds`. Inspect only the exact former pointer/content paths; if artifacts remain, report them — do not fall back to broad recursive deletion. Uninstall the system image separately only after proving no remaining AVD depends on it and confirming:

~~~powershell
& $sdkmanager "--sdk_root=$sdkRoot" --uninstall $systemImage
~~~

Never recursively delete `%USERPROFILE%\.android`, the SDK root, or a broad parent directory.
