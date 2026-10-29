#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>
#import <math.h>
#import <os/log.h>
#import "Focus.h"

@interface AppDelegate : NSObject <NSApplicationDelegate> {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _tapSource;
    AXUIElementRef _window;
    CGPoint _mouseStart;
    CGPoint _windowStart;
    CGSize _sizeStart;
    BOOL _resizing;
    NSInteger _resizeX; // -1: left, 0: unchanged, 1: right
    NSInteger _resizeY; // -1: top, 0: unchanged, 1: bottom
    BOOL _dragging;
    BOOL _enabled;
    BOOL _trusted;
    BOOL _focusFollowsMouse;
    CGPoint _hoverPoint;
    CGEventFlags _modifier;
}
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSTimer *permissionTimer;
@property(nonatomic, strong) NSTimer *hoverTimer;
- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type;
@end

// Keep Accessibility calls short: they can run while the event tap is waiting.
static const float AXTimeout = 0.05f;
static const CGEventFlags ModifierMask =
    kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl | kCGEventFlagMaskShift;

// Stream with: log stream --level debug --predicate 'subsystem == "local.commanddrag.app"'
// Debug messages stay in memory unless streamed; nothing is persisted by default.
static os_log_t Log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("local.commanddrag.app", "gesture"); });
    return log;
}

static NSString *DescribeApp(AXUIElementRef element) {
    pid_t pid = 0;
    if (AXUIElementGetPid(element, &pid) != kAXErrorSuccess) return @"unknown app";
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return [NSString stringWithFormat:@"%@ (pid %d)", app.bundleIdentifier ?: app.localizedName ?: @"?", pid];
}

static CGEventRef EventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy;
    return [(__bridge AppDelegate *)context handleEvent:event type:type];
}

static BOOL ReadAXValue(AXUIElementRef element, CFStringRef attribute, AXValueType type, void *result) {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess || !value) {
        os_log_debug(Log(), "read %{public}@ failed: AXError %d", (__bridge NSString *)attribute, (int)error);
        return NO;
    }
    BOOL valid = CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType((AXValueRef)value) == type &&
        AXValueGetValue((AXValueRef)value, type, result);
    CFRelease(value);
    return valid;
}

static void OpenPrivacySettings(NSString *pane) {
    NSString *string = [@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:pane];
    NSURL *url = [NSURL URLWithString:string];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

static BOOL WriteAXValue(AXUIElementRef element, CFStringRef attribute, AXValueType type, const void *value) {
    AXValueRef wrapped = AXValueCreate(type, value);
    if (!wrapped) return NO;
    AXError error = AXUIElementSetAttributeValue(element, attribute, wrapped);
    CFRelease(wrapped);
    if (error != kAXErrorSuccess) {
        os_log_error(Log(), "write %{public}@ failed: AXError %d", (__bridge NSString *)attribute, (int)error);
    }
    return error == kAXErrorSuccess;
}

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _enabled = YES;
    _trusted = AXIsProcessTrusted() ? YES : NO;
    _focusFollowsMouse = [[NSUserDefaults standardUserDefaults] boolForKey:@"focusFollowsMouse"];
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"modifier"];
    _modifier = saved ? (CGEventFlags)saved.unsignedLongLongValue : kCGEventFlagMaskCommand;
    if (_modifier != kCGEventFlagMaskCommand && _modifier != kCGEventFlagMaskAlternate &&
        _modifier != kCGEventFlagMaskControl) {
        _modifier = kCGEventFlagMaskCommand;
    }
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"↔";
    self.statusItem.button.toolTip = @"CommandDrag — modifier + left drag to move, right drag to resize";
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    os_log(Log(),
        "launch: version %{public}@ (%{public}@), path %{public}@, trusted %d, modifier 0x%llx, "
        "focusFollowsMouse %d, focusAvailable %d",
        info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"], NSBundle.mainBundle.bundlePath, _trusted,
        (unsigned long long)_modifier, _focusFollowsMouse, FocusWithoutRaiseAvailable());
    [self rebuildMenu];
    [self startTap];
    self.permissionTimer = [NSTimer scheduledTimerWithTimeInterval:2
                                                            target:self
                                                          selector:@selector(checkPermissions:)
                                                          userInfo:nil
                                                           repeats:YES];
    self.permissionTimer.tolerance = 1;
    if (!AXIsProcessTrusted()) [self requestAccessibility:nil];
}

- (NSMenuItem *)item:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    NSString *state = !AXIsProcessTrusted()
        ? @"Needs Accessibility permission"
        : (!_tap ? @"Needs Input Monitoring permission" : (_enabled ? @"Ready" : @"Paused"));
    NSMenuItem *status = [self item:state action:NULL];
    status.enabled = NO;
    [menu addItem:status];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self item:(_enabled ? @"Pause" : @"Resume") action:@selector(toggleEnabled:)]];
    BOOL canFocus = FocusWithoutRaiseAvailable();
    NSMenuItem *hover = [self item:(canFocus ? @"Focus Follows Mouse (Without Raising)" : @"Hover Focus Unavailable")
                            action:(canFocus ? @selector(toggleFocusFollowsMouse:) : NULL)];
    hover.enabled = canFocus;
    hover.state = _focusFollowsMouse ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:hover];
    NSMenuItem *modifierItem = [self item:@"Modifier" action:NULL];
    NSMenu *modifiers = [[NSMenu alloc] init];
    NSArray<NSString *> *names = @[@"Command ⌘", @"Option ⌥", @"Control ⌃"];
    NSArray<NSNumber *> *values =
        @[@(kCGEventFlagMaskCommand), @(kCGEventFlagMaskAlternate), @(kCGEventFlagMaskControl)];
    for (NSUInteger i = 0; i < names.count; i++) {
        NSMenuItem *item = [self item:names[i] action:@selector(changeModifier:)];
        item.representedObject = values[i];
        item.state = _modifier == values[i].unsignedLongLongValue ? NSControlStateValueOn : NSControlStateValueOff;
        [modifiers addItem:item];
    }
    modifierItem.submenu = modifiers;
    [menu addItem:modifierItem];
    NSMenuItem *login = [self item:@"Launch at Login" action:@selector(toggleLogin:)];
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn
                                                                                  : NSControlStateValueOff;
    [menu addItem:login];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self item:@"Grant Accessibility…" action:@selector(requestAccessibility:)]];
    [menu addItem:[self item:@"Open Input Monitoring…" action:@selector(openInputMonitoring:)]];
    [menu addItem:[self item:@"Quit CommandDrag" action:@selector(quit:)]];
    self.statusItem.menu = menu;
}

- (void)startTap {
    if (_tap) return;
    if (!AXIsProcessTrusted()) {
        os_log_debug(Log(), "event tap not started: Accessibility permission missing");
        return;
    }
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventMouseMoved);
    _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, EventCallback,
        (__bridge void *)self);
    if (_tap) {
        _tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes);
        CGEventTapEnable(_tap, true);
        os_log(Log(), "event tap started");
    } else {
        os_log_error(Log(), "event tap creation failed: check Input Monitoring permission");
    }
    [self rebuildMenu];
}

- (void)checkPermissions:(NSTimer *)timer {
    (void)timer;
    BOOL trusted = AXIsProcessTrusted() ? YES : NO;
    BOOL changed = trusted != _trusted;
    _trusted = trusted;
    if (changed) os_log(Log(), "Accessibility permission %{public}s", trusted ? "granted" : "revoked");
    if (!_tap) [self startTap];
    if (!trusted) [self finishDrag];
    if (changed) [self rebuildMenu];
}

- (void)finishDrag {
    if (_window) {
        CFRelease(_window);
        _window = NULL;
    }
}

- (void)cancelHover {
    [self.hoverTimer invalidate];
    self.hoverTimer = nil;
}

- (void)focusHoveredWindow:(NSTimer *)timer {
    (void)timer;
    self.hoverTimer = nil;
    if (!_enabled || !_focusFollowsMouse || _dragging || !FocusWithoutRaiseAvailable() || !AXIsProcessTrusted()) return;
    if (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & ModifierMask) return;
    // Never switch focus during another app's selection, resize, or drag-and-drop.
    // CGMouseButton only names buttons 0-2, but Quartz tracks all 32.
    for (uint32_t button = 0; button < 32; button++) {
        // NOLINTNEXTLINE(clang-analyzer-optin.core.EnumCastOutOfRange)
        if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, (CGMouseButton)button)) return;
    }
    AXUIElementRef window = [self copyWindowAtPoint:_hoverPoint];
    if (!window) return;
    AXUIElementSetMessagingTimeout(window, AXTimeout);
    CFTypeRef subrole = NULL;
    AXUIElementCopyAttributeValue(window, kAXSubroleAttribute, &subrole);
    BOOL supported = subrole && (CFEqual(subrole, kAXStandardWindowSubrole) || CFEqual(subrole, kAXDialogSubrole));
    if (subrole) CFRelease(subrole);
    pid_t pid = 0;
    AXUIElementGetPid(window, &pid);
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (supported && app && app.processIdentifier != NSProcessInfo.processInfo.processIdentifier &&
        app.activationPolicy == NSApplicationActivationPolicyRegular) {
        AXUIElementRef application = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(application, AXTimeout);
        CFTypeRef focused = NULL;
        AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute, &focused);
        BOOL alreadyFocused = app.active && focused && CFEqual(focused, window);
        if (!alreadyFocused) {
            AXUIElementRef previous = app.active && focused && CFGetTypeID(focused) == AXUIElementGetTypeID()
                ? (AXUIElementRef)focused
                : NULL;
            FocusWindowWithoutRaise(window, previous, pid);
        }
        if (focused) CFRelease(focused);
        CFRelease(application);
    }
    CFRelease(window);
}

- (AXUIElementRef)copyWindowAtPoint:(CGPoint)point {
    AXUIElementRef system = AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(system, AXTimeout);
    AXUIElementRef hit = NULL;
    AXError error = AXUIElementCopyElementAtPosition(system, (float)point.x, (float)point.y, &hit);
    CFRelease(system);
    if (error != kAXErrorSuccess || !hit) {
        os_log_debug(Log(), "no element at (%.0f, %.0f): AXError %d", point.x, point.y, (int)error);
        return NULL;
    }
    AXUIElementSetMessagingTimeout(hit, AXTimeout);
    CFTypeRef role = NULL;
    AXUIElementCopyAttributeValue(hit, kAXRoleAttribute, &role);
    BOOL isWindow = role && CFEqual(role, kAXWindowRole);
    os_log_debug(Log(), "element at (%.0f, %.0f): role %{public}@ in %{public}@", point.x, point.y,
        role ? (__bridge NSString *)role : @"none", DescribeApp(hit));
    if (role) CFRelease(role);
    if (isWindow) return hit;
    CFTypeRef window = NULL;
    error = AXUIElementCopyAttributeValue(hit, kAXWindowAttribute, &window);
    CFRelease(hit);
    if (!window) os_log_debug(Log(), "element has no AXWindow: AXError %d", (int)error);
    if (window && CFGetTypeID(window) != AXUIElementGetTypeID()) {
        CFRelease(window);
        return NULL;
    }
    return (AXUIElementRef)window;
}

- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        os_log_error(Log(), "event tap disabled by %{public}s; re-enabling",
            type == kCGEventTapDisabledByTimeout ? "timeout" : "user input");
        [self cancelHover];
        [self finishDrag];
        if (_tap) CGEventTapEnable(_tap, true);
        return event;
    }
    if (type == kCGEventMouseMoved) {
        if (_enabled && _focusFollowsMouse && FocusWithoutRaiseAvailable() && !_dragging &&
            !(CGEventGetFlags(event) & ModifierMask)) {
            _hoverPoint = CGEventGetLocation(event);
            // Debounce movement without doing Accessibility work inside the event tap.
            if (self.hoverTimer) {
                self.hoverTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:0.18];
            } else {
                self.hoverTimer = [NSTimer scheduledTimerWithTimeInterval:0.18
                                                                   target:self
                                                                 selector:@selector(focusHoveredWindow:)
                                                                 userInfo:nil
                                                                  repeats:NO];
            }
        } else {
            [self cancelHover];
        }
        return event;
    }
    [self cancelHover];
    BOOL down = type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown;
    BOOL up = type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp;
    BOOL right = type == kCGEventRightMouseDown || type == kCGEventRightMouseDragged || type == kCGEventRightMouseUp;
    CGPoint point = CGEventGetLocation(event); // AX and CG both use global, top-left coordinates.
    // A fresh down means the previous up was lost while the tap was disabled.
    if (_dragging && right == _resizing && down && !_window) {
        os_log_debug(Log(), "dropping stale gesture: its mouse-up was lost");
        _dragging = NO;
    }
    if (_dragging) {
        if (right != _resizing) return event;
        if (up) {
            os_log_debug(Log(), "%{public}s ended", _resizing ? "resize" : "move");
            [self finishDrag];
            _dragging = NO;
            return NULL;
        }
        if (down) return NULL;
        // Continue swallowing a canceled gesture until its matching mouse-up.
        if (!_window) return NULL;
        CGFloat dx = point.x - _mouseStart.x, dy = point.y - _mouseStart.y;
        if (_resizing) {
            CGSize size = CGSizeMake(_resizeX ? fmax(120, _sizeStart.width + (CGFloat)_resizeX * dx) : _sizeStart.width,
                _resizeY ? fmax(80, _sizeStart.height + (CGFloat)_resizeY * dy) : _sizeStart.height);
            if (!WriteAXValue(_window, kAXSizeAttribute, kAXValueTypeCGSize, &size)) {
                [self finishDrag];
                return NULL;
            }
            if (_resizeX < 0 || _resizeY < 0) {
                // Read back the app's constrained size before anchoring the opposite edges.
                if (!ReadAXValue(_window, kAXSizeAttribute, kAXValueTypeCGSize, &size)) {
                    [self finishDrag];
                    return NULL;
                }
                CGPoint position = _windowStart;
                if (_resizeX < 0) position.x += _sizeStart.width - size.width;
                if (_resizeY < 0) position.y += _sizeStart.height - size.height;
                if (!WriteAXValue(_window, kAXPositionAttribute, kAXValueTypeCGPoint, &position)) [self finishDrag];
            }
        } else {
            CGPoint position = CGPointMake(_windowStart.x + dx, _windowStart.y + dy);
            if (!WriteAXValue(_window, kAXPositionAttribute, kAXValueTypeCGPoint, &position)) [self finishDrag];
        }
        return NULL;
    }
    if (!down) return event;
    CGEventFlags flags = CGEventGetFlags(event);
    os_log_debug(Log(), "%{public}s mouse down at (%.0f, %.0f): flags 0x%llx, modifiers 0x%llx, expected 0x%llx",
        right ? "right" : "left", point.x, point.y, (unsigned long long)flags,
        (unsigned long long)(flags & ModifierMask), (unsigned long long)_modifier);
    if (!_enabled) {
        os_log_debug(Log(), "ignored: paused");
        return event;
    }
    if ((flags & ModifierMask) != _modifier) return event;
    AXUIElementRef window = [self copyWindowAtPoint:point];
    if (!window) {
        os_log(Log(), "ignored: no Accessibility window under the pointer");
        return event;
    }
    AXUIElementSetMessagingTimeout(window, AXTimeout);
    CFTypeRef fullscreen = NULL;
    AXUIElementCopyAttributeValue(window, CFSTR("AXFullScreen"), &fullscreen);
    BOOL isFullscreen = fullscreen && CFEqual(fullscreen, kCFBooleanTrue);
    if (fullscreen) CFRelease(fullscreen);
    Boolean settable = false;
    AXUIElementIsAttributeSettable(window, right ? kAXSizeAttribute : kAXPositionAttribute, &settable);
    CGPoint position;
    CGSize size;
    if (isFullscreen || !settable || !ReadAXValue(window, kAXPositionAttribute, kAXValueTypeCGPoint, &position) ||
        !ReadAXValue(window, kAXSizeAttribute, kAXValueTypeCGSize, &size)) {
        // When neither flag explains it, reading the window frame failed.
        os_log(Log(), "ignored window in %{public}@: fullscreen %d, %{public}s settable %d", DescribeApp(window),
            isFullscreen, right ? "size" : "position", settable);
        CFRelease(window);
        return event;
    }
    if (right) {
        CGFloat x = point.x - position.x, y = point.y - position.y;
        // Outer thirds select corners/sides. In the center, select the nearest border.
        _resizeX = x < size.width / 3 ? -1 : (x > size.width * 2 / 3 ? 1 : 0);
        _resizeY = y < size.height / 3 ? -1 : (y > size.height * 2 / 3 ? 1 : 0);
        if (!_resizeX && !_resizeY) {
            if (fmin(x, size.width - x) <= fmin(y, size.height - y)) _resizeX = x <= size.width / 2 ? -1 : 1;
            else _resizeY = y <= size.height / 2 ? -1 : 1;
        }
        if (_resizeX < 0 || _resizeY < 0) {
            Boolean movable = false;
            AXUIElementIsAttributeSettable(window, kAXPositionAttribute, &movable);
            if (!movable) {
                os_log(Log(), "ignored resize in %{public}@: position not settable", DescribeApp(window));
                CFRelease(window);
                return event;
            }
        }
    }
    _window = window;
    _windowStart = position;
    _sizeStart = size;
    _mouseStart = point;
    _resizing = right;
    _dragging = YES;
    os_log(Log(), "%{public}s started in %{public}@: frame (%.0f, %.0f, %.0f x %.0f)", right ? "resize" : "move",
        DescribeApp(window), position.x, position.y, size.width, size.height);
    // Do not activate the app: the gesture also works on background windows.
    return NULL;
}

- (void)toggleEnabled:(id)sender {
    (void)sender;
    _enabled = !_enabled;
    [self cancelHover];
    // Keep an active gesture until mouse-up so its swallowed down has a swallowed up.
    [self rebuildMenu];
}
- (void)toggleFocusFollowsMouse:(id)sender {
    (void)sender;
    _focusFollowsMouse = !_focusFollowsMouse;
    [[NSUserDefaults standardUserDefaults] setBool:_focusFollowsMouse forKey:@"focusFollowsMouse"];
    [self cancelHover];
    [self rebuildMenu];
}
- (void)changeModifier:(NSMenuItem *)sender {
    NSNumber *modifier = sender.representedObject;
    _modifier = (CGEventFlags)modifier.unsignedLongLongValue;
    [[NSUserDefaults standardUserDefaults] setObject:@(_modifier) forKey:@"modifier"];
    [self rebuildMenu];
}
- (void)requestAccessibility:(id)sender {
    (void)sender;
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    OpenPrivacySettings(@"Privacy_Accessibility");
}
- (void)openInputMonitoring:(id)sender {
    (void)sender;
    OpenPrivacySettings(@"Privacy_ListenEvent");
}
- (void)toggleLogin:(id)sender {
    (void)sender;
    NSError *error = nil;
    SMAppService *service = SMAppService.mainAppService;
    if (service.status == SMAppServiceStatusEnabled) [service unregisterAndReturnError:&error];
    else if (service.status == SMAppServiceStatusRequiresApproval) [SMAppService openSystemSettingsLoginItems];
    else [service registerAndReturnError:&error];
    if (error) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Could not change launch at login";
        alert.informativeText = error.localizedDescription;
        [alert runModal];
    } else if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
    }
    [self rebuildMenu];
}
- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.permissionTimer invalidate];
    [self cancelHover];
    [self finishDrag];
    if (_tap) CGEventTapEnable(_tap, false);
    if (_tapSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes);
        CFRelease(_tapSource);
    }
    if (_tap) {
        CFMachPortInvalidate(_tap);
        CFRelease(_tap);
    }
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __attribute__((objc_precise_lifetime)) AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
