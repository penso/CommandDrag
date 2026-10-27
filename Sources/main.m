#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>
#import <math.h>

@interface AppDelegate : NSObject <NSApplicationDelegate> {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _tapSource;
    AXUIElementRef _window;
    CGPoint _mouseStart;
    CGPoint _windowStart;
    CGSize _sizeStart;
    BOOL _resizing;
    BOOL _dragging;
    BOOL _enabled;
    BOOL _trusted;
    CGEventFlags _modifier;
}
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSTimer *permissionTimer;
- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type;
@end

static CGEventRef EventCallback(CGEventTapProxy proxy, CGEventType type,
                                CGEventRef event, void *context) {
    (void)proxy;
    return [(__bridge AppDelegate *)context handleEvent:event type:type];
}

static BOOL ReadAXValue(AXUIElementRef element, CFStringRef attribute,
                        AXValueType type, void *result) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value)
        return NO;
    BOOL valid = CFGetTypeID(value) == AXValueGetTypeID() &&
        AXValueGetType((AXValueRef)value) == type &&
        AXValueGetValue((AXValueRef)value, type, result);
    CFRelease(value);
    return valid;
}

static BOOL WriteAXValue(AXUIElementRef element, CFStringRef attribute,
                         AXValueType type, const void *value) {
    AXValueRef wrapped = AXValueCreate(type, value);
    if (!wrapped) return NO;
    AXError error = AXUIElementSetAttributeValue(element, attribute, wrapped);
    CFRelease(wrapped);
    return error == kAXErrorSuccess;
}

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _enabled = YES;
    _trusted = AXIsProcessTrusted();
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"modifier"];
    _modifier = saved ? saved.unsignedLongLongValue : kCGEventFlagMaskCommand;
    if (_modifier != kCGEventFlagMaskCommand && _modifier != kCGEventFlagMaskAlternate &&
        _modifier != kCGEventFlagMaskControl) _modifier = kCGEventFlagMaskCommand;
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"↔";
    self.statusItem.button.toolTip = @"CommandDrag — modifier + left drag to move, right drag to resize";
    [self rebuildMenu];
    [self startTap];
    self.permissionTimer = [NSTimer scheduledTimerWithTimeInterval:2 target:self
        selector:@selector(checkPermissions:) userInfo:nil repeats:YES];
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
    NSString *state = !AXIsProcessTrusted() ? @"Needs Accessibility permission" :
        (!_tap ? @"Needs Input Monitoring permission" : (_enabled ? @"Ready" : @"Paused"));
    NSMenuItem *status = [self item:state action:NULL];
    status.enabled = NO;
    [menu addItem:status];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self item:(_enabled ? @"Pause" : @"Resume") action:@selector(toggleEnabled:)]];
    NSMenuItem *modifierItem = [self item:@"Modifier" action:NULL];
    NSMenu *modifiers = [[NSMenu alloc] init];
    NSArray<NSString *> *names = @[@"Command ⌘", @"Option ⌥", @"Control ⌃"];
    NSArray<NSNumber *> *values = @[@(kCGEventFlagMaskCommand), @(kCGEventFlagMaskAlternate), @(kCGEventFlagMaskControl)];
    for (NSUInteger i = 0; i < names.count; i++) {
        NSMenuItem *item = [self item:names[i] action:@selector(changeModifier:)];
        item.representedObject = values[i];
        item.state = (_modifier == values[i].unsignedLongLongValue) ? NSControlStateValueOn : NSControlStateValueOff;
        [modifiers addItem:item];
    }
    modifierItem.submenu = modifiers;
    [menu addItem:modifierItem];
    NSMenuItem *login = [self item:@"Launch at Login" action:@selector(toggleLogin:)];
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:login];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self item:@"Grant Accessibility…" action:@selector(requestAccessibility:)]];
    [menu addItem:[self item:@"Open Input Monitoring…" action:@selector(openInputMonitoring:)]];
    [menu addItem:[self item:@"Quit CommandDrag" action:@selector(quit:)]];
    self.statusItem.menu = menu;
}

- (void)startTap {
    if (_tap || !AXIsProcessTrusted()) return;
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventRightMouseDragged);
    _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, mask, EventCallback, (__bridge void *)self);
    if (_tap) {
        _tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes);
        CGEventTapEnable(_tap, true);
    }
    [self rebuildMenu];
}

- (void)checkPermissions:(NSTimer *)timer {
    (void)timer;
    BOOL trusted = AXIsProcessTrusted();
    BOOL changed = trusted != _trusted;
    _trusted = trusted;
    if (!_tap) [self startTap];
    if (!trusted) [self finishDrag];
    if (changed) [self rebuildMenu];
}

- (void)finishDrag {
    if (_window) { CFRelease(_window); _window = NULL; }
}

- (AXUIElementRef)copyWindowAtPoint:(CGPoint)point {
    AXUIElementRef system = AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(system, 0.05f);
    AXUIElementRef hit = NULL;
    AXError error = AXUIElementCopyElementAtPosition(system, point.x, point.y, &hit);
    CFRelease(system);
    if (error != kAXErrorSuccess || !hit) return NULL;
    AXUIElementSetMessagingTimeout(hit, 0.05f);
    CFTypeRef role = NULL;
    AXUIElementCopyAttributeValue(hit, kAXRoleAttribute, &role);
    BOOL isWindow = role && CFEqual(role, kAXWindowRole);
    if (role) CFRelease(role);
    if (isWindow) return hit;
    CFTypeRef window = NULL;
    AXUIElementCopyAttributeValue(hit, kAXWindowAttribute, &window);
    CFRelease(hit);
    if (window && CFGetTypeID(window) != AXUIElementGetTypeID()) {
        CFRelease(window);
        return NULL;
    }
    return (AXUIElementRef)window;
}

- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [self finishDrag];
        if (_tap) CGEventTapEnable(_tap, true);
        return event;
    }
    BOOL down = type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown;
    BOOL up = type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp;
    BOOL right = type == kCGEventRightMouseDown || type == kCGEventRightMouseDragged || type == kCGEventRightMouseUp;
    CGPoint point = CGEventGetLocation(event); // AX and CG both use global, top-left coordinates.
    // A fresh down means the previous up was lost while the tap was disabled.
    if (_dragging && right == _resizing && down && !_window) _dragging = NO;
    if (_dragging) {
        if (right != _resizing) return event;
        if (up) { [self finishDrag]; _dragging = NO; return NULL; }
        if (down) return NULL;
        // Continue swallowing a canceled gesture until its matching mouse-up.
        if (!_window) return NULL;
        CGFloat dx = point.x - _mouseStart.x, dy = point.y - _mouseStart.y;
        if (_resizing) {
            CGSize size = CGSizeMake(fmax(120, _sizeStart.width + dx), fmax(80, _sizeStart.height + dy));
            if (!WriteAXValue(_window, kAXSizeAttribute, kAXValueCGSizeType, &size)) [self finishDrag];
        } else {
            CGPoint position = CGPointMake(_windowStart.x + dx, _windowStart.y + dy);
            if (!WriteAXValue(_window, kAXPositionAttribute, kAXValueCGPointType, &position)) [self finishDrag];
        }
        return NULL;
    }
    CGEventFlags relevant = kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate |
        kCGEventFlagMaskControl | kCGEventFlagMaskShift;
    if (!_enabled || !down || (CGEventGetFlags(event) & relevant) != _modifier) return event;
    AXUIElementRef window = [self copyWindowAtPoint:point];
    if (!window) return event;
    AXUIElementSetMessagingTimeout(window, 0.05f);
    CFTypeRef fullscreen = NULL;
    AXUIElementCopyAttributeValue(window, CFSTR("AXFullScreen"), &fullscreen);
    BOOL isFullscreen = fullscreen && CFEqual(fullscreen, kCFBooleanTrue);
    if (fullscreen) CFRelease(fullscreen);
    Boolean settable = false;
    AXUIElementIsAttributeSettable(window, right ? kAXSizeAttribute : kAXPositionAttribute, &settable);
    CGPoint position;
    CGSize size;
    if (isFullscreen || !settable ||
        !ReadAXValue(window, kAXPositionAttribute, kAXValueCGPointType, &position) ||
        !ReadAXValue(window, kAXSizeAttribute, kAXValueCGSizeType, &size)) {
        CFRelease(window);
        return event;
    }
    _window = window;
    _windowStart = position;
    _sizeStart = size;
    _mouseStart = point;
    _resizing = right;
    _dragging = YES;
    // Do not activate the app: the gesture also works on background windows.
    return NULL;
}

- (void)toggleEnabled:(id)sender {
    (void)sender;
    _enabled = !_enabled;
    // Keep an active gesture until mouse-up so its swallowed down has a swallowed up.
    [self rebuildMenu];
}
- (void)changeModifier:(NSMenuItem *)sender {
    _modifier = [sender.representedObject unsignedLongLongValue];
    [[NSUserDefaults standardUserDefaults] setObject:@(_modifier) forKey:@"modifier"];
    [self rebuildMenu];
}
- (void)requestAccessibility:(id)sender {
    (void)sender;
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
- (void)openInputMonitoring:(id)sender {
    (void)sender;
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
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
- (void)quit:(id)sender { (void)sender; [NSApp terminate:nil]; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.permissionTimer invalidate];
    [self finishDrag];
    if (_tap) CGEventTapEnable(_tap, false);
    if (_tapSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes);
        CFRelease(_tapSource);
    }
    if (_tap) { CFMachPortInvalidate(_tap); CFRelease(_tap); }
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
