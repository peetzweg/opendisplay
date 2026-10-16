#import <AppKit/AppKit.h>

@interface SetupController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(strong) NSWindow *window;
@property(strong) NSTextField *status;
@property(strong) NSButton *installButton;
@property(strong) NSButton *removeButton;
@property(strong) NSProgressIndicator *progress;
@property(strong) NSTask *task;
@end

@implementation SetupController
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 280)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Install iPhone Native Mirror"; self.window.delegate = self;
    NSTextField *heading = [NSTextField labelWithString:@"Use your iPhone as a Mac display"];
    heading.font = [NSFont systemFontOfSize:19 weight:NSFontWeightSemibold];
    self.status = [NSTextField wrappingLabelWithString:@"Open OpenDisplay on your unlocked iPhone and connect both devices to the same Wi-Fi. Click Install to find your phone and set up the background service."];
    self.status.preferredMaxLayoutWidth = 440;
    self.progress = [[NSProgressIndicator alloc] init]; self.progress.style = NSProgressIndicatorStyleSpinning;
    self.progress.displayedWhenStopped = NO;
    self.installButton = [NSButton buttonWithTitle:@"Install" target:self action:@selector(install:)];
    self.installButton.bezelStyle = NSBezelStyleRounded; self.installButton.keyEquivalent = @"\r";
    self.removeButton = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(remove:)];
    self.removeButton.bezelStyle = NSBezelStyleRounded;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.removeButton, self.installButton]];
    buttons.spacing = 20;
    NSStackView *stack = [NSStackView stackViewWithViews:@[heading, self.status, self.progress, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical; stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:30],
        [stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-30],
        [stack.centerYAnchor constraintEqualToAnchor:self.window.contentView.centerYAnchor],
        [self.status.widthAnchor constraintEqualToConstant:440]]];
    [self.window center]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}
- (void)install:(id)sender { (void)sender; [self start:NO]; }
- (void)remove:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"Remove iPhone Native Mirror?";
    alert.informativeText = @"This stops and removes the background service. Your saved phone settings are kept.";
    [alert addButtonWithTitle:@"Remove"]; [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) [self start:YES];
}
- (void)start:(BOOL)remove {
    self.installButton.enabled = NO; self.removeButton.enabled = NO;
    self.status.stringValue = remove ? @"Removing the background service…" : @"Finding your phone and installing…";
    [self.progress startAnimation:nil];
    NSString *runtime = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"runtime"];
    NSTask *task = [[NSTask alloc] init]; self.task = task;
    task.executableURL = [NSURL fileURLWithPath:[runtime stringByAppendingPathComponent:@"node"]];
    task.arguments = remove ? @[[runtime stringByAppendingPathComponent:@"scripts/bundle-setup.js"], @"--remove"]
                            : @[[runtime stringByAppendingPathComponent:@"scripts/bundle-setup.js"]];
    NSMutableDictionary *env = NSProcessInfo.processInfo.environment.mutableCopy;
    env[@"PATH"] = @"/usr/bin:/bin:/usr/sbin:/sbin";
    [env removeObjectForKey:@"IPHONE_HOST"]; task.environment = env;
    NSPipe *output = [NSPipe pipe]; task.standardOutput = output; task.standardError = output;
    __weak SetupController *weakSelf = self;
    task.terminationHandler = ^(NSTask *completed) {
        NSData *data = [output.fileHandleForReading readDataToEndOfFile];
        NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{
            SetupController *controller = weakSelf;
            [controller.progress stopAnimation:nil];
            controller.status.stringValue = message.length ? message : @"Setup did not complete. Please retry.";
            controller.installButton.enabled = YES; controller.removeButton.enabled = YES;
            if (completed.terminationStatus == 0) controller.window.title = remove ? @"iPhone Native Mirror removed" : @"iPhone Native Mirror installed";
            controller.task = nil;
        });
    };
    NSError *error; if (![task launchAndReturnError:&error]) {
        [self.progress stopAnimation:nil]; self.status.stringValue = error.localizedDescription;
        self.installButton.enabled = YES; self.removeButton.enabled = YES; self.task = nil;
    }
}
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; return self.task == nil; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        SetupController *controller = [[SetupController alloc] init]; NSApp.delegate = controller; [NSApp run];
    }
    return 0;
}
