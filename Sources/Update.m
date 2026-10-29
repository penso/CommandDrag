#import <Cocoa/Cocoa.h>
#import <os/log.h>
#import "Update.h"

static NSString *const LatestReleaseURL = @"https://api.github.com/repos/penso/CommandDrag/releases/latest";
// Only download installers published by this repository's releases.
static NSString *const DownloadPrefix = @"https://github.com/penso/CommandDrag/releases/download/";

static os_log_t Log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("local.commanddrag.app", "update"); });
    return log;
}

static NSModalResponse ShowAlert(NSString *title, NSString *text, NSArray<NSString *> *buttons) {
    // An accessory app's alert would otherwise open behind the frontmost app.
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = text;
    for (NSString *button in buttons) [alert addButtonWithTitle:button];
    return [alert runModal];
}

// JSON values are untyped; return the value only when it has the expected class.
static id _Nullable Typed(id _Nullable value, Class type) {
    return [(NSObject *)value isKindOfClass:type] ? value : nil;
}

static NSString *CurrentVersion(void) {
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] ? version : @"0";
}

@implementation Updater {
    BOOL _busy;
}

- (void)checkForUpdates {
    NSURL *url = [NSURL URLWithString:LatestReleaseURL];
    if (_busy || !url) return;
    _busy = YES;
    NSString *current = CurrentVersion();
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 15;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:[@"CommandDrag/" stringByAppendingString:current] forHTTPHeaderField:@"User-Agent"];
    os_log(Log(), "checking for updates (current %{public}@)", current);
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              dispatch_async(dispatch_get_main_queue(),
                  ^{ [self handleRelease:data response:response error:error current:current]; });
          }];
    [task resume];
}

- (void)handleRelease:(nullable NSData *)data
             response:(nullable NSURLResponse *)response
                error:(nullable NSError *)error
              current:(NSString *)current {
    NSInteger status =
        [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    id json =
        data && status == 200 ? [NSJSONSerialization JSONObjectWithData:(NSData *)data options:0 error:NULL] : nil;
    NSDictionary *release = Typed(json, NSDictionary.class);
    NSString *tag = release[@"tag_name"];
    if (![tag isKindOfClass:NSString.class] || ![tag hasPrefix:@"v"]) {
        NSString *reason = error
            ? error.localizedDescription
            : [NSString stringWithFormat:@"GitHub returned an unexpected response (HTTP %ld).", (long)status];
        os_log_error(Log(), "update check failed: %{public}@", reason);
        _busy = NO;
        ShowAlert(@"Could not check for updates", reason, @[]);
        return;
    }
    NSString *latest = [tag substringFromIndex:1];
    if ([latest compare:current options:NSNumericSearch] != NSOrderedDescending) {
        os_log(Log(), "up to date: latest %{public}@", latest);
        _busy = NO;
        ShowAlert(@"CommandDrag is up to date",
            [NSString stringWithFormat:@"Version %@ is the newest version available.", current], @[]);
        return;
    }
    NSURL *download = nil;
    NSString *name = nil;
    NSArray *assets = Typed(release[@"assets"], NSArray.class) ?: @[];
    for (id item in assets) {
        NSDictionary *asset = Typed(item, NSDictionary.class);
        NSString *assetName = asset[@"name"];
        NSString *assetURL = asset[@"browser_download_url"];
        if ([assetName isKindOfClass:NSString.class] && [assetName hasSuffix:@"-universal.dmg"] &&
            [assetName rangeOfString:@"/"].location == NSNotFound && [assetURL isKindOfClass:NSString.class] &&
            [assetURL hasPrefix:DownloadPrefix]) {
            download = [NSURL URLWithString:assetURL];
            name = assetName;
            break;
        }
    }
    os_log(
        Log(), "update available: %{public}@ -> %{public}@, installer %{public}@", current, latest, name ?: @"missing");
    if (!download || !name) {
        _busy = NO;
        ShowAlert(@"Could not find the installer",
            [NSString stringWithFormat:@"CommandDrag %@ is available, but its release has no DMG download.", latest],
            @[]);
        return;
    }
    NSModalResponse choice = ShowAlert([NSString stringWithFormat:@"CommandDrag %@ is available", latest],
        [NSString stringWithFormat:@"You have version %@. Download the installer to your Downloads folder?", current],
        @[@"Download", @"Later"]);
    if (choice != NSAlertFirstButtonReturn) {
        _busy = NO;
        return;
    }
    [self download:download name:name version:latest];
}

- (void)download:(NSURL *)url name:(NSString *)name version:(NSString *)version {
    os_log(Log(), "downloading %{public}@", url.absoluteString);
    NSURLSessionDownloadTask *task = [NSURLSession.sharedSession
        downloadTaskWithURL:url
          completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
              NSInteger status =
                  [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
              NSError *saveError = error;
              NSURL *saved = nil;
              // The temporary file is deleted when this handler returns, so move it now.
              if (location && status == 200)
                  saved = [self save:(NSURL *)location name:name source:url error:&saveError];
              NSString *reason = saveError
                  ? saveError.localizedDescription
                  : [NSString stringWithFormat:@"The download failed (HTTP %ld).", (long)status];
              dispatch_async(
                  dispatch_get_main_queue(), ^{ [self finishDownload:saved version:version failure:reason]; });
          }];
    [task resume];
}

- (nullable NSURL *)save:(NSURL *)location
                    name:(NSString *)name
                  source:(NSURL *)source
                   error:(NSError *_Nullable __autoreleasing *_Nullable)error {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *folder = [files URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
    if (!folder) return nil;
    NSString *base = name.stringByDeletingPathExtension;
    NSURL *destination = [folder URLByAppendingPathComponent:name];
    // Never overwrite an existing file; pick "Name 2.dmg", "Name 3.dmg", …
    for (NSUInteger copy = 2; [destination checkResourceIsReachableAndReturnError:NULL]; copy++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ %lu.dmg", base, (unsigned long)copy];
        destination = [folder URLByAppendingPathComponent:candidate];
    }
    if (![files moveItemAtURL:location toURL:destination error:error]) return nil;
    // Quarantine the file like a browser download, so Gatekeeper verifies it when opened.
    NSDictionary *quarantine = @{
        (__bridge NSString *)kLSQuarantineAgentNameKey: @"CommandDrag",
        (__bridge NSString *)kLSQuarantineTypeKey: (__bridge NSString *)kLSQuarantineTypeWebDownload,
        (__bridge NSString *)kLSQuarantineDataURLKey: source,
    };
    NSError *quarantineError = nil;
    if (![destination setResourceValue:quarantine forKey:NSURLQuarantinePropertiesKey error:&quarantineError]) {
        os_log_error(Log(), "could not quarantine download: %{public}@", quarantineError.localizedDescription);
    }
    return destination;
}

- (void)finishDownload:(nullable NSURL *)saved version:(NSString *)version failure:(NSString *)failure {
    _busy = NO;
    if (!saved) {
        os_log_error(Log(), "download failed: %{public}@", failure);
        ShowAlert(@"Could not download the update", failure, @[]);
        return;
    }
    os_log(Log(), "downloaded %{public}@", saved.path);
    [NSWorkspace.sharedWorkspace openURL:(NSURL *)saved];
    NSModalResponse choice = ShowAlert([NSString stringWithFormat:@"CommandDrag %@ downloaded", version],
        @"The installer is opening. Quit CommandDrag, drag the new copy onto Applications to replace the old one, "
        @"then reopen it.",
        @[@"Quit CommandDrag", @"Keep Running"]);
    if (choice == NSAlertFirstButtonReturn) [NSApp terminate:nil];
}

@end
