#include "audio-route.h"

int mirror_audio_route_step(mirror_audio_route *route, const mirror_audio_backend *backend) {
    uint32_t current = backend->current(backend->context);
    if (!current) return 0;
    if (!backend->is_bridge(backend->context, current)) {
        if (backend->usable(backend->context, current)) route->previous = current;
        return 0;
    }
    if (!route->previous || route->previous == current ||
        !backend->usable(backend->context, route->previous)) return 0;
    return backend->select(backend->context, route->previous) ? 1 : -1;
}
