# AVD — select and install a system image

Loaded on demand from `avd-management/SKILL.md`. The contract and safety gates in `android-common.md` apply.

## Choose an image

Derive requirements from the user's app/test:

- API level at least the app's `minSdk`; exact API levels for compatibility testing
- AOSP/default for minimal Android; Google APIs when Google libraries/services are needed; Play Store image only when Play Store behavior is required
- host-compatible ABI, normally `x86_64` on an x64 Windows host

Play Store images are release-signed and intentionally restrict root — do not pick an image to bypass security. Use an exact package ID returned by the same SDK root and stable channel; do not assume the newest API/tag/page-size/ABI exists. Preview/canary images require an explicit reason and channel choice.

~~~text
system-images;android-<api>;<tag>;<abi>
~~~

## Install

1. Check download size, install location, and free disk first.
2. Confirm the exact packages and licenses. Install only what the task needs:

   ~~~powershell
   & $sdkmanager "--sdk_root=$sdkRoot" 'platform-tools' 'emulator' $systemImage
   ~~~

3. Avoid routine `sdkmanager --update` — broad updates can change emulator behavior and invalidate snapshots.
4. Run `& $sdkmanager "--sdk_root=$sdkRoot" --licenses` interactively only after confirmation. Do not pipe automatic acceptance. For CI, require licenses pre-provisioned under the organization's policy.
5. Re-run `--list_installed` and verify the exact image directory and package metadata before creating an AVD.
