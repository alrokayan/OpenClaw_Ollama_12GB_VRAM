# UIAutomator2 Developer Guide

> **Document ID:** `uiautomator2-developer-guide`  
> **Generated:** 2026-07-10  
> **Status:** Curated developer guide  
> **Primary provenance:** Context7 `/appium/appium-uiautomator2-driver`, Appium documentation, AndroidX UI Automator, and OpenATX distinctions

This guide is written for developers building and operating Android automation, local-AI, emulator, and Windows tooling. Commands are intentionally explicit and favor reproducibility, observability, and reversible changes.

---

## 1. Terminology

“UIAutomator2” can refer to different layers:

- **AndroidX UI Automator**: Android testing APIs for interacting across app and system UI boundaries.
- **Appium UiAutomator2 Driver**: Appium's Android driver, which deploys server components and exposes WebDriver/Appium commands.
- **OpenATX `uiautomator2`**: a Python-oriented Android automation library using its own device-side components and APIs.

Do not mix installation instructions, capabilities, or selectors between these projects.

## 2. When to use semantic UI automation

Use UIAutomator2 when you need:

- selectors by resource ID, text, description, class, or hierarchy;
- waits based on UI state;
- cross-app and system UI interaction;
- test assertions;
- less fragile automation than raw coordinates.

Use visual control when nodes are unavailable or incomplete, and use ADB/scrcpy for transport, media, or low-latency control.

## 3. Appium architecture

```text
Test client
   │ WebDriver/Appium protocol
   ▼
Appium server
   │ UiAutomator2 driver
   ▼
Device-side server components
   │ Android UI Automator / instrumentation
   ▼
Android apps and system UI
```

The Appium server and driver are separate packages. Pin both versions.

## 4. Installation

Install Appium and the driver:

```powershell
npm install -g appium
appium driver install uiautomator2
appium driver list --installed
appium
```

Verify Java, Android SDK, ADB, and device authorization before starting a session.

## 5. Minimal capabilities

Example:

```json
{
  "platformName": "Android",
  "appium:automationName": "UiAutomator2",
  "appium:deviceName": "Android Emulator",
  "appium:udid": "emulator-5554",
  "appium:appPackage": "com.example.app",
  "appium:appActivity": ".MainActivity",
  "appium:noReset": true,
  "appium:newCommandTimeout": 120
}
```

Use the `appium:` namespace for non-standard W3C capabilities. Avoid setting capabilities you do not understand; many change installation, reset, signing, timeout, or server behavior.

## 6. App installation

A session can install an APK from a local path. Appium also exposes mobile commands for installing apps or multiple APK splits.

Separate installation from ordinary UI tests when possible. This reduces session startup variability and makes failures easier to diagnose.

## 7. Locators

Preferred order:

1. stable accessibility ID/content description;
2. stable resource ID;
3. Android UI Automator selector;
4. class plus contextual filtering;
5. XPath only as a last resort.

Examples in a client library vary, but concepts include:

```text
accessibility id: Continue
id: com.example:id/continue
android uiautomator: new UiSelector().text("Continue")
```

Avoid visible text for localized apps unless the test explicitly covers localization.

## 8. Waits

Never use fixed sleeps as the primary synchronization mechanism. Wait for:

- element existence;
- enabled/clickable state;
- activity/package change;
- text change;
- disappearance of loading UI;
- stable window state.

Set a bounded timeout and include the last page source/screenshot in failure artifacts.

## 9. Gestures

Modern Appium drivers expose mobile gesture commands for click, long click, swipe, scroll, drag, and related actions. Prefer driver-supported gestures over legacy touch-action APIs.

Validate:

- element or coordinates;
- screen bounds;
- duration;
- direction and distance;
- scrollable container;
- completion condition.

## 10. Activities and applications

The driver can start activities, activate/terminate apps, query app state, install/remove packages, and execute Android-specific mobile commands.

Use explicit package/activity values and inspect launchable activity data with ADB when uncertain:

```powershell
adb shell cmd package resolve-activity --brief com.example.app
adb shell dumpsys package com.example.app
```

## 11. WebViews

Hybrid apps require context discovery and switching. Requirements may include a compatible browser driver and debuggable WebView. Keep native and WebView selectors separate.

```text
NATIVE_APP
WEBVIEW_com.example.app
```

A missing WebView context may indicate debugging is disabled, version mismatch, or the WebView is not yet created.

## 12. Multi-display and screen streaming

The Appium driver includes Android-specific commands for screen streaming and operations on devices with multiple displays. Multi-display automation requires explicit display awareness; coordinates from one display are invalid on another.

## 13. Page source limitations

The XML source is generated from accessibility/UI Automator data. It may omit:

- pixels rendered into a canvas;
- protected surfaces;
- some WebView internals;
- game UI;
- custom-rendered Flutter content without semantics.

Combine semantic and visual perception when coverage is incomplete.

## 14. Reliability settings

Potential capability families include:

- server launch and installation timeouts;
- ADB command timeout;
- instrumentation startup timeout;
- app wait package/activity;
- reset behavior;
- animation handling;
- hidden API policy handling;
- system port allocation for parallel sessions.

Pin a unique system port per parallel Android session. Do not copy parallel-session configurations without understanding all port conflicts.

## 15. Parallel execution

One Appium session per device is the safest default. For parallel devices:

- unique `udid`;
- unique UiAutomator2 system port;
- unique chromedriver port when applicable;
- separate artifact directories;
- independent app data or AVD snapshots;
- no shared mutable test account unless designed for concurrency.

## 16. OpenATX uiautomator2

OpenATX offers a Python API with direct device connection and selector syntax. A typical workflow conceptually includes:

```python
import uiautomator2 as u2

d = u2.connect("emulator-5554")
d.app_start("com.example.app")
d(resourceId="com.example:id/continue").click()
```

Install and initialization details change by release. Follow the OpenATX repository for its exact device-agent setup. Do not assume an Appium server is required for OpenATX.

## 17. Choosing Appium versus OpenATX

Choose Appium when:

- using WebDriver ecosystem and language clients;
- integrating with test grids and reports;
- testing hybrid apps;
- requiring standardized capabilities and plugins.

Choose OpenATX when:

- Python-first direct device automation is preferred;
- a lightweight scripting API is sufficient;
- Appium infrastructure is unnecessary.

## 18. Agent integration

A model should request semantic actions, not raw driver code:

```json
{
  "action": "click",
  "locator": {
    "strategy": "id",
    "value": "com.example:id/continue"
  },
  "timeoutMs": 10000
}
```

The executor resolves the locator, verifies state, captures evidence, performs the action, and reports the result. Fall back to scrcpy/ADB coordinates only after semantic lookup fails and policy permits it.

## 19. Troubleshooting

### Session creation fails

Check Appium logs, driver installation, Java, SDK variables, ADB state, app path, package/activity, and version compatibility.

### Instrumentation process crashes

Inspect logcat, remove stale server packages if directed by official troubleshooting, and verify device API level and driver support.

### Element not found

Capture page source and screenshot, confirm context, wait for UI stability, and inspect whether the element is accessible.

### Parallel sessions collide

Assign unique ports and device serials.

### App is reinstalled unexpectedly

Review `app`, `noReset`, `fullReset`, and installation-related capabilities.

## 20. Security

Appium and OpenATX can install apps, start services, execute mobile shell commands, and access UI data. Bind servers to trusted interfaces, avoid unauthenticated remote exposure, use disposable devices, and disable high-risk mobile commands when not required.

## 21. Context7 snapshot

See `context7-raw/uiautomator2-context7-snapshot.md` for retrieved Appium UiAutomator2 installation, app-management, activity, service, streaming, and mobile-command examples.
