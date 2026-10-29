#include <stdio.h>
#include <stdint.h>
#include "dnssd.h"

int main(void) {
    dnssd_t state = {0};
    for (int bit = 0; bit < 64; bit++) {
        dnssd_set_airplay_features(&state, bit, 1);
        if (dnssd_get_airplay_features(&state) != (UINT64_C(1) << bit)) {
            fprintf(stderr, "Failed to set feature bit %d\n", bit);
            return 1;
        }
        dnssd_set_airplay_features(&state, bit, 0);
        if (dnssd_get_airplay_features(&state) != 0) {
            fprintf(stderr, "Failed to clear feature bit %d\n", bit);
            return 1;
        }
    }
    dnssd_set_airplay_features(&state, -1, 1);
    dnssd_set_airplay_features(&state, 64, 1);
    dnssd_set_airplay_features(&state, 0, -1);
    dnssd_set_airplay_features(&state, 0, 2);
    if (dnssd_get_airplay_features(&state) != 0) {
        fputs("Invalid feature requests changed the mask\n", stderr);
        return 1;
    }
    return 0;
}
