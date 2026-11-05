#import <AppKit/AppKit.h>

@interface SetupController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(strong) NSWindow *window;
@property(strong) NSTextField *status;
@property(strong) NSTextField *heading;
@property(strong) NSButton *installButton;
@property(strong) NSButton *removeButton;
@property(strong) NSButton *cancelButton;
@property(strong) NSImageView *successIcon;
@property(strong) NSProgressIndicator *progress;
@property(strong) NSTask *task;
@end

@implementation SetupController
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 250)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed = NO;
    self.window.title = @"Screen Mirroring for iPhone"; self.window.delegate = self;
    self.heading = [NSTextField labelWithString:@"Screen Mirroring for iPhone"];
    self.heading.font = [NSFont systemFontOfSize:19 weight:NSFontWeightSemibold];
    self.status = [NSTextField wrappingLabelWithString:@""];
    self.status.preferredMaxLayoutWidth = 440;
    self.status.font = [NSFont systemFontOfSize:14];
    self.successIcon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"checkmark.circle.fill" accessibilityDescription:@"Success"]];
    self.successIcon.contentTintColor = NSColor.systemGreenColor;
    self.successIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:32 weight:NSFontWeightRegular];
    self.successIcon.hidden = YES;
    self.progress = [[NSProgressIndicator alloc] init]; self.progress.style = NSProgressIndicatorStyleSpinning;
    self.progress.displayedWhenStopped = NO;
    self.installButton = [NSButton buttonWithTitle:@"Install" target:self action:@selector(install:)];
    self.installButton.bezelStyle = NSBezelStyleRounded; self.installButton.keyEquivalent = @"\r";
    self.removeButton = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(remove:)];
    self.removeButton.bezelStyle = NSBezelStyleRounded;
    self.cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(done:)];
    self.cancelButton.keyEquivalent = @"\e";
    self.removeButton.hidden = ![NSFileManager.defaultManager fileExistsAtPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/iphone-native-mirror/runtime/node"]];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.removeButton, self.cancelButton, self.installButton]];
    buttons.spacing = 20;
    NSStackView *stack = [NSStackView stackViewWithViews:@[self.successIcon, self.heading, self.status, self.progress, buttons]];
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
- (void)done:(id)sender { (void)sender; [self.window close]; }
- (void)finish:(BOOL)success removing:(BOOL)remove message:(NSString *)message {
    [self.progress stopAnimation:nil];
    self.task = nil;
    self.installButton.enabled = YES;
    if (success) {
        self.window.title = remove ? @"Removal complete" : @"Installation complete";
        self.heading.stringValue = self.window.title;
        self.successIcon.hidden = NO; self.cancelButton.hidden = YES;
        self.status.stringValue = remove ? @"The background service has been removed. Your saved phone settings are kept."
            : @"1. Open the OpenDisplay app on your iPhone.\n\n2. On your Mac, open Control Center, click Screen Mirroring, then select iPhone.";
        self.installButton.title = @"Done";
        self.installButton.action = @selector(done:);
        self.removeButton.hidden = YES;
    } else {
        self.successIcon.hidden = YES; self.cancelButton.hidden = NO; self.cancelButton.enabled = YES;
        self.window.title = @"Setup incomplete";
        self.heading.stringValue = remove ? @"Removal failed" : @"Installation failed";
        self.status.stringValue = message.length ? [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"Please try again.";
        self.installButton.title = remove ? @"Install" : @"Retry";
        self.installButton.action = @selector(install:);
        self.removeButton.hidden = NO; self.removeButton.enabled = YES;
    }
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
    self.installButton.enabled = NO; self.removeButton.enabled = NO; self.cancelButton.enabled = NO;
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
            [controller finish:completed.terminationStatus == 0 removing:remove message:message];
        });
    };
    NSError *error; if (![task launchAndReturnError:&error]) {
        [self finish:NO removing:remove message:error.localizedDescription];
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
