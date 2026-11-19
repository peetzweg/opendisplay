/*
 * JNI bridge between Kotlin NativeBridge and the C RAOP library.
 */

#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include <memory>
#include <android/log.h>

extern "C" {
#include "raop.h"
#include "dnssd.h"
#include "logger.h"
#include "pairing.h"
#include "android_raop_callbacks.h"
#include "android_dnssd_shim.h"
}

#include "audio_engine.h"
#include "log_sink.h"

#define TAG "AirPlayNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* Holds all native state for one server instance */
typedef struct {
    raop_t *raop;
    dnssd_t *dnssd;
    android_callback_ctx_t cb_ctx;
    raop_callbacks_t callbacks;
    char hw_addr[6];
    std::shared_ptr<LogSink> log;
} server_ctx_t;

static void _log_callback(void *cls, int level, const char *msg) {
    int prio = ANDROID_LOG_DEBUG;
    if (level <= LOGGER_ERR) prio = ANDROID_LOG_ERROR;
    else if (level == LOGGER_WARNING) prio = ANDROID_LOG_WARN;
    else if (level <= LOGGER_INFO) prio = ANDROID_LOG_INFO;
    __android_log_print(prio, TAG, "%s", msg);
}

extern "C"
JNIEXPORT jlong JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeInit(
        JNIEnv *env, jobject thiz,
        jobject callback, jbyteArray hwAddr, jstring name, jstring keyFile,
        jboolean nohold, jboolean requirePin) {

    server_ctx_t *ctx = new server_ctx_t();

    jsize hw_len = env->GetArrayLength(hwAddr);
    if (hw_len > 6) hw_len = 6;
    env->GetByteArrayRegion(hwAddr, 0, hw_len, (jbyte *)ctx->hw_addr);

    android_callbacks_init(&ctx->cb_ctx, env, callback);
    ctx->cb_ctx.require_pin = requirePin ? 1 : 0;
    android_callbacks_fill(&ctx->callbacks, &ctx->cb_ctx);

    ctx->raop = raop_init(&ctx->callbacks);
    if (!ctx->raop) {
        LOGE("raop_init failed");
        android_callbacks_destroy(&ctx->cb_ctx, env);
        delete ctx;
        return 0;
    }
    ctx->cb_ctx.raop = ctx->raop;

    raop_set_log_level(ctx->raop, LOGGER_ERR);
    raop_set_log_callback(ctx->raop, _log_callback, NULL);

    const char *keyfile_c = env->GetStringUTFChars(keyFile, NULL);
    const char *name_c = env->GetStringUTFChars(name, NULL);

    char device_id[18];
    snprintf(device_id, sizeof(device_id), "%02X:%02X:%02X:%02X:%02X:%02X",
             (unsigned char)ctx->hw_addr[0], (unsigned char)ctx->hw_addr[1],
             (unsigned char)ctx->hw_addr[2], (unsigned char)ctx->hw_addr[3],
             (unsigned char)ctx->hw_addr[4], (unsigned char)ctx->hw_addr[5]);

    int ret = raop_init2(ctx->raop, nohold ? 1 : 0, device_id, keyfile_c);
    if (ret < 0) {
        LOGE("raop_init2 failed: %d", ret);
    }

    if (requirePin) {
        /* avoid UxPlay's random-PIN retry path: use one random PIN for this server run */
        int pin = random_pin();
        if (pin < 0) {
            LOGE("Failed to generate random pin");
            pin = 1234;
        }
        raop_set_plist(ctx->raop, "pin", pin + 10000);
    }

    /* shim dnssd_init only builds txt records; kotlin does the actual nsd registration */
    int dns_err = 0;
    unsigned char pin_pw = requirePin ? 1 : 0;
    ctx->dnssd = dnssd_init(name_c, (int)strlen(name_c), ctx->hw_addr, 6, &dns_err, pin_pw);
    if (!ctx->dnssd) {
        LOGE("dnssd_init failed: %d", dns_err);
    } else {
        raop_set_dnssd(ctx->raop, ctx->dnssd);
    }

    env->ReleaseStringUTFChars(keyFile, keyfile_c);
    env->ReleaseStringUTFChars(name, name_c);

    ctx->log = std::make_shared<LogSink>();
    ctx->log->bind(env, callback);

    ctx->cb_ctx.audio_engine = audio_engine_create(ctx->log, 44100, 2);

    return (jlong)(intptr_t)ctx;
}

extern "C"
JNIEXPORT jint JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeStart(
        JNIEnv *env, jobject thiz, jlong handle, jint requestedPort) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->raop) return -1;

    unsigned short port = (unsigned short)(requestedPort > 0 ? requestedPort : 7000);
    int ret = raop_start_httpd(ctx->raop, &port);
    if (ret < 0) {
        LOGE("raop_start_httpd failed: %d", ret);
        return -1;
    }
    /* raop_start_httpd doesn't record the bound port; without this the hls
       proxy urls are built with port 0 */
    raop_set_port(ctx->raop, port);

    LOGI("AirPlay server started on port %d", port);

    /* Register dnssd records (stored in shim, Kotlin reads them) */
    if (ctx->dnssd) {
        dnssd_register_raop(ctx->dnssd, port);
        dnssd_register_airplay(ctx->dnssd, port);
    }

    return (jint)port;
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeStop(
        JNIEnv *env, jobject thiz, jlong handle) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->raop) return;

    raop_stop_httpd(ctx->raop);
    LOGI("AirPlay server stopped");

    if (ctx->dnssd) {
        dnssd_unregister_raop(ctx->dnssd);
        dnssd_unregister_airplay(ctx->dnssd);
    }
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeDestroy(
        JNIEnv *env, jobject thiz, jlong handle) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx) return;

    if (ctx->raop) {
        raop_destroy(ctx->raop);
        ctx->raop = NULL;
    }
    // engine teardown safe: raop_destroy() already ran, no decode() calls in flight
    AudioEngine *engine = ctx->cb_ctx.audio_engine;
    ctx->cb_ctx.audio_engine = NULL;
    if (engine) audio_engine_destroy(engine);
    if (ctx->dnssd) {
        dnssd_destroy(ctx->dnssd);
        ctx->dnssd = NULL;
    }
    android_callbacks_destroy(&ctx->cb_ctx, env);
    delete ctx;
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeSetDisplaySize(
        JNIEnv *env, jobject thiz, jlong handle, jint w, jint h, jint fps) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->raop) return;

    raop_set_plist(ctx->raop, "width", w);
    raop_set_plist(ctx->raop, "height", h);
    raop_set_plist(ctx->raop, "refreshRate", fps);
}

/* Returns a HashMap<String, String> of TXT records */
static jobject _build_txt_map(JNIEnv *env, dnssd_t *dnssd, int is_raop) {
    jclass mapClass = env->FindClass("java/util/HashMap");
    jmethodID mapInit = env->GetMethodID(mapClass, "<init>", "()V");
    jmethodID mapPut = env->GetMethodID(mapClass, "put",
        "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    jobject map = env->NewObject(mapClass, mapInit);

    int count = is_raop ? android_dnssd_get_raop_txt_count(dnssd)
                        : android_dnssd_get_airplay_txt_count(dnssd);

    for (int i = 0; i < count; i++) {
        const char *key = is_raop ? android_dnssd_get_raop_txt_key(dnssd, i)
                                  : android_dnssd_get_airplay_txt_key(dnssd, i);
        const char *val = is_raop ? android_dnssd_get_raop_txt_val(dnssd, i)
                                  : android_dnssd_get_airplay_txt_val(dnssd, i);
        if (key && val) {
            jstring jkey = env->NewStringUTF(key);
            jstring jval = env->NewStringUTF(val);
            env->CallObjectMethod(map, mapPut, jkey, jval);
            env->DeleteLocalRef(jkey);
            env->DeleteLocalRef(jval);
        }
    }

    env->DeleteLocalRef(mapClass);
    return map;
}

extern "C"
JNIEXPORT jobject JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeGetRaopTxtRecords(
        JNIEnv *env, jobject thiz, jlong handle) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->dnssd) return NULL;
    return _build_txt_map(env, ctx->dnssd, 1);
}

extern "C"
JNIEXPORT jobject JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeGetAirplayTxtRecords(
        JNIEnv *env, jobject thiz, jlong handle) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->dnssd) return NULL;
    return _build_txt_map(env, ctx->dnssd, 0);
}

extern "C"
JNIEXPORT jstring JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeGetRaopServiceName(
        JNIEnv *env, jobject thiz, jlong handle) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->dnssd) return NULL;
    return env->NewStringUTF(android_dnssd_get_raop_servname(ctx->dnssd));
}

extern "C"
JNIEXPORT jstring JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeGetServerName(
        JNIEnv *env, jobject thiz, jlong handle) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->dnssd) return NULL;
    int len = 0;
    const char *name = dnssd_get_name(ctx->dnssd, &len);
    return env->NewStringUTF(name);
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeSetPlist(
        JNIEnv *env, jobject thiz, jlong handle, jstring key, jint value) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->raop) return;
    const char *key_c = env->GetStringUTFChars(key, NULL);
    raop_set_plist(ctx->raop, key_c, value);
    env->ReleaseStringUTFChars(key, key_c);
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeSetH265Enabled(
        JNIEnv *env, jobject thiz, jlong handle, jboolean enabled) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx) return;
    ctx->cb_ctx.h265_enabled = enabled ? 1 : 0;
    /* Set DNS-SD feature bit 42 (SupportsScreenMultiCodec) for H265 */
    if (ctx->dnssd) {
        dnssd_set_airplay_features(ctx->dnssd, 42, enabled ? 1 : 0);
    }
}

/* hls plist gates raop.c's hls support; feature bits 0/4 advertise it over dns-sd */
extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeSetHlsEnabled(
        JNIEnv *env, jobject thiz, jlong handle, jboolean enabled) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->raop) return;
    raop_set_plist(ctx->raop, "hls", enabled ? 1 : 0);
    if (ctx->dnssd) {
        dnssd_set_airplay_features(ctx->dnssd, 0, enabled ? 1 : 0);
        dnssd_set_airplay_features(ctx->dnssd, 4, enabled ? 1 : 0);
    }
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeSetLang(
        JNIEnv *env, jobject thiz, jlong handle, jstring lang) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->raop) return;
    const char *c = env->GetStringUTFChars(lang, NULL);
    raop_set_lang(ctx->raop, c);
    env->ReleaseStringUTFChars(lang, c);
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeSetFeature(
        JNIEnv *env, jobject thiz, jlong handle, jint bit, jboolean enabled) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->dnssd) return;
    dnssd_set_airplay_features(ctx->dnssd, bit, enabled ? 1 : 0);
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeSetCodecs(
        JNIEnv *env, jobject thiz, jlong handle, jboolean alac, jboolean aac) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->dnssd) return;
    android_dnssd_set_codecs(ctx->dnssd, alac ? 1 : 0, aac ? 1 : 0);
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeUpdatePlaybackInfo(
        JNIEnv *env, jobject thiz, jlong handle,
        jfloat position, jfloat duration, jfloat rate, jboolean readyToPlay) {

    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx) return;
    android_callbacks_update_playback_info(&ctx->cb_ctx, position, duration, rate, readyToPlay ? 1 : 0);
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeSetDefaultStreamValues(
        JNIEnv *env, jobject thiz, jint sampleRate, jint framesPerBurst) {
    audio_engine_set_default_stream_values(sampleRate, framesPerBurst);
}

extern "C"
JNIEXPORT jboolean JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeServerAudioStart(
        JNIEnv *env, jobject thiz, jlong handle) {
    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->cb_ctx.audio_engine) return JNI_FALSE;
    return audio_engine_start(ctx->cb_ctx.audio_engine) ? JNI_TRUE : JNI_FALSE;
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeServerAudioStop(
        JNIEnv *env, jobject thiz, jlong handle) {
    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (ctx && ctx->cb_ctx.audio_engine) audio_engine_pause(ctx->cb_ctx.audio_engine);
}

extern "C"
JNIEXPORT jboolean JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeServerAudioConfigure(
        JNIEnv *env, jobject thiz, jlong handle, jint cushionMs, jint percentilePct,
        jint oboeBufferFrames, jboolean forceSwAlac, jboolean forceSwAac, jboolean realtimePriority,
        jboolean lowLatency, jboolean benchmarkLog) {
    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->cb_ctx.audio_engine) return JNI_FALSE;
    return audio_engine_configure(ctx->cb_ctx.audio_engine, cushionMs, percentilePct,
                                  oboeBufferFrames, forceSwAlac, forceSwAac, realtimePriority,
                                  lowLatency, benchmarkLog) ? JNI_TRUE : JNI_FALSE;
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeServerAudioSetClientGain(
        JNIEnv *env, jobject thiz, jlong handle, jfloat gain) {
    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (ctx && ctx->cb_ctx.audio_engine) audio_engine_set_client_gain(ctx->cb_ctx.audio_engine, gain);
}

extern "C"
JNIEXPORT void JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeServerAudioFormat(
        JNIEnv *env, jobject thiz, jlong handle, jint ct, jint spf) {
    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (ctx && ctx->cb_ctx.audio_engine) audio_engine_on_format(ctx->cb_ctx.audio_engine, ct, spf);
}

extern "C"
JNIEXPORT jboolean JNICALL
Java_app_opendisplay_android_airplay_bridge_NativeBridge_nativeServerAudioDebug(
        JNIEnv *env, jobject thiz, jlong handle, jobject buf) {
    server_ctx_t *ctx = (server_ctx_t *)(intptr_t)handle;
    if (!ctx || !ctx->cb_ctx.audio_engine || !buf) return JNI_FALSE;
    void *addr = env->GetDirectBufferAddress(buf);
    jlong cap = env->GetDirectBufferCapacity(buf);
    if (!addr || cap <= 0) return JNI_FALSE;
    return audio_engine_get_debug(ctx->cb_ctx.audio_engine, addr, (size_t)cap) ? JNI_TRUE : JNI_FALSE;
}
