package app.opendisplay.android.airplay.bridge

object NativeBridge {
    const val FT_MIRROR = 7
    const val FT_AUDIO = 9

    init {
        System.loadLibrary("airplay_native")
    }

    external fun nativeInit(
        callback: RaopCallbackHandler,
        hwAddr: ByteArray,
        name: String,
        keyFile: String,
        nohold: Boolean,
        requirePin: Boolean
    ): Long

    external fun nativeStart(handle: Long, port: Int): Int
    external fun nativeStop(handle: Long)
    external fun nativeDestroy(handle: Long)

    external fun nativeSetDisplaySize(handle: Long, w: Int, h: Int, fps: Int)
    external fun nativeSetPlist(handle: Long, key: String, value: Int)
    external fun nativeSetH265Enabled(handle: Long, enabled: Boolean)
    external fun nativeSetCodecs(handle: Long, alac: Boolean, aac: Boolean)
    external fun nativeSetHlsEnabled(handle: Long, enabled: Boolean)
    external fun nativeSetLang(handle: Long, lang: String)
    external fun nativeSetFeature(handle: Long, bit: Int, enabled: Boolean)
    external fun nativeUpdatePlaybackInfo(
        handle: Long, position: Float, duration: Float, rate: Float, readyToPlay: Boolean
    )

    external fun nativeGetRaopTxtRecords(handle: Long): Map<String, String>?
    external fun nativeGetAirplayTxtRecords(handle: Long): Map<String, String>?
    external fun nativeGetRaopServiceName(handle: Long): String?
    external fun nativeGetServerName(handle: Long): String?

    external fun nativeSetDefaultStreamValues(sampleRate: Int, framesPerBurst: Int)
    external fun nativeServerAudioConfigure(handle: Long, cushionMs: Int, percentilePct: Int,
                                            oboeBufferFrames: Int, forceSwAlac: Boolean,
                                            forceSwAac: Boolean, realtimePriority: Boolean,
                                            lowLatency: Boolean, benchmarkLog: Boolean): Boolean
    external fun nativeServerAudioStart(handle: Long): Boolean
    external fun nativeServerAudioStop(handle: Long)
    external fun nativeServerAudioSetClientGain(handle: Long, gain: Float)
    external fun nativeServerAudioFormat(handle: Long, ct: Int, spf: Int)
    // fills direct buffer with packed debug snapshot; false if audio isn't running
    external fun nativeServerAudioDebug(handle: Long, buf: java.nio.ByteBuffer): Boolean
}
