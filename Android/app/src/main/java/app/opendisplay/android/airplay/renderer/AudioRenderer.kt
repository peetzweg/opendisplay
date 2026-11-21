package app.opendisplay.android.airplay.renderer

import app.opendisplay.android.airplay.bridge.NativeBridge

/** Thin wrapper around the native AirPlay audio engine. */
class AudioRenderer {
    @Volatile
    var config: AudioConfig = AudioConfig()
        private set

    @Volatile
    var codecLabel: String = ""
        private set

    @Volatile
    var clientGain: Float = 1f
        private set

    private var serverHandle = 0L

    @Synchronized
    fun attachEngine(server: Long) {
        serverHandle = server
        pushConfig()
        if (serverHandle != 0L) NativeBridge.nativeServerAudioSetClientGain(serverHandle, clientGain)
    }

    @Synchronized
    fun detachEngine() {
        serverHandle = 0L
        codecLabel = ""
    }

    @Synchronized
    fun start() {
        if (serverHandle != 0L) NativeBridge.nativeServerAudioStart(serverHandle)
    }

    @Synchronized
    fun stop() {
        if (serverHandle != 0L) NativeBridge.nativeServerAudioStop(serverHandle)
        codecLabel = ""
    }

    @Synchronized
    fun setClientGain(gain: Float) {
        clientGain = gain.coerceIn(0f, 1f)
        if (serverHandle != 0L) NativeBridge.nativeServerAudioSetClientGain(serverHandle, clientGain)
    }

    @Synchronized
    fun updateConfig(newConfig: AudioConfig) {
        config = newConfig
        pushConfig()
    }

    @Synchronized
    fun setFormat(ct: Int, spf: Int) {
        codecLabel = when (ct) {
            CT_ALAC -> "ALAC"
            CT_AAC_LC -> "AAC-LC"
            CT_AAC_ELD -> "AAC-ELD"
            else -> "?"
        }
        if (serverHandle != 0L) NativeBridge.nativeServerAudioFormat(serverHandle, ct, spf)
    }

    private fun pushConfig() {
        if (serverHandle == 0L) return
        NativeBridge.nativeServerAudioConfigure(
            serverHandle,
            config.cushionMs,
            config.percentilePct,
            config.oboeBufferFrames,
            config.forceSwAlac,
            config.forceSwAac,
            config.realtimePriority,
            config.lowLatency,
            config.benchmarkLog,
        )
    }

    companion object {
        const val CT_ALAC = 2
        const val CT_AAC_LC = 4
        const val CT_AAC_ELD = 8
    }
}
