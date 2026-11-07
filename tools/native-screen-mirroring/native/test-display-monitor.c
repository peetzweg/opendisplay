// Developer diagnostic: observe public CoreGraphics display events without changing displays.
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

static void snapshot(CGDirectDisplayID changed, CGDisplayChangeSummaryFlags flags) {
    CGDirectDisplayID ids[64]; uint32_t count = 0;
    CGError result = CGGetActiveDisplayList(64, ids, &count);
    printf("{\"time\":%.3f,\"display\":%u,\"flags\":%u,\"begin\":%s,\"removed\":%s,\"error\":%d,\"active\":[",
        CFAbsoluteTimeGetCurrent(), changed, flags, (flags & kCGDisplayBeginConfigurationFlag) ? "true" : "false",
        (flags & kCGDisplayRemoveFlag) ? "true" : "false", result);
    for (uint32_t i = 0; i < count; i++) {
        printf("%s{\"id\":%u,\"vendor\":%u,\"product\":%u,\"width\":%zu,\"height\":%zu}", i ? "," : "", ids[i],
            CGDisplayVendorNumber(ids[i]), CGDisplayModelNumber(ids[i]),
            CGDisplayPixelsWide(ids[i]), CGDisplayPixelsHigh(ids[i]));
    }
    puts("]}"); fflush(stdout);
}
static void changed(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
    (void)context; snapshot(display, flags);
}
static void poll(CFRunLoopTimerRef timer, void *context) {
    (void)timer; (void)context; snapshot(0, 0);
}
int main(int argc, char **argv) {
    char *end = NULL;
    double seconds = argc > 1 ? strtod(argv[1], &end) : 180;
    if (!isfinite(seconds) || seconds <= 0 || seconds > 3600 ||
        (argc > 1 && (!*argv[1] || *end))) return 2;
    CGError result = CGDisplayRegisterReconfigurationCallback(changed, NULL);
    if (result != kCGErrorSuccess) return 1;
    snapshot(0, 0);
    // Callback delivery can be absent in a command-line process. Poll as well
    // so a running monitor always records bounded, timestamped evidence.
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 0.1, 0.1, 0, 0, poll, NULL);
    if (!timer) { CGDisplayRemoveReconfigurationCallback(changed, NULL); return 1; }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    CFRunLoopTimerInvalidate(timer);
    CFRelease(timer);
    CGDisplayRemoveReconfigurationCallback(changed, NULL);
    return 0;
}
