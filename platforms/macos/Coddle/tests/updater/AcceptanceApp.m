#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

// An isolated executable used only by acceptance.py. It has no Coddle code,
// production defaults, helper, or power-management APIs.
static void Record(NSString *event, NSDictionary *details) {
    NSMutableDictionary *entry = [details mutableCopy] ?: [NSMutableDictionary dictionary];
    entry[@"event"] = event;
    entry[@"version"] = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"];
    entry[@"pid"] = @(getpid());
    NSString *path = NSBundle.mainBundle.infoDictionary[@"AcceptanceEvidence"];
    NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    [file seekToEndOfFile]; [file writeData:json]; [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [file closeFile];
}

@interface AcceptanceDriver : NSObject <SPUUserDriver>
@end
@implementation AcceptanceDriver
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { Record(@"checking", nil); }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    Record(@"found", @{@"target": item.versionString}); reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    Record(@"not-found", @{@"code": @(error.code)}); acknowledgement(); exit(2);
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    Record(@"error", @{@"domain": error.domain, @"code": @(error.code), @"description": error.localizedDescription,
        @"underlying": underlying.localizedDescription ?: @""});
    acknowledgement(); exit(2);
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation { Record(@"download", nil); }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { Record(@"extracting", nil); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    Record(@"ready-to-install", nil); reply(SPUUserUpdateChoiceInstall);
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    Record(@"installing", @{@"terminated": @(terminated)});
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement { acknowledgement(); }
- (void)dismissUpdateInstallation {}
@end

@interface AcceptanceApp : NSObject <NSApplicationDelegate>
@property SPUUpdater *updater;
@property AcceptanceDriver *driver;
@property BOOL terminating;
@end
@implementation AcceptanceApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    Record(@"launched", @{@"bundle": NSBundle.mainBundle.bundlePath});
    if ([NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] isEqual:@"2"]) {
        // The old app's delayed quit is the lifecycle under test. This newly
        // relaunched fixture has no services to clean up.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            Record(@"acceptance-completed", nil); exit(0);
        });
        return;
    }
    self.driver = [AcceptanceDriver new];
    self.updater = [[SPUUpdater alloc] initWithHostBundle:NSBundle.mainBundle applicationBundle:NSBundle.mainBundle userDriver:self.driver delegate:nil];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) { Record(@"startup-error", @{@"description": error.localizedDescription}); exit(2); }
    [self.updater checkForUpdates];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (self.terminating) return NSTerminateLater;
    self.terminating = YES;
    Record(@"quit-requested", nil);
    // Exercise the same delayed quit contract as Coddle's async cleanup.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
        Record(@"cleanup-completed", nil); [sender replyToApplicationShouldTerminate:YES];
    });
    return NSTerminateLater;
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AcceptanceApp *delegate = [AcceptanceApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
