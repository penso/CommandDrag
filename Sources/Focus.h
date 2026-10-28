#pragma once
#import <ApplicationServices/ApplicationServices.h>

CF_ASSUME_NONNULL_BEGIN

BOOL FocusWithoutRaiseAvailable(void);
BOOL FocusWindowWithoutRaise(AXUIElementRef window, AXUIElementRef _Nullable previousWindow, pid_t pid);

CF_ASSUME_NONNULL_END
