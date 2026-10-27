#import <ApplicationServices/ApplicationServices.h>

BOOL FocusWithoutRaiseAvailable(void);
BOOL FocusWindowWithoutRaise(AXUIElementRef window, AXUIElementRef previousWindow, pid_t pid);
