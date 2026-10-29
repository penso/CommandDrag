#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Checks GitHub for a newer release and, if the user agrees, downloads its DMG to ~/Downloads.
@interface Updater : NSObject
- (void)checkForUpdates;
@end

NS_ASSUME_NONNULL_END
