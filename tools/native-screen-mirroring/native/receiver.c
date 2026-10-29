// GPL-3.0-or-later. Uses the UxPlay receiver core; no GStreamer required.
#include "raop.h"
#include "audio-route.h"
#include <arpa/inet.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static FILE *events;
static bool preflight(void *cls) {
    (void)cls;
    if (!events) return false;
    const char *body = "{\"preflight\":true}";
    uint32_t length = htonl((uint32_t)strlen(body));
    flockfile(events);
    fwrite(&length, 4, 1, events); fwrite(body, 1, strlen(body), events);
    fflush(events); funlockfile(events);
    fd_set fds; FD_ZERO(&fds); FD_SET(4, &fds);
    struct timeval timeout = {10, 0};
    unsigned char answer = 0;
    return select(5, &fds, NULL, NULL, &timeout) > 0 && read(4, &answer, 1) == 1 && answer == 1;
}
static void mirror_state(void *cls, bool active) {
    (void)cls;
    fprintf(stderr, "AIRPLAY-SESSION %s\n", active ? "started" : "stopped");
    if (events) {
        const char *body = active ? "{\"active\":true}" : "{\"active\":false}";
        uint32_t length = htonl((uint32_t)strlen(body));
        flockfile(events);
        fwrite(&length, 4, 1, events);
        fwrite(body, 1, strlen(body), events);
        fflush(events);
        funlockfile(events);
    }
}
static void stop(int sig) { (void)sig; running = 0; }
static void noop(void *cls) { (void)cls; }
static void reset(void *cls, reset_type_t reason) { (void)cls; (void)reason; }
static void conn_reset(void *cls, int reason) { (void)cls; (void)reason; }
static void audio(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {
    (void)cls; (void)ntp; (void)data;
}
static double volume(void *cls) { (void)cls; return -30.0; }
static int codec(void *cls, video_codec_t value) {
    (void)cls; return value == VIDEO_CODEC_H264 ? 0 : -1;
}
static void size(void *cls, float *sw, float *sh, float *w, float *h) {
    (void)cls; (void)sw; (void)sh;
    fprintf(stderr, "AIRPLAY-SIZE %.0fx%.0f\n", *w, *h);
}
static void video(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    (void)cls; (void)ntp;
    if (data->data_len <= 0 || data->is_h265) return;
    uint32_t length = htonl((uint32_t)data->data_len);
    if (fwrite(&length, 4, 1, stdout) != 1 ||
        fwrite(data->data, 1, data->data_len, stdout) != (size_t)data->data_len ||
        fflush(stdout) != 0) running = 0;
}
static void log_message(void *cls, int level, const char *message) {
    (void)cls; (void)level; fprintf(stderr, "%s\n", message);
}
static int dimension(const char *key, int fallback) {
    const char *value = getenv(key);
    if (!value) return fallback;
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (!end || *end || parsed < 320 || parsed > 8192) {
        fprintf(stderr, "Invalid %s (expected 320..8192 pixels)\n", key); exit(1);
    }
    return (int)parsed;
}
int main(int argc, char **argv) {
    if (getenv("MIRROR_EVENTS")) events = fdopen(3, "wb");
    const char *name = argc > 1 ? argv[1] : "iPhone Mirror";
    const char *pairing_id = getenv("MIRROR_PAIRING_ID");
    if (pairing_id && pairing_id[0]) {
        if (strlen(pairing_id) != 36) { fprintf(stderr, "Invalid MIRROR_PAIRING_ID\n"); return 1; }
        for (int i = 0; i < 36; i++) {
            int hyphen = i == 8 || i == 13 || i == 18 || i == 23;
            if ((hyphen && pairing_id[i] != '-') || (!hyphen && !strchr("0123456789abcdefABCDEF", pairing_id[i]))) {
                fprintf(stderr, "Invalid MIRROR_PAIRING_ID\n"); return 1;
            }
        }
    }
    mirror_audio_route_poll(name);
    unsigned char hw[6] = {0x02, 0x49, 0x50, 0x48, 0x4f, 0x4e};
    const char *device_id = getenv("MIRROR_DEVICE_ID");
    if (!device_id) device_id = "02:49:50:48:4f:4e";
    unsigned int parsed[6];
    if (sscanf(device_id, "%2x:%2x:%2x:%2x:%2x:%2x", &parsed[0], &parsed[1], &parsed[2], &parsed[3], &parsed[4], &parsed[5]) != 6) {
        fprintf(stderr, "Invalid MIRROR_DEVICE_ID\n"); return 1;
    }
    for (int i = 0; i < 6; i++) hw[i] = parsed[i];
    signal(SIGINT, stop); signal(SIGTERM, stop); signal(SIGPIPE, stop);
    int error = 0;
    ntp_global_init();
    dnssd_t *dns = dnssd_init(name, strlen(name), (const char *)hw, 6, 0, &error);
    if (!dns || error) { fprintf(stderr, "DNS init failed: %d\n", error); return 1; }
#ifdef UXPLAY_HAVE_APPLE_P2P
    dnssd_set_peer_to_peer(dns, getenv("MIRROR_P2P") != NULL);
#endif
    // macOS needs the audio capability to keep the route active across display
    // updates. Preserve the user's real audio output with the Core Audio guard.
    const int off[] = {0, 3, 4, 8, 23, 24, 26, 29, 31, 42};
    for (size_t i = 0; i < sizeof(off)/sizeof(off[0]); i++)
        dnssd_set_airplay_features(dns, off[i], 0);
    raop_callbacks_t cb = {0};
    cb.audio_process = audio; cb.video_process = video;
    cb.conn_init = noop; cb.conn_destroy = noop; cb.conn_feedback = noop;
    cb.conn_reset = conn_reset; cb.video_reset = reset;
    cb.audio_flush = noop; cb.video_flush = noop;
    cb.video_pause = noop; cb.video_resume = noop;
    cb.audio_set_client_volume = volume; cb.audio_stop_coverart_rendering = noop;
    cb.video_set_codec = codec; cb.video_report_size = size;
    cb.mirror_video_running = mirror_state;
    cb.mirror_preflight = preflight;
    raop_t *raop = raop_init(&cb);
    if (!raop) return 1;
    raop_set_log_callback(raop, log_message, NULL);
    raop_set_log_level(raop, 6);
    if (raop_init2(raop, 0, device_id, "")) return 1;
    raop_set_dnssd(raop, dns);
    raop_set_plist(raop, "width", dimension("MIRROR_WIDTH", 1288));
    raop_set_plist(raop, "height", dimension("MIRROR_HEIGHT", 2796));
    raop_set_plist(raop, "maxFPS", 60);
    const char *event_port = getenv("MIRROR_EVENT_PORT");
    if (event_port) {
        char *end = NULL;
        long value = strtol(event_port, &end, 10);
        if (!*event_port || *end || value < 1 || value > 65535) return 1;
        raop_set_plist(raop, "eventPort", (int)value);
    }
    unsigned short tcp[2] = {0}, udp[3] = {0}, port = 0;
    raop_set_tcp_ports(raop, tcp); raop_set_udp_ports(raop, udp);
    if (raop_start_httpd(raop, &port) < 0) return 1;
    raop_set_port(raop, port);
    if (dnssd_register_raop(dns, port) || dnssd_register_airplay(dns, port)) return 1;
    fprintf(stderr, "AIRPLAY-READY %s port=%u\n", name, port);
    while (running) {
        mirror_audio_route_poll(name);
#ifdef EXTERNAL_DNS_SD
        fd_set fds; FD_ZERO(&fds); int max = -1;
        int a = dnssd_get_service_fd(dns, 0), b = dnssd_get_service_fd(dns, 1);
        if (a >= 0) { FD_SET(a, &fds); max = a; }
        if (b >= 0) { FD_SET(b, &fds); if (b > max) max = b; }
        struct timeval timeout = {0, 100000};
        if (select(max + 1, &fds, NULL, NULL, &timeout) > 0) {
            if (a >= 0 && FD_ISSET(a, &fds)) dnssd_process_service(dns, 0);
            if (b >= 0 && FD_ISSET(b, &fds)) dnssd_process_service(dns, 1);
        }
#else
        usleep(100000);
#endif
    }
    dnssd_unregister_airplay(dns); dnssd_unregister_raop(dns);
    raop_destroy(raop); dnssd_destroy(dns);
    return 0;
}
