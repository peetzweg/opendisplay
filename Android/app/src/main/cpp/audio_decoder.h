#ifndef AUDIO_DECODER_H
#define AUDIO_DECODER_H

#include <android/log.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <atomic>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/common.h>
#include <libavutil/log.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
}

#include "audio_time.h"
#include "log_sink.h"
#include "timeline_buffer.h"

static constexpr int CT_ALAC = 2, CT_AAC_LC = 4, CT_AAC_ELD = 8;

class LatencyReporter {
public:
    LatencyReporter(const char *name, LogSink &log) : mName(name), mLog(log) {}

    // no concurrent callers
    void record(int64_t ns) {
        if (mN == 0 || ns < mMinNs) mMinNs = ns;
        if (ns > mMaxNs) mMaxNs = ns;
        mSumNs += ns;
        if (++mN >= UPDATE_FREQ) {
            const int32_t meanUs = (int32_t)(mSumNs / mN / 1000);
            mMeanUs.store(meanUs, std::memory_order_relaxed);
            mMaxUs.store((int32_t)(mMaxNs / 1000), std::memory_order_relaxed);
            if (mLogging.load(std::memory_order_relaxed)) {
                mLog.info("%s latency: n=%lld min=%.2fms mean=%.2fms max=%.2fms (held=%zu)",
                          mName, (long long)mN, mMinNs / 1e6, meanUs / 1000.0, mMaxNs / 1e6,
                          mHeld.load(std::memory_order_relaxed));
            }
            mN = 0; mSumNs = 0; mMinNs = 0; mMaxNs = 0;
        }
    }

    // # of operations currently in flight
    void setHeld(size_t n) { mHeld.store(n, std::memory_order_relaxed); }

    void setEnableLogging(bool on) { mLogging.store(on, std::memory_order_relaxed); }

    // packed: nests into AudioDebugData with fixed layout
    struct __attribute__((packed)) Debug {
        int32_t meanUs, maxUs;
        uint16_t held;  // operations in flight
    };
    Debug debugInfo() const {
        Debug d{};
        d.meanUs = mMeanUs.load(std::memory_order_relaxed);
        d.maxUs = mMaxUs.load(std::memory_order_relaxed);
        d.held = (uint16_t)mHeld.load(std::memory_order_relaxed);
        return d;
    }

private:
    static constexpr int64_t UPDATE_FREQ = 200;

    const char *mName;
    LogSink &mLog;
    std::atomic<bool> mLogging{false};
    int64_t mN = 0, mSumNs = 0, mMinNs = 0, mMaxNs = 0;  // producer-thread accumulators
    std::atomic<int32_t> mMeanUs{0}, mMaxUs{0};
    std::atomic<size_t> mHeld{0};
};

// https://stackoverflow.com/a/44095383
/*
 * SPSC queue to measure AMediaCodec decode latency: MediaCodec can't carry side data
 * across decode, so track queue times ourselves
 */
struct LatencyProbe {
    struct Entry { int64_t ptsUs; int64_t queueNs; };
    static constexpr uint64_t CAP = 64;
    Entry mBuf[CAP] = {};
    std::atomic<uint64_t> mWrite{0};
    std::atomic<uint64_t> mRead{0};

    // call before feeding frame into MediaCodec
    void record(int64_t ptsUs, int64_t queueNs) {
        const uint64_t w = mWrite.load(std::memory_order_relaxed);
        mBuf[w % CAP] = {ptsUs, queueNs};
        mWrite.store(w + 1, std::memory_order_release);
    }

    // call after frame comes back; latency ns for ptsUs, or -1 if not recorded
    int64_t match(int64_t ptsUs, int64_t nowNs) {
        uint64_t r = mRead.load(std::memory_order_relaxed);
        const uint64_t w = mWrite.load(std::memory_order_acquire);
        for (; r < w; r++) {
            if (mBuf[r % CAP].ptsUs == ptsUs) {
                const int64_t lat = nowNs - mBuf[r % CAP].queueNs;
                mRead.store(r + 1, std::memory_order_release);
                return lat;
            }
        }
        return -1;
    }

    size_t inFlight() const {
        return (size_t)(mWrite.load(std::memory_order_relaxed) -
                        mRead.load(std::memory_order_relaxed));
    }
};

// decodes one encoded airplay audio packet and pushes PCM onto the timeline
class Decoder {
public:
    virtual ~Decoder() = default;
    // called on RAOP receive thread; returns false = non-critical decode error
    virtual bool decode(const uint8_t *data, size_t len, int64_t ptsNs) = 0;
};

// 24-byte ALACSpecificConfig "magic cookie" (big-endian)
static inline void buildAlacMagicCookie(uint8_t out[24], int sampleRate, int channels, int spf) {
    const int frameLength = spf;
    const int bitDepth = 16, pb = 40, mb = 10, kb = 14;
    out[0] = (frameLength >> 24) & 0xFF;
    out[1] = (frameLength >> 16) & 0xFF;
    out[2] = (frameLength >> 8) & 0xFF;
    out[3] = frameLength & 0xFF;
    out[4] = 0;                /* compatibleVersion */
    out[5] = (uint8_t)bitDepth;
    out[6] = (uint8_t)pb;
    out[7] = (uint8_t)mb;
    out[8] = (uint8_t)kb;
    out[9] = (uint8_t)channels;
    out[10] = 0; out[11] = 0xFF; /* maxRun = 255 (big-endian) */
    out[12] = out[13] = out[14] = out[15] = 0; /* maxFrameBytes */
    out[16] = out[17] = out[18] = out[19] = 0; /* avgBitRate */
    out[20] = (sampleRate >> 24) & 0xFF;
    out[21] = (sampleRate >> 16) & 0xFF;
    out[22] = (sampleRate >> 8) & 0xFF;
    out[23] = sampleRate & 0xFF;
}

// cookie wrapped in its atom: size (4) + 'alac' + version/flags (4) + ALACSpecificConfig
static inline void buildAlacAtomCookie(uint8_t out[36], int sampleRate, int channels, int spf) {
    static const uint8_t hdr[12] = {0x00, 0x00, 0x00, 0x24, 'a', 'l', 'a', 'c', 0, 0, 0, 0};
    memcpy(out, hdr, sizeof(hdr));
    buildAlacMagicCookie(out + 12, sampleRate, channels, spf);
}

// request the in process AAC decoder when available
static constexpr const char *AAC_INPROC_DECODER = "c2.android.inproc.aac.decoder";

struct CodecConfig {
    const char *mime;
    const char *preferName;
    AVCodecID ffmpegId;
    int aacProfile;
    int sampleRate, channels;
    uint8_t csd[36];
    size_t csdLen;
};

static inline std::optional<CodecConfig> codecConfig(int ct, int spf, int sampleRate, int channels) {
    CodecConfig c{};
    c.sampleRate = sampleRate;
    c.channels = channels;
    if (ct == CT_ALAC) {
        c.mime = "audio/alac";
        c.ffmpegId = AV_CODEC_ID_ALAC;
        buildAlacAtomCookie(c.csd, sampleRate, channels, spf);
        c.csdLen = 36;
        return c;
    }
    c.mime = "audio/mp4a-latm";
    c.preferName = AAC_INPROC_DECODER;
    c.ffmpegId = AV_CODEC_ID_AAC;
    if (ct == CT_AAC_ELD) {
        // AAC-ELD AudioSpecificConfig: AOT=39, 44100, stereo, then ELDSpecificConfig
        c.aacProfile = 39; c.csd[0] = 0xF8; c.csd[1] = 0xE8;
        c.csd[2] = (spf == 512) ? 0x40 : 0x50; c.csd[3] = 0x00; c.csdLen = 4;
    } else if (ct == CT_AAC_LC) {
        // AAC-LC AudioSpecificConfig: AOT=2, 44100, stereo, then GASpecificConfig
        c.aacProfile = 2; c.csd[0] = 0x12;
        c.csd[1] = (spf == 960) ? 0x14 : 0x10; c.csdLen = 2;
    } else {
        return std::nullopt;
    }
    return c;
}

// AMediaCodec decoder; output dequeued on separate thread, shaves ~10ms latency
class MediaCodecDecoder : public Decoder {
public:
    // takes ownership of already-created+started codec
    MediaCodecDecoder(AMediaCodec *codec, TimelineBuffer &timeline, LatencyReporter &lat)
        : mCodec(codec), mTimeline(timeline), mLat(lat) {
        mDrainRun.store(true, std::memory_order_relaxed);
        mDrainThread = std::thread(&MediaCodecDecoder::drainLoop, this);
    }

    ~MediaCodecDecoder() override {
        // stop drain thread before touching the codec it reads from
        if (mDrainThread.joinable()) {
            mDrainRun.store(false, std::memory_order_relaxed);
            mDrainThread.join();
        }
        if (mCodec) { AMediaCodec_stop(mCodec); AMediaCodec_delete(mCodec); }
    }

    bool decode(const uint8_t *data, size_t len, int64_t ptsNs) override {
        ssize_t ii = AMediaCodec_dequeueInputBuffer(mCodec, 5000);
        if (ii < 0) return false;
        size_t cap = 0;
        uint8_t *in = AMediaCodec_getInputBuffer(mCodec, (size_t)ii, &cap);
        if (!in) return false;
        const size_t n = len < cap ? len : cap;
        memcpy(in, data, n);
        mProbe.record((int64_t)(ptsNs / 1000), monoNs());
        // still queue packets that are too large, but truncate them and report as error
        return AMediaCodec_queueInputBuffer(mCodec, (size_t)ii, 0, n, (uint64_t)(ptsNs / 1000), 0) ==
                   AMEDIA_OK && n == len;
    }

private:
    static constexpr int64_t DRAIN_TIMEOUT_US = 20000;

    void drainLoop() {
        AMediaCodecBufferInfo info;
        while (mDrainRun.load(std::memory_order_relaxed)) {
            ssize_t oi = AMediaCodec_dequeueOutputBuffer(mCodec, &info, DRAIN_TIMEOUT_US);
            if (oi < 0) continue;  // timeout / format / buffers changed
            size_t osz = 0;
            uint8_t *out = AMediaCodec_getOutputBuffer(mCodec, (size_t)oi, &osz);
            if (out && info.size > 0) {
                mTimeline.write((const int16_t *)(out + info.offset),
                                (size_t)info.size / sizeof(int16_t),
                                (int64_t)info.presentationTimeUs * 1000);
            }
            const int64_t nowNs = monoNs();
            AMediaCodec_releaseOutputBuffer(mCodec, (size_t)oi, false);
            const int64_t lat = mProbe.match((int64_t)info.presentationTimeUs, nowNs);
            if (lat >= 0) mLat.record(lat);
            mLat.setHeld(mProbe.inFlight());
        }
    }

    AMediaCodec *mCodec;  // owned
    TimelineBuffer &mTimeline;
    LatencyReporter &mLat;
    LatencyProbe mProbe;
    std::thread mDrainThread;
    std::atomic<bool> mDrainRun{false};
};

static inline void installFfmpegLogcat() {
    static std::once_flag once;
    std::call_once(once, [] {
        av_log_set_level(AV_LOG_WARNING);
        av_log_set_callback([](void *, int level, const char *fmt, va_list vl) {
            if (level > av_log_get_level()) return;
            __android_log_vprint(level <= AV_LOG_ERROR ? ANDROID_LOG_ERROR : ANDROID_LOG_WARN,
                                 "ffmpeg", fmt, vl);
        });
    });
}

// synchronous
class FfmpegDecoder : public Decoder {
public:
    // returns nullptr if codec can't be created/opened
    static std::unique_ptr<FfmpegDecoder> make(const CodecConfig &c, TimelineBuffer &timeline,
                                               LatencyReporter &lat, LogSink &log) {
        installFfmpegLogcat();
        auto dec = std::unique_ptr<FfmpegDecoder>(new FfmpegDecoder(timeline, lat, log));
        if (!dec->init(c)) return nullptr;
        return dec;
    }

    ~FfmpegDecoder() override {
        av_frame_free(&mFrame);
        av_packet_free(&mPkt);
        avcodec_free_context(&mCtx);
    }

    bool decode(const uint8_t *data, size_t len, int64_t ptsNs) override {
        if (len == 0 || len > INT_MAX - AV_INPUT_BUFFER_PADDING_SIZE) return false;
        const int64_t t0 = monoNs();

        // not refcounted
        mPkt->data = const_cast<uint8_t *>(data);
        mPkt->size = (int)len;
        if (avcodec_send_packet(mCtx, mPkt) < 0) return false;

        int64_t pts = ptsNs;
        int ret;
        while ((ret = avcodec_receive_frame(mCtx, mFrame)) == 0) {
            const int n = mFrame->nb_samples;
            if (n <= 0) continue;
            if (!toPcm(n)) {
                mLog.error("ffmpeg %s: unsupported output (fmt=%d ch=%d)", mCtx->codec->name,
                           mFrame->format, mFrame->ch_layout.nb_channels);
                return false;
            }
            mTimeline.write(mPcm.data(), (size_t)n * mChannels, pts);
            pts += (int64_t)n * NS_PER_SEC / mCtx->sample_rate;
        }

        mLat.record(monoNs() - t0);
        mLat.setHeld(0);
        return ret == AVERROR(EAGAIN);
    }

private:
    FfmpegDecoder(TimelineBuffer &timeline, LatencyReporter &lat, LogSink &log)
        : mTimeline(timeline), mLat(lat), mLog(log) {}

    bool init(const CodecConfig &c) {
        const AVCodec *codec = avcodec_find_decoder(c.ffmpegId);
        if (!codec) {
            mLog.error("ffmpeg %s decoder not compiled in", avcodec_get_name(c.ffmpegId));
            return false;
        }
        mCtx = avcodec_alloc_context3(codec);
        if (!mCtx) return false;

        // extradata must be alloced with av_malloc* and have AV_INPUT_BUFFER_PADDING_SIZE of
        // 0-padding at the end
        mCtx->extradata = (uint8_t *)av_mallocz(c.csdLen + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!mCtx->extradata) return false;
        memcpy(mCtx->extradata, c.csd, c.csdLen);
        mCtx->extradata_size = (int)c.csdLen;

        mCtx->sample_rate = c.sampleRate;
        av_channel_layout_default(&mCtx->ch_layout, c.channels);
        mCtx->thread_count = 1;

        if (avcodec_open2(mCtx, codec, nullptr) < 0) {
            mLog.error("ffmpeg %s open failed (rate=%d ch=%d)", codec->name, c.sampleRate, c.channels);
            return false;
        }

        mPkt = av_packet_alloc();
        mFrame = av_frame_alloc();
        mChannels = c.channels;
        return mPkt && mFrame;
    }

    bool toPcm(int n) {
        if (mFrame->ch_layout.nb_channels != mChannels) return false;
        if (mPcm.size() < (size_t)n * mChannels) mPcm.resize((size_t)n * mChannels);
        switch (mFrame->format) {
            case AV_SAMPLE_FMT_S16P:  // alac
                interleave<int16_t>(n, [](int16_t s) { return s; });
                return true;
            case AV_SAMPLE_FMT_FLTP:  // aac, same conversion as libswresample
                interleave<float>(n, [](float s) { return av_clip_int16(lrintf(s * (1 << 15))); });
                return true;
            default:
                return false;
        }
    }

    template <typename T, typename Conv>
    void interleave(int n, Conv conv) {
        for (int c = 0; c < mChannels; c++) {
            const T *p = (const T *)mFrame->data[c];
            for (int i = 0; i < n; i++) mPcm[(size_t)i * mChannels + c] = conv(p[i]);
        }
    }

    AVCodecContext *mCtx = nullptr;  // owned
    AVPacket *mPkt = nullptr;        // owned
    AVFrame *mFrame = nullptr;       // owned
    std::vector<int16_t> mPcm;       // interleave scratch
    TimelineBuffer &mTimeline;
    LatencyReporter &mLat;
    LogSink &mLog;
    int mChannels;
};

// ---- decoder factories ----
// create + configure + start; nullptr on failure
static inline AMediaCodec *startCodec(const char *mime, const char *name, AMediaFormat *fmt,
                                      LogSink &log) {
    const char *label = name ? name : "default";
    AMediaCodec *codec = name ? AMediaCodec_createCodecByName(name) : AMediaCodec_createDecoderByType(mime);
    if (!codec) {
        log.warn("%s decoder (%s) create failed", mime, label);
        return nullptr;
    }
    const char *step = "configure";
    media_status_t st = AMediaCodec_configure(codec, fmt, nullptr, nullptr, 0);
    if (st == AMEDIA_OK) {
        step = "start";
        st = AMediaCodec_start(codec);
    }
    if (st != AMEDIA_OK) {
        log.warn("%s decoder (%s) %s failed (%d)", mime, label, step, (int)st);
        AMediaCodec_delete(codec);
        return nullptr;
    }
    log.info("%s decoder started (%s)", mime, label);
    return codec;
}

// tries c.preferName first if set, then platform default
static inline AMediaCodec *startMediaCodec(const CodecConfig &c, LogSink &log, bool realtimePriority,
                                           bool lowLatency) {
    AMediaFormat *fmt = AMediaFormat_new();
    AMediaFormat_setString(fmt, "mime", c.mime);
    AMediaFormat_setInt32(fmt, "sample-rate", c.sampleRate);
    AMediaFormat_setInt32(fmt, "channel-count", c.channels);
    if (c.aacProfile) {
        AMediaFormat_setInt32(fmt, "aac-profile", c.aacProfile);
        AMediaFormat_setInt32(fmt, "is-adts", 0);
    }
    // priority=0 requests realtime scheduling; low-latency=1 minimizes decoder buffering
    if (realtimePriority) AMediaFormat_setInt32(fmt, "priority", 0);
    if (lowLatency) AMediaFormat_setInt32(fmt, "low-latency", 1);
    AMediaFormat_setBuffer(fmt, "csd-0", c.csd, c.csdLen);
    AMediaCodec *codec = c.preferName ? startCodec(c.mime, c.preferName, fmt, log) : nullptr;
    if (!codec) codec = startCodec(c.mime, nullptr, fmt, log);
    AMediaFormat_delete(fmt);
    return codec;
}

static inline std::unique_ptr<Decoder> makeDecoder(int ct, int spf, int sampleRate, int channels,
                                                   TimelineBuffer &timeline, LatencyReporter &lat,
                                                   LogSink &log, bool forceSw,
                                                   bool realtimePriority, bool lowLatency) {
    const auto c = codecConfig(ct, spf, sampleRate, channels);
    if (!c) {
        log.error("Unknown audio ct=%d", ct);
        return nullptr;
    }
    if (!forceSw) {
        if (AMediaCodec *codec = startMediaCodec(*c, log, realtimePriority, lowLatency))
            return std::make_unique<MediaCodecDecoder>(codec, timeline, lat);
    }
    if (auto sw = FfmpegDecoder::make(*c, timeline, lat, log)) {
        log.info("%s decoder started (ffmpeg%s)", c->mime, forceSw ? ", forced" : "");
        return sw;
    }
    log.error("%s decoder init failed (ct=%d)", c->mime, ct);
    return nullptr;
}

#endif  // AUDIO_DECODER_H
