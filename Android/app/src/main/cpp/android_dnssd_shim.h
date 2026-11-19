#ifndef ANDROID_DNSSD_SHIM_H
#define ANDROID_DNSSD_SHIM_H

#include "dnssd.h"

#ifdef __cplusplus
extern "C" {
#endif

int android_dnssd_get_raop_txt_count(dnssd_t *dnssd);
const char *android_dnssd_get_raop_txt_key(dnssd_t *dnssd, int index);
const char *android_dnssd_get_raop_txt_val(dnssd_t *dnssd, int index);

int android_dnssd_get_airplay_txt_count(dnssd_t *dnssd);
const char *android_dnssd_get_airplay_txt_key(dnssd_t *dnssd, int index);
const char *android_dnssd_get_airplay_txt_val(dnssd_t *dnssd, int index);

void android_dnssd_set_codecs(dnssd_t *dnssd, int alac, int aac);
const char *android_dnssd_get_raop_servname(dnssd_t *dnssd);

#ifdef __cplusplus
}
#endif

#endif
