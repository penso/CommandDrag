# CommandDrag

A small Objective-C menu bar app for macOS 13 or later. No dependencies beyond Apple's frameworks. It uses public Accessibility and Quartz event-tap APIs; it does not disable SIP or inject code into other apps.

## Build and install

On your Mac, install Apple's command line tools if needed:

```sh
xcode-select --install
```

From this directory:

```sh
bash build.sh
ditto build/CommandDrag.app /Applications/CommandDrag.app
open /Applications/CommandDrag.app
```

The app appears as **↔** in the menu bar, without a Dock icon. Keep it in `/Applications` before granting permissions or enabling launch at login.

1. Grant **CommandDrag** access in **System Settings → Privacy & Security → Accessibility**. The app opens this pane on first launch.
2. If the menu still reports a permission problem, use **Open Input Monitoring…**, enable CommandDrag there, and quit and reopen it. macOS permission behavior varies by version; an active event tap may work with Accessibility permission alone.
3. The menu should say **Ready**. Turn on **Launch at Login** if desired; approve it in System Settings if macOS asks.

## Gestures

| Gesture | Behavior |
| --- | --- |
| Hold Command, then left-drag a window | Move from anywhere in its accessible content |
| Hold Command, then right-drag a window | Resize by moving its bottom-right corner |
| Release the mouse button | End the gesture, even if Command was released first |

The top-left corner stays fixed during resize. Drag right/down to grow and left/up to shrink. Standard windows honor their application's size constraints; the app also requests a minimum of 120 × 80 points.

Use **Modifier** to switch to Option or Control. The preference persists. Press only the selected modifier: additional Command/Option/Control/Shift keys bypass the gesture. Ordinary clicks pass through when the modifier is absent, the app is paused, or the target window does not advertise the required capability. An accepted gesture consumes the click, so it doesn't activate links, select text, or open a context menu. Background windows can be manipulated without activating their app.

## Implementation

A single Objective-C source file handles the menu bar and mouse gestures. The event tap listens only for left/right button presses, drags, and releases; ordinary mouse movement does no work. Window lookup happens once per gesture, and subsequent drag events update that window directly through Accessibility. Accessibility calls use a short timeout, and a failed update cancels window manipulation while still consuming the remainder of the gesture. A low-frequency, coalescible timer checks permissions; the menu is rebuilt only when needed.

## Limitations and permissions

- Some apps do not expose accessible windows or support setting their position/size. Full-screen windows are skipped. Secure system UI and locked sessions are outside the app's control.
- The selected modifier's normal click behavior is replaced over supported windows. Pause from the menu when you need that behavior, or select a different modifier.
- Rebuilding an ad-hoc signed app can invalidate its Accessibility approval. If it stops working after an update, quit it, remove its entry in Privacy & Security, add the installed copy again, and reopen it.
- Launch at login uses `SMAppService` (macOS 13+). Disable it before moving or deleting the app.
- The app receives global mouse events to recognize gestures. It has no network, analytics, or event logging code.

The default build is locally ad-hoc signed. For distribution, use a Developer ID identity (`SIGN_IDENTITY="Developer ID Application: …" bash build.sh`) and Apple's notarization process. This source package is not a notarized binary.

## Verification on macOS

Build with `bash build.sh` (compiler warnings are treated as errors). To check the bundle and its signature:

```sh
plutil -lint Sources/Info.plist
codesign --verify --strict --verbose=2 build/CommandDrag.app
```

Interactive checks after installing and granting Accessibility permission:

1. Move a Finder and TextEdit window by dragging in their content while holding Command. Verify ordinary clicks and text selection still work without it.
2. Command-right-drag in the center of each window. Verify the top-left stays fixed, app minimum sizes are respected, and no context menu appears. Right-click without Command should still open the normal menu.
3. Release Command before the mouse button during each gesture. Verify dragging ends on mouse-up and subsequent clicks work normally.
4. Try a background window and a window on another display, including one above or left of the main display.
5. Verify full-screen windows are ignored. Confirm unsupported resize operations pass through.
6. Pause/resume; switch modifiers; quit/reopen to check the saved selection.
7. Enable launch at login, sign out/in, and check the app returns. Disable it and verify the setting clears.
8. Revoke Accessibility access and verify the permission status updates; restore it and relaunch if needed.

## Files

- `Sources/main.m`: menu, preferences, permissions, login item, hit-testing, and mouse handling.
- `Sources/Info.plist`: app bundle metadata.
- `build.sh`: compile and sign a local app bundle.

To remove: disable Launch at Login, quit CommandDrag, delete `/Applications/CommandDrag.app`, and remove its Privacy & Security entries.
