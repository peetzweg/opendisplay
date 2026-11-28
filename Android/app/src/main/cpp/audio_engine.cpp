/*
 * Native low-latency audio pipeline for the airplay receiver, three layers:
 *   decoding (AAC/ALAC) -> timing/jitter buffer (spike absorption + PTS sync) -> PCM output
 */

#include <jni.h>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>

#include "audio_engine.h"
#include "audio_decoder.h"
#include "audio_output.h"
#include "log_sink.h"
#include "timeline_buffer.h"

/*
 * debug metrics copied out to Java each overlay poll (see copyDebug). MUST BE PACKED,
 * including nested structs: Java reader (AudioRenderer.audioDebug) mirrors this exact
 * byte layout
 */
struct __attribute__((packed)) AudioDebugData {
    TimelineBuffer::Debug timeline;
    LatencyReporter::Debug decode;
    AudioOutput::Debug output;
    int32_t decodeErrors;  // cumulative packets Decoder::decode() reported as failed
};

struct AudioConfig {
    const int staticCushionMs;   // 0 = adaptive tuner
    const int percentilePct;     // adaptive tuner target percentile
    const int oboeBufferFrames;  // 0 = auto, two bursts in low-latency mode, oboe default in power save
    const bool forceSwAlac;      // embedded ffmpeg software ALAC even when HW available
    const bool forceSwAac;       // embedded ffmpeg software AAC-LC/ELD
    const bool realtimePriority; // decoder: request realtime priority
    const bool lowLatency;       // low-latency decoder + oboe low-latency output
    const bool benchmarkLog;     // periodically log decoder stats
};

struct CodecFormat {
    int spf = 0;  // samples/frame; 0 = not yet announced (decoder uses built-in default)
    bool operator==(const CodecFormat &o) const { return spf == o.spf; }
    bool operator!=(const CodecFormat &o) const { return !(*this == o); }
};

struct AudioEngine {
    AudioEngine(std::shared_ptr<LogSink> log, int sampleRate, int channels)
        : mLog(std::move(log)), mSampleRate(sampleRate), mChannels(channels) {
        mQueued[ctIndex(CT_ALAC)].store(CodecFormat{352}, std::memory_order_relaxed);
        mQueued[ctIndex(CT_AAC_LC)].store(CodecFormat{1024}, std::memory_order_relaxed);
        mQueued[ctIndex(CT_AAC_ELD)].store(CodecFormat{480}, std::memory_order_relaxed);
    }

    ~AudioEngine() {
        delete mPending.load(std::memory_order_relaxed);
    }

    bool configure(const AudioConfig &cfg) {
        std::lock_guard<std::mutex> lk(mRebuildLock);
        if (!mApplied) {
            initInternals(cfg);
            return true;
        }
        // engine may be in use: decode() applies the queued config
        delete mPending.exchange(new AudioConfig(cfg), std::memory_order_release);
        return true;
    }

    bool start() {
        std::lock_guard<std::mutex> lk(mRebuildLock);
        mRunning = true;
        if (mOutput && !mOutputActive) {
            mTimeline->flushAndReprime();
            mOutputActive = mOutput->start();
        }
        return mOutputActive;
    }

    void pause() {
        std::lock_guard<std::mutex> lk(mRebuildLock);
        mRunning = false;
        if (mOutput && mOutputActive) {
            mOutput->stop();
            mOutputActive = false;
        }
    }

    // touches decoder: must not run concurrently with decode()
    void stop() {
        if (mOutput) mOutput->stop();
        mOutputActive = false;
        mDecoder = {};
    }

    void setClientGain(float g) {
        std::lock_guard<std::mutex> lk(mRebuildLock);
        mClientGain = g;
        if (mOutput) mOutput->setClientGain(g);
    }

    void onFormat(int ct, int spf) {
        const int i = ctIndex(ct);
        if (i < 0 || spf <= 0) return;
        mQueued[i].store(CodecFormat{spf}, std::memory_order_release);
    }

    bool copyDebug(void *dst, size_t dstLen) {
        if (dstLen < sizeof(AudioDebugData)) return false;
        {
            // never block: return stale data if lock in use
            std::unique_lock<std::mutex> lk(mRebuildLock, std::try_to_lock);
            if (lk.owns_lock() && mOutput) {
                mDebug.timeline = mTimeline->debugInfo();
                mDebug.decode = mDecLatency.debugInfo();
                mDebug.output = mOutput->debugInfo();
                mDebug.decodeErrors = mDecodeErrors.load(std::memory_order_relaxed);
            }
        }
        memcpy(dst, &mDebug, sizeof(mDebug));
        return true;
    }

    // touches decoder: must not run concurrently with stop()
    void decode(const uint8_t *data, size_t len, int ct, int64_t ptsNs) {
        if (!mTimeline) return;
        if (mPending.load(std::memory_order_relaxed)) {
            if (AudioConfig *raw = mPending.exchange(nullptr, std::memory_order_acquire)) {
                std::unique_ptr<AudioConfig> c(raw);
                mDecoder = {};
                std::lock_guard<std::mutex> lk(mRebuildLock);
                if (mOutputActive) mOutput->stop();
                mOutput.reset();
                initInternals(*c);
                mOutputActive = mRunning ? mOutput->start() : false;
            }
        }

        const int ci = ctIndex(ct);
        const CodecFormat wantConfig = ci >= 0 ? mQueued[ci].load(std::memory_order_acquire) : CodecFormat{};
        // transient codec-service failure does not mute entire session
        const bool changed = ct != mDecoder.ct || wantConfig != mDecoder.format;
        if (changed || (!mDecoder.decoder && monoNs() >= mRetryAtNs)) {
            mDecoder = {}; // release old decoder first to free resources
            mDecoder = {ct, wantConfig,
                        makeDecoder(ct, wantConfig.spf, mSampleRate, mChannels, *mTimeline,
                                    mDecLatency, *mLog,
                                    ct == CT_ALAC ? mApplied->forceSwAlac : mApplied->forceSwAac,
                                    mApplied->realtimePriority, mApplied->lowLatency)};
            mRetryAtNs = mDecoder.decoder ? 0 : monoNs() + DECODER_RETRY_NS;
            // codec switch is definitely a discontinuity
            mTimeline->reanchorTracker();
        }
        if (mDecoder.decoder && !mDecoder.decoder->decode(data, len, ptsNs))
            mDecodeErrors.fetch_add(1, std::memory_order_relaxed);
    }

private:
    static int ctIndex(int ct) {
        switch (ct) {
            case CT_ALAC:    return 0;
            case CT_AAC_LC:  return 1;
            case CT_AAC_ELD: return 2;
            default:         return -1;
        }
    }

    void initInternals(const AudioConfig &cfg) {
        mDecLatency.setEnableLogging(cfg.benchmarkLog);
        mTimeline = std::make_shared<TimelineBuffer>(mSampleRate, mChannels,
                                                     cfg.staticCushionMs, cfg.percentilePct);
        mOutput = AudioOutput::create(mSampleRate, mChannels, cfg.oboeBufferFrames,
                                      cfg.lowLatency, mTimeline, mLog);
        mOutput->setClientGain(mClientGain);  // carry current level across rebuild
        mApplied = std::make_unique<AudioConfig>(cfg);
    }

    const int mSampleRate;
    const int mChannels;
    std::unique_ptr<AudioConfig> mApplied;
    std::shared_ptr<LogSink> mLog;

    // thread safety: decode thread reads mTimeline/mOutput unguarded (nothing else writes them outside teardown) and writes them under mRebuildLock
    // all other threads read them under mRebuildLock; mDecoder is decode-thread-only
    // teardown stop() requires caller to guarantee no in-flight or future decode() calls

    std::mutex mRebuildLock;
    std::shared_ptr<TimelineBuffer> mTimeline; // guarded by mRebuildLock
    std::shared_ptr<AudioOutput> mOutput;      // guarded by mRebuildLock
    bool mRunning = false;                     // requested output state, guarded by mRebuildLock
    bool mOutputActive = false;                // actual output state, guarded by mRebuildLock
    float mClientGain = 1.0f;                  // last-set sender gain, guarded by mRebuildLock

    LatencyReporter mDecLatency{"decode", *mLog};
    // decoder + codec/config it was built with
    // ct == -1: not initialized; ct != -1 && decoder == nullptr: build for ct failed
    struct CreatedDecoder {
        int ct = -1;
        CodecFormat format;
        std::unique_ptr<Decoder> decoder;
    };
    CreatedDecoder mDecoder;
    static constexpr int64_t DECODER_RETRY_NS = 1'000'000'000LL;
    int64_t mRetryAtNs = 0;  // earliest retry of failed decoder

    // wanted config per codec, keyed by ctIndex
    static constexpr int NUM_CT = 3;
    std::atomic<CodecFormat> mQueued[NUM_CT] = {};

    // pending config change, applied on next decode()
    std::atomic<AudioConfig *> mPending{nullptr};

    AudioDebugData mDebug{};
    std::atomic<int32_t> mDecodeErrors{0};
};

AudioEngine *audio_engine_create(std::shared_ptr<LogSink> log, int sampleRate, int channels) {
    if (!log) return nullptr;
    return new AudioEngine(std::move(log), sampleRate, channels);
}



extern "C" {

void audio_engine_set_default_stream_values(int sampleRate, int framesPerBurst) {
    // configures oboe's OpenSL ES backend for pre-AAudio devices
    if (sampleRate > 0) oboe::DefaultStreamValues::SampleRate = sampleRate;
    if (framesPerBurst > 0) oboe::DefaultStreamValues::FramesPerBurst = framesPerBurst;
}

bool audio_engine_configure(AudioEngine *engine, int cushionMs, int percentilePct,
                            int oboeBufferFrames, bool forceSwAlac, bool forceSwAac,
                            bool realtimePriority, bool lowLatency, bool benchmarkLog) {
    if (!engine) return false;
    return engine->configure({cushionMs, percentilePct, oboeBufferFrames, forceSwAlac, forceSwAac,
                              realtimePriority, lowLatency, benchmarkLog});
}

void audio_engine_set_client_gain(AudioEngine *engine, float gain) {
    if (engine) engine->setClientGain(gain);
}

void audio_engine_on_format(AudioEngine *engine, int ct, int spf) {
    if (engine) engine->onFormat(ct, spf);
}

bool audio_engine_start(AudioEngine *engine) {
    return engine && engine->start();
}

void audio_engine_pause(AudioEngine *engine) {
    if (engine) engine->pause();
}

bool audio_engine_get_debug(AudioEngine *engine, void *dst, size_t dstLen) {
    if (!engine || !dst) return false;
    return engine->copyDebug(dst, dstLen);
}

void audio_engine_destroy(AudioEngine *engine) {
    if (!engine) return;
    engine->stop();
    delete engine;
}

// decode straight from RAOP audio callback, no JNI crossing
void audio_engine_decode(AudioEngine *engine, const uint8_t *data, int len, int ct, int64_t pts_ns) {
    if (engine && data && len > 0) {
        engine->decode(data, (size_t)len, ct, pts_ns);
    }
}

}
