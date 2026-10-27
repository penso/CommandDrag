#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <unistd.h>
#import "Focus.h"

// Private focus protocol used by yabai. See THIRD_PARTY_NOTICES.md.
// Resolve at runtime so moving/resizing still works if macOS removes these APIs.
static AXError (*GetWindowID)(AXUIElementRef, CGWindowID *);
static OSStatus (*GetPSN)(pid_t, ProcessSerialNumber *);
static CGError (*FocusProcess)(ProcessSerialNumber *, uint32_t, uint32_t);
static CGError (*PostEvent)(ProcessSerialNumber *, uint8_t *);

BOOL FocusWithoutRaiseAvailable(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        GetWindowID = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
        GetPSN = dlsym(RTLD_DEFAULT, "GetProcessForPID");
        if (skyLight) {
            FocusProcess = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions");
            PostEvent = dlsym(skyLight, "SLPSPostEventRecordTo");
        }
        // Keep the framework loaded for the lifetime of these function pointers.
    });
    return GetWindowID && GetPSN && FocusProcess && PostEvent;
}

BOOL FocusWindowWithoutRaise(AXUIElementRef window, AXUIElementRef previousWindow, pid_t pid) {
    if (!FocusWithoutRaiseAvailable()) return NO;
    CGWindowID windowID = 0;
    ProcessSerialNumber psn = {0};
    if (GetWindowID(window, &windowID) != kAXErrorSuccess || !windowID || GetPSN(pid, &psn) != noErr) return NO;

    uint8_t record[0xf8] = {0};
    if (previousWindow) {
        CGWindowID previousID = 0;
        if (GetWindowID(previousWindow, &previousID) != kAXErrorSuccess || !previousID) return NO;
        if (previousID == windowID) return YES;
        // Switching between windows in the same app needs explicit deactivate/activate records.
        record[0x04] = sizeof(record);
        record[0x08] = 0x0d;
        record[0x8a] = 0x02;
        memcpy(record + 0x3c, &previousID, sizeof(previousID));
        if (PostEvent(&psn, record) != kCGErrorSuccess) return NO;
        // Some apps need a small gap between these two records (outside the event tap).
        usleep(40000);
        record[0x8a] = 0x01;
        memcpy(record + 0x3c, &windowID, sizeof(windowID));
        if (PostEvent(&psn, record) != kCGErrorSuccess) return NO;
    }
    if (FocusProcess(&psn, windowID, 0x200 /* kCPSUserGenerated */) != kCGErrorSuccess) return NO;

    memset(record, 0, sizeof(record));
    record[0x04] = sizeof(record);
    record[0x3a] = 0x10;
    memcpy(record + 0x3c, &windowID, sizeof(windowID));
    memset(record + 0x20, 0xff, 0x10);
    record[0x08] = 0x01;
    CGError down = PostEvent(&psn, record);
    record[0x08] = 0x02;
    CGError up = PostEvent(&psn, record);
    return down == kCGErrorSuccess && up == kCGErrorSuccess;
}
