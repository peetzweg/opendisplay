/*
 * Implements raop_callbacks_t by forwarding to Java/Kotlin via JNI.
 * All callbacks fire from RAOP's internal pthreads, so we AttachCurrentThread.
 */

#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <android/log.h>
#include "android_raop_callbacks.h"
#include "audio_engine.h"

#define TAG "AirPlayNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static JNIEnv *_get_env(android_callback_ctx_t *ctx) {
    JNIEnv *env = NULL;
    int status = (*ctx->jvm)->GetEnv(ctx->jvm, (void **)&env, JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        (*ctx->jvm)->AttachCurrentThread(ctx->jvm, &env, NULL);
    }
    /* Clear any pending exception from a previous callback on this thread,
       otherwise JNI calls like NewByteArray will fatally abort. */
    if (env && (*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    return env;
}

void android_callbacks_init(android_callback_ctx_t *ctx, JNIEnv *env, jobject callback_obj) {
    (*env)->GetJavaVM(env, &ctx->jvm);
    ctx->callback_obj = (*env)->NewGlobalRef(env, callback_obj);
    ctx->h265_enabled = 1;
    ctx->require_pin = 0;
    ctx->registered_count = 0;
    ctx->audio_engine = NULL;
    memset(ctx->registered_keys, 0, sizeof(ctx->registered_keys));

    pthread_mutex_init(&ctx->playback_info_lock, NULL);
    pthread_cond_init(&ctx->play_ready_cond, NULL);
    ctx->play_ready = 0;
    ctx->playback_position = 0.0;
    /* -1.0 is the video finished sentinel, reserved for _video_stop */
    ctx->playback_duration = 0.0;
    ctx->playback_rate = 0.0f;
    ctx->playback_ready = 0;

    jclass cls = (*env)->GetObjectClass(env, callback_obj);
    ctx->on_video_data = (*env)->GetMethodID(env, cls, "onVideoData", "([BJZ)V");
    ctx->on_audio_format = (*env)->GetMethodID(env, cls, "onAudioFormat", "(IIZ)V");
    ctx->on_video_size = (*env)->GetMethodID(env, cls, "onVideoSize", "(FFFF)V");
    ctx->on_client_volume = (*env)->GetMethodID(env, cls, "onClientVolume", "(F)V");
    ctx->on_client_volume_query = (*env)->GetMethodID(env, cls, "onClientVolumeQuery", "()F");
    ctx->on_audio_teardown = (*env)->GetMethodID(env, cls, "onAudioTeardown", "()V");
    ctx->on_conn_init = (*env)->GetMethodID(env, cls, "onConnectionInit", "()V");
    ctx->on_conn_destroy = (*env)->GetMethodID(env, cls, "onConnectionDestroy", "()V");
    ctx->on_conn_reset = (*env)->GetMethodID(env, cls, "onConnectionReset", "(I)V");
    ctx->on_display_pin = (*env)->GetMethodID(env, cls, "onDisplayPin", "(Ljava/lang/String;)V");
    ctx->on_metadata = (*env)->GetMethodID(env, cls, "onMetadata", "([B)V");
    ctx->on_coverart = (*env)->GetMethodID(env, cls, "onCoverArt", "([B)V");
    ctx->on_progress = (*env)->GetMethodID(env, cls, "onProgress", "(JJJ)V");
    ctx->on_dacp_id = (*env)->GetMethodID(env, cls, "onDacpId", "(Ljava/lang/String;Ljava/lang/String;)V");
    ctx->on_mirror_running = (*env)->GetMethodID(env, cls, "onMirrorRunning", "(Z)V");
    ctx->on_video_play = (*env)->GetMethodID(env, cls, "onVideoPlay", "(Ljava/lang/String;F)V");
    ctx->on_video_scrub = (*env)->GetMethodID(env, cls, "onVideoScrub", "(F)V");
    ctx->on_video_rate = (*env)->GetMethodID(env, cls, "onVideoRate", "(F)V");
    ctx->on_video_stop = (*env)->GetMethodID(env, cls, "onVideoStop", "()V");
    ctx->on_video_session_poll = (*env)->GetMethodID(env, cls, "onVideoSessionPoll", "()V");
    (*env)->DeleteLocalRef(env, cls);
}

void android_callbacks_destroy(android_callback_ctx_t *ctx, JNIEnv *env) {
    if (ctx->callback_obj) {
        (*env)->DeleteGlobalRef(env, ctx->callback_obj);
        ctx->callback_obj = NULL;
    }
    for (int i = 0; i < ctx->registered_count; i++) {
        free(ctx->registered_keys[i]);
        ctx->registered_keys[i] = NULL;
    }
    ctx->registered_count = 0;
    pthread_cond_destroy(&ctx->play_ready_cond);
    pthread_mutex_destroy(&ctx->playback_info_lock);
}

void android_callbacks_update_playback_info(android_callback_ctx_t *ctx, double position,
                                             double duration, float rate, int ready) {
    pthread_mutex_lock(&ctx->playback_info_lock);
    ctx->playback_position = position;
    ctx->playback_duration = duration;
    ctx->playback_rate = rate;
    ctx->playback_ready = ready;
    if (ready && !ctx->play_ready) {
        ctx->play_ready = 1;
        pthread_cond_signal(&ctx->play_ready_cond);
    }
    pthread_mutex_unlock(&ctx->playback_info_lock);
}

/* --- RAOP callback implementations --- */

static void _audio_process(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    if (!ctx->audio_engine || !data->data || data->data_len <= 0) return;
    audio_engine_decode(ctx->audio_engine, data->data, data->data_len,
                        (int)data->ct, (int64_t)data->ntp_time_local);
}

static void _video_process(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env || !data->data || data->data_len <= 0) return;
    /* raop_rtp_mirror marks undecryptable packets by setting byte 0 (start code) to 1 */
    if (data->data[0]) {
        LOGE("video packet decryption failed, dropping %d bytes", data->data_len);
        return;
    }

    jbyteArray arr = (*env)->NewByteArray(env, data->data_len);
    (*env)->SetByteArrayRegion(env, arr, 0, data->data_len, (jbyte *)data->data);
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_video_data,
                           arr, (jlong)data->ntp_time_local, (jboolean)data->is_h265);
    (*env)->DeleteLocalRef(env, arr);
}

static void _conn_init(void *cls) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    /* fires for every connection including the player's own hls fetches: clear only a stale sentinel */
    pthread_mutex_lock(&ctx->playback_info_lock);
    if (ctx->playback_duration == -1.0) {
        ctx->playback_position = 0.0;
        ctx->playback_duration = 0.0;
        ctx->playback_rate = 0.0f;
        ctx->playback_ready = 0;
    }
    pthread_mutex_unlock(&ctx->playback_info_lock);
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_conn_init);
}

static void _conn_destroy(void *cls) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_conn_destroy);
}

static void _conn_reset(void *cls, int reason) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_conn_reset, (jint)reason);
}

static void _audio_set_volume(void *cls, float volume) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_client_volume, (jfloat)volume);
}

static void _audio_get_format(void *cls, unsigned char *ct, unsigned short *spf,
                               bool *usingScreen, bool *isMedia, uint64_t *audioFormat) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_audio_format,
                           (jint)*ct, (jint)*spf, (jboolean)*usingScreen);
}

static void _video_report_size(void *cls, float *w_src, float *h_src, float *w, float *h) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_video_size,
                           (jfloat)*w_src, (jfloat)*h_src, (jfloat)*w, (jfloat)*h);
}

static void _display_pin(void *cls, char *pin) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    
    /* certain senders trigger pair-pin-start even when we advertise no auth */
    if (!ctx->require_pin) return;

    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    jstring jpin = (*env)->NewStringUTF(env, pin);
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_display_pin, jpin);
    (*env)->DeleteLocalRef(env, jpin);
}

/* Stubs for less critical callbacks */
static void _noop(void *cls) { (void)cls; }
static void _video_pause(void *cls) { LOGI("video_pause"); }
static void _video_resume(void *cls) { LOGI("video_resume"); }
static void _conn_feedback(void *cls) { (void)cls; }
static void _video_stop(void *cls);
static void _video_reset(void *cls, reset_type_t t) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    LOGI("video_reset %d", t);
    if (t == RESET_TYPE_HLS_SHUTDOWN || t == RESET_TYPE_HLS_EOS) {
        _video_stop(cls);
    }
    if (t == RESET_TYPE_HLS_CONN_CLOSED) {
        /* abandoned only if paused and ready: rate alone is also 0 while buffering */
        pthread_mutex_lock(&ctx->playback_info_lock);
        int paused = ctx->playback_ready && ctx->playback_rate <= 0.0f;
        pthread_mutex_unlock(&ctx->playback_info_lock);
        if (paused) {
            _video_stop(cls);
        }
    }
    if (t == RESET_TYPE_HLS_SHUTDOWN && ctx->raop) {
        raop_remove_hls_connections(ctx->raop);
    }
}
static void _audio_flush(void *cls) { LOGI("audio_flush"); }

static void _audio_stop_coverart_rendering(void *cls) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    LOGI("audio_teardown");
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_audio_teardown);
}
static void _video_flush(void *cls) { LOGI("video_flush"); }
static double _audio_set_client_volume(void *cls) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env) return 0.0;
    return (double)(*env)->CallFloatMethod(env, ctx->callback_obj, ctx->on_client_volume_query);
}
static void _audio_set_metadata(void *cls, const void *buf, int len) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env || !buf || len <= 0) return;
    jbyteArray arr = (*env)->NewByteArray(env, len);
    (*env)->SetByteArrayRegion(env, arr, 0, len, (jbyte *)buf);
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_metadata, arr);
    (*env)->DeleteLocalRef(env, arr);
}

static void _audio_set_coverart(void *cls, const void *buf, int len) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env || !buf || len <= 0) return;
    jbyteArray arr = (*env)->NewByteArray(env, len);
    (*env)->SetByteArrayRegion(env, arr, 0, len, (jbyte *)buf);
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_coverart, arr);
    (*env)->DeleteLocalRef(env, arr);
}

static void _audio_remote_control_id(void *cls, const char *dacp_id, const char *active_remote) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    jstring jdacp = (*env)->NewStringUTF(env, dacp_id ? dacp_id : "");
    jstring jremote = (*env)->NewStringUTF(env, active_remote ? active_remote : "");
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_dacp_id, jdacp, jremote);
    (*env)->DeleteLocalRef(env, jdacp);
    (*env)->DeleteLocalRef(env, jremote);
}

static void _audio_set_progress(void *cls, uint32_t *start, uint32_t *curr, uint32_t *end) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env || !start || !curr || !end) return;
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_progress,
                           (jlong)*start, (jlong)*curr, (jlong)*end);
}

static void _mirror_video_running(void *cls, bool running) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    LOGI("mirror running: %d", running);
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_mirror_running, (jboolean)running);
}
static void _register_client(void *cls, const char *device_id, const char *pk_str, const char *name) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    (void)device_id; (void)name;
    if (ctx->registered_count >= 16) return;
    for (int i = 0; i < ctx->registered_count; i++) {
        if (ctx->registered_keys[i] && strcmp(ctx->registered_keys[i], pk_str) == 0) return;
    }
    ctx->registered_keys[ctx->registered_count++] = strdup(pk_str);
    LOGI("registered client pk (slot %d)", ctx->registered_count);
}

static bool _check_register(void *cls, const char *pk_str) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    for (int i = 0; i < ctx->registered_count; i++) {
        if (ctx->registered_keys[i] && strcmp(ctx->registered_keys[i], pk_str) == 0) return true;
    }
    return false;
}

/* --- AirPlay Video (HLS) playback callbacks --- */

static void _video_play(void *cls, const char *location, const float start_position) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    LOGI("video_play: %s @ %.2fs", location ? location : "(null)", start_position);
    pthread_mutex_lock(&ctx->playback_info_lock);
    ctx->play_ready = 0;
    pthread_mutex_unlock(&ctx->playback_info_lock);
    android_callbacks_update_playback_info(ctx, start_position, 0.0, 0.0f, 0);
    JNIEnv *env = _get_env(ctx);
    if (!env || !location) return;
    jstring jloc = (*env)->NewStringUTF(env, location);
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_video_play, jloc, (jfloat)start_position);
    (*env)->DeleteLocalRef(env, jloc);
}

/* self-driven senders (macOS) latch their scrubber timeline at /play; hold the response
   until the player reports ready so that read must carry the real duration */
static void _video_wait_ready(void *cls) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 10; // hold for max 10s
    pthread_mutex_lock(&ctx->playback_info_lock);
    while (!ctx->play_ready) {
        if (pthread_cond_timedwait(&ctx->play_ready_cond, &ctx->playback_info_lock, &ts) == ETIMEDOUT) break;
    }
    pthread_mutex_unlock(&ctx->playback_info_lock);
}

static void _video_scrub(void *cls, const float position) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_video_scrub, (jfloat)position);
}

static void _video_rate(void *cls, const float rate) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_video_rate, (jfloat)rate);
}

static void _video_stop(void *cls) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    android_callbacks_update_playback_info(ctx, 0.0, -1.0, 0.0f, 0);
    JNIEnv *env = _get_env(ctx);
    if (!env) return;
    (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_video_stop);
}

/* httpd thread: reads the kotlin-pushed snapshot, never calls into the player */
static void _video_acquire_playback_info(void *cls, playback_info_t *info) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    pthread_mutex_lock(&ctx->playback_info_lock);
    info->position = ctx->playback_position;
    info->duration = ctx->playback_duration;
    info->rate = ctx->playback_rate;
    info->ready_to_play = ctx->playback_ready;
    info->playback_buffer_empty = false;
    info->playback_buffer_full = true;
    info->playback_likely_to_keep_up = true;
    info->seek_start = 0.0;
    info->seek_duration = ctx->playback_duration > 0.0 ? ctx->playback_duration : 0.0;
    pthread_mutex_unlock(&ctx->playback_info_lock);
    /* polls are the earliest video-channel signal, starting ~1s before /play */
    JNIEnv *env = _get_env(ctx);
    if (env) {
        (*env)->CallVoidMethod(env, ctx->callback_obj, ctx->on_video_session_poll);
    }
}

static float _video_playlist_remove(void *cls) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    pthread_mutex_lock(&ctx->playback_info_lock);
    double position = ctx->playback_position;
    pthread_mutex_unlock(&ctx->playback_info_lock);
    return (float) position;
}

static int _video_set_codec(void *cls, video_codec_t codec) {
    android_callback_ctx_t *ctx = (android_callback_ctx_t *)cls;
    LOGI("video_set_codec: %d (h265_enabled=%d)", codec, ctx->h265_enabled);
    if (codec == VIDEO_CODEC_H265 && !ctx->h265_enabled) return -1;
    return 0;
}

void android_callbacks_fill(raop_callbacks_t *cbs, android_callback_ctx_t *ctx) {
    memset(cbs, 0, sizeof(raop_callbacks_t));
    cbs->cls = ctx;

    cbs->audio_process = _audio_process;
    cbs->video_process = _video_process;
    cbs->video_pause = _video_pause;
    cbs->video_resume = _video_resume;
    cbs->conn_feedback = _conn_feedback;
    cbs->conn_reset = _conn_reset;
    cbs->video_reset = _video_reset;
    cbs->conn_init = _conn_init;
    cbs->conn_destroy = _conn_destroy;
    cbs->audio_flush = _audio_flush;
    cbs->video_flush = _video_flush;
    cbs->audio_set_client_volume = _audio_set_client_volume;
    cbs->audio_set_volume = _audio_set_volume;
    cbs->audio_set_metadata = _audio_set_metadata;
    cbs->audio_set_coverart = _audio_set_coverart;
    cbs->audio_stop_coverart_rendering = _audio_stop_coverart_rendering;
    cbs->audio_remote_control_id = _audio_remote_control_id;
    cbs->audio_set_progress = _audio_set_progress;
    cbs->audio_get_format = _audio_get_format;
    cbs->video_report_size = _video_report_size;
    cbs->mirror_video_running = _mirror_video_running;
    cbs->display_pin = _display_pin;
    cbs->video_set_codec = _video_set_codec;
    cbs->on_video_play = _video_play;
    cbs->on_video_wait_ready = _video_wait_ready;
    cbs->on_video_scrub = _video_scrub;
    cbs->on_video_rate = _video_rate;
    cbs->on_video_stop = _video_stop;
    cbs->on_video_acquire_playback_info = _video_acquire_playback_info;
    cbs->on_video_playlist_remove = _video_playlist_remove;
    if (ctx->require_pin) {
        cbs->check_register = _check_register;
        cbs->register_client = _register_client;
    }
}
