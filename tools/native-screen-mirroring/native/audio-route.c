#include "audio-route.h"
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <time.h>

static const AudioObjectPropertyAddress output = {
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
};
static uint32_t current(void *context) {
    (void)context;
    AudioDeviceID device = kAudioObjectUnknown; UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &output, 0, NULL, &size, &device) != noErr) return 0;
    return device;
}
static bool is_bridge(void *context, uint32_t device) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 transport = 0, size = sizeof(transport);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &transport) != noErr || transport != kAudioDeviceTransportTypeAirPlay) return false;
    address.mSelector = kAudioObjectPropertyName;
    CFStringRef name = NULL; size = sizeof(name);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name) != noErr || !name) return false;
    CFStringRef expected = CFStringCreateWithCString(NULL, context, kCFStringEncodingUTF8);
    bool matches = expected && CFEqual(name, expected);
    if (expected) CFRelease(expected);
    CFRelease(name);
    return matches;
}
static bool usable(void *context, uint32_t device) {
    (void)context;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 alive = 0, size = sizeof(alive);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &alive) != noErr || !alive) return false;
    address.mSelector = kAudioDevicePropertyStreams; address.mScope = kAudioDevicePropertyScopeOutput;
    return AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) == noErr && size > 0;
}
static bool select_output(void *context, uint32_t device) {
    (void)context;
    AudioDeviceID selected = device;
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &output, 0, NULL, sizeof(selected), &selected) == noErr;
}
void mirror_audio_route_poll(const char *name) {
    static mirror_audio_route route = {0};
    static double retry_after = 0;
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    double seconds = now.tv_sec + now.tv_nsec / 1e9;
    if (seconds < retry_after) return;
    mirror_audio_backend backend = {(void *)name, current, is_bridge, usable, select_output};
    int result = mirror_audio_route_step(&route, &backend);
    if (result > 0) fprintf(stderr, "AUDIO-OUTPUT restored selected output\n");
    if (result < 0) {
        fprintf(stderr, "AUDIO-OUTPUT could not restore selected output\n");
        retry_after = seconds + 1;
    }
}
