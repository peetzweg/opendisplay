#ifndef ANDROID_RAOP_CALLBACKS_H
#define ANDROID_RAOP_CALLBACKS_H

#include <jni.h>
#include <pthread.h>
#include "raop.h"
#include "audio_engine.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    JavaVM *jvm;
    jobject callback_obj;
    raop_t *raop;
    jmethodID on_video_data;
    jmethodID on_audio_format;
    jmethodID on_video_size;
    jmethodID on_client_volume;
    jmethodID on_client_volume_query;
    jmethodID on_audio_teardown;
    jmethodID on_conn_init;
    jmethodID on_conn_destroy;
    jmethodID on_conn_reset;
    jmethodID on_display_pin;
    jmethodID on_metadata;
    jmethodID on_coverart;
    jmethodID on_progress;
    jmethodID on_dacp_id;
    jmethodID on_mirror_running;
    jmethodID on_video_play;
    jmethodID on_video_scrub;
    jmethodID on_video_rate;
    jmethodID on_video_stop;
    jmethodID on_video_session_poll;
    int h265_enabled;
    int require_pin;
    char *registered_keys[16];
    int registered_count;
    /* playback info snapshot pushed by kotlin, read on the native httpd thread */
    pthread_mutex_t playback_info_lock;
    double playback_position;
    double playback_duration;
    float playback_rate;
    int playback_ready;
    /* holds the /play response until the player is ready, so self-driven senders (macOS)
       establish their timeline after the real duration is known, not at duration 0 */
    pthread_cond_t play_ready_cond;
    int play_ready;
    AudioEngine *audio_engine;
} android_callback_ctx_t;

void android_callbacks_init(android_callback_ctx_t *ctx, JNIEnv *env, jobject callback_obj);
void android_callbacks_destroy(android_callback_ctx_t *ctx, JNIEnv *env);
void android_callbacks_fill(raop_callbacks_t *cbs, android_callback_ctx_t *ctx);
void android_callbacks_update_playback_info(android_callback_ctx_t *ctx, double position,
                                             double duration, float rate, int ready);

#ifdef __cplusplus
}
#endif

#endif
