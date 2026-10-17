#ifndef MIRROR_AUDIO_ROUTE_H
#define MIRROR_AUDIO_ROUTE_H
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    uint32_t previous;
} mirror_audio_route;
typedef struct {
    void *context;
    uint32_t (*current)(void *);
    bool (*is_bridge)(void *, uint32_t);
    bool (*usable)(void *, uint32_t);
    bool (*select)(void *, uint32_t);
} mirror_audio_backend;

int mirror_audio_route_step(mirror_audio_route *, const mirror_audio_backend *);
void mirror_audio_route_poll(const char *);
#endif
