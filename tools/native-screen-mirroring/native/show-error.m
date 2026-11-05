#import <AppKit/AppKit.h>

@interface ErrorController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *panel;
- (void)dismiss:(id)sender;
@end
@implementation ErrorController
- (void)dismiss:(id)sender { (void)sender; [NSApp stopModal]; [self.panel orderOut:nil]; }
- (void)windowWillClose:(NSNotification *)notification { (void)notification; [NSApp stopModal]; }
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *title = @"iPhone display isn't ready";
        NSString *message = @"Open OpenDisplay on your iPhone and keep it visible. Then try again.";
        if (argc > 1 && !strcmp(argv[1], "tailscale")) {
            title = @"Tailscale setup required";
            message = @"Tailscale needs to be configured.";
        }
        if (argc > 1 && !strcmp(argv[1], "sidecar")) {
            title = @"Connect iPad first";
            message = @"In Control Center → Screen Mirroring, disconnect iPhone. Connect iPad, then reconnect iPhone.";
        }
        NSImage *icon = [NSImage imageWithSystemSymbolName:@"laptopcomputer" accessibilityDescription:@"Laptop display"];
        icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.systemBlueColor]]];
        icon.size = NSMakeSize(64, 64);
        BOOL check = !strcmp(argv[argc - 1], "--check");

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        ErrorController *controller = [[ErrorController alloc] init];
        NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 280)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
            backing:NSBackingStoreBuffered defer:NO];
        controller.panel = panel; panel.delegate = controller;
        panel.title = @"iPhone Display";
        panel.titleVisibility = NSWindowTitleHidden;
        panel.titlebarAppearsTransparent = YES;
        panel.movableByWindowBackground = YES;
        panel.level = NSFloatingWindowLevel;
        panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

        NSImageView *image = [NSImageView imageViewWithImage:icon];
        [image.widthAnchor constraintEqualToConstant:64].active = YES;
        [image.heightAnchor constraintEqualToConstant:64].active = YES;
        NSTextField *heading = [NSTextField wrappingLabelWithString:title];
        heading.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
        heading.alignment = NSTextAlignmentCenter;
        NSTextField *body = [NSTextField wrappingLabelWithString:message];
        body.font = [NSFont systemFontOfSize:13];
        body.textColor = NSColor.secondaryLabelColor;
        body.alignment = NSTextAlignmentCenter;
        body.preferredMaxLayoutWidth = 332;
        NSButton *button = [NSButton buttonWithTitle:@"OK" target:controller action:@selector(dismiss:)];
        button.bezelStyle = NSBezelStyleRounded;
        button.keyEquivalent = @"\r";
        [button.widthAnchor constraintEqualToConstant:88].active = YES;
        NSStackView *stack = [NSStackView stackViewWithViews:@[image, heading, body, button]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeCenterX;
        stack.spacing = 14;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [panel.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.widthAnchor constraintEqualToConstant:332],
            [stack.centerXAnchor constraintEqualToAnchor:panel.contentView.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:panel.contentView.centerYAnchor],
            [body.widthAnchor constraintEqualToConstant:332],
            [heading.widthAnchor constraintEqualToConstant:332],
        ]];
        [panel.contentView layoutSubtreeIfNeeded];
        if (check) {
            NSRect imageFrame = [image convertRect:image.bounds toView:panel.contentView];
            NSRect bodyFrame = [body convertRect:body.bounds toView:panel.contentView];
            NSRect stackFrame = [stack convertRect:stack.bounds toView:panel.contentView];
            BOOL valid = title.length > 0 && message.length < 100 && icon.TIFFRepresentation.length > 0
                && fabs(NSMidX(imageFrame) - NSMidX(panel.contentView.bounds)) < 1
                && fabs(NSMidX(bodyFrame) - NSMidX(imageFrame)) < 1
                && NSContainsRect(panel.contentView.bounds, stackFrame)
                && fabs(imageFrame.size.width - 64) < 1 && bodyFrame.size.height > 0;
            if (!valid) NSLog(@"Layout check failed: content=%@ stack=%@ icon=%@ body=%@", NSStringFromRect(panel.contentView.bounds), NSStringFromRect(stackFrame), NSStringFromRect(imageFrame), NSStringFromRect(bodyFrame));
            return valid ? 0 : 1;
        }
        NSScreen *screen = NSScreen.screens.firstObject;
        for (NSScreen *candidate in NSScreen.screens)
            if ([candidate.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == CGMainDisplayID()) { screen = candidate; break; }
        NSRect visible = screen.visibleFrame;
        [panel setFrameOrigin:NSMakePoint(NSMidX(visible) - panel.frame.size.width / 2,
                                         NSMidY(visible) - panel.frame.size.height / 2)];
        [panel makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp runModalForWindow:panel];
    }
    return 0;
}
