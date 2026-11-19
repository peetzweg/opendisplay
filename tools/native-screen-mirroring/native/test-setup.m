#define main installerMain
#import "setup.m"
#undef main
#define CHECK(condition) do { if (!(condition)) { NSLog(@"Failed: %s", #condition); return 1; } } while (0)
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        SetupController *controller = [SetupController new];
        [controller applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
        CHECK([controller.installButton.title isEqualToString:@"Install"]);
        [controller finish:YES removing:NO message:@"Finding phone…\nInstalled"];
        CHECK([controller.heading.stringValue isEqualToString:@"Installation complete"]);
        CHECK([controller.installButton.title isEqualToString:@"Done"]);
        CHECK(controller.installButton.action == @selector(done:));
        CHECK(controller.removeButton.hidden);
        CHECK([controller.status.stringValue containsString:@"Screen Mirroring, then select iPhone"]);
        CHECK(![controller.status.stringValue containsString:@"iPad"]);
        CHECK(!controller.successIcon.hidden);
        CHECK(controller.cancelButton.hidden);
        CHECK(![controller.status.stringValue containsString:@"Finding"]);
        [controller finish:NO removing:NO message:@"No phone found.\n"];
        CHECK([controller.installButton.title isEqualToString:@"Retry"]);
        CHECK(controller.installButton.action == @selector(install:));
        CHECK(!controller.removeButton.hidden);
        CHECK([controller.status.stringValue isEqualToString:@"No phone found."]);
        [controller finish:YES removing:YES message:nil];
        CHECK([controller.heading.stringValue isEqualToString:@"Removal complete"]);
        CHECK([controller.installButton.title isEqualToString:@"Done"]);
        [controller done:nil];
        CHECK(!controller.window.visible);
        NSLog(@"Installer UI checks passed");
    }
    return 0;
}
