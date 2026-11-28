package app.opendisplay.android.airplay.bridge

interface RaopCallbackHandler {
    fun onVideoData(data: ByteArray, ntpTimeNs: Long, isH265: Boolean)
    fun onAudioFormat(ct: Int, spf: Int, usingScreen: Boolean)
    fun onVideoSize(srcW: Float, srcH: Float, w: Float, h: Float)
    // airplay volume in dB: -30..0, -144 = mute
    fun onClientVolume(db: Float)
    // /info initialVolume
    fun onClientVolumeQuery(): Float
    fun onAudioTeardown()
    fun onConnectionInit()
    fun onConnectionDestroy()
    fun onConnectionReset(reason: Int)
    fun onDisplayPin(pin: String)
    fun onMetadata(data: ByteArray)
    fun onCoverArt(data: ByteArray)
    fun onProgress(start: Long, curr: Long, end: Long)
    fun onDacpId(dacpId: String, activeRemote: String)
    fun onMirrorRunning(running: Boolean)
    // video (hls), distinct from mirroring and raop audio
    fun onVideoPlay(location: String, startPositionSeconds: Float)
    fun onVideoScrub(positionSeconds: Float)
    fun onVideoRate(rate: Float)
    fun onVideoStop()
    // fired per sender GET /playback-info poll; polling starts before /play
    fun onVideoSessionPoll()
}
