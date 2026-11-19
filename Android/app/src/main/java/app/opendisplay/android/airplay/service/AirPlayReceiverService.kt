package app.opendisplay.android.airplay.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.opendisplay.android.R
import app.opendisplay.android.airplay.bridge.LogListener
import app.opendisplay.android.airplay.bridge.NativeBridge
import app.opendisplay.android.airplay.bridge.RaopCallbackHandler
import app.opendisplay.android.airplay.discovery.MdnsService
import app.opendisplay.android.airplay.discovery.NsdServiceManager
import app.opendisplay.android.airplay.renderer.AudioRenderer
import java.io.File
import java.util.UUID
import kotlin.math.log10

/**
 * Audio-only AirPlay receiver. It advertises RAOP over DNS-SD and feeds the
 * incoming ALAC/AAC stream directly into the native Oboe output. No video,
 * mirroring, photo or HLS capability is advertised.
 */
class AirPlayReceiverService : Service() {

    private val audioManager by lazy { getSystemService(AUDIO_SERVICE) as AudioManager }
    private val nsdManager by lazy { NsdServiceManager(this) }
    private val audioRenderer = AudioRenderer()

    private var serverHandle = 0L
    private var wakeLock: PowerManager.WakeLock? = null
    private var senderGain = 1f

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopReceiver()
            else -> {
                promoteToForeground()
                startReceiver()
            }
        }
        // The host app's settings switch owns the lifetime; do not auto-restart.
        return START_NOT_STICKY
    }

    @Synchronized
    private fun startReceiver() {
        if (serverHandle != 0L) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            Log.w(TAG, "AirPlay audio requires API 23+; skipping on API ${Build.VERSION.SDK_INT}")
            return
        }

        try {
            nsdManager.acquireMulticastLock()
        } catch (t: Throwable) {
            Log.w(TAG, "multicast lock unavailable: ${t.message}")
        }

        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OpenDisplay:AirPlayAudio")
            .apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_TIMEOUT_MS)
            }

        try {
            val sampleRate = audioManager
                .getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull() ?: 44_100
            val burst = audioManager
                .getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull() ?: 512
            NativeBridge.nativeSetDefaultStreamValues(sampleRate, burst)

            val name = airPlayName()
            val keyFile = File(filesDir, "airplay-audio.pem").absolutePath
            val handle = NativeBridge.nativeInit(
                receiverCallbacks,
                hardwareAddress(),
                name,
                keyFile,
                true,  // allow new connections without a PIN
                false, // no pairing PIN UI in this embedded receiver
            )
            if (handle == 0L) throw IllegalStateException("nativeInit failed")

            serverHandle = handle
            audioRenderer.attachEngine(handle)

            // Audio-only service profile. Keep the audio/metadata bits, clear
            // screen mirroring, photos, HLS and video codec negotiation bits.
            NativeBridge.nativeSetCodecs(handle, true, true)
            NativeBridge.nativeSetFeature(handle, NativeBridge.FT_AUDIO, true)
            NativeBridge.nativeSetFeature(handle, NativeBridge.FT_MIRROR, false)
            NativeBridge.nativeSetHlsEnabled(handle, false)
            for (bit in AUDIO_ONLY_DISABLED_BITS) {
                NativeBridge.nativeSetFeature(handle, bit, false)
            }
            NativeBridge.nativeSetPlist(handle, "audio_delay_micros", 0)

            val port = NativeBridge.nativeStart(handle, DEFAULT_PORT)
            if (port <= 0) throw IllegalStateException("nativeStart returned $port")

            val raopTxt = NativeBridge.nativeGetRaopTxtRecords(handle).orEmpty()
            val raopName = NativeBridge.nativeGetRaopServiceName(handle)
                ?.takeIf { it.isNotBlank() }
                ?: "$name@AirPlay"
            val airplayTxt = NativeBridge.nativeGetAirplayTxtRecords(handle).orEmpty()
            val airplayName = NativeBridge.nativeGetServerName(handle)
                ?.takeIf { it.isNotBlank() }
                ?: name
            // Android's mDNS responder hangs when the same instance name is
            // registered for two types at once (we already use this name for
            // _opensidecar._tcp). Give the AirPlay list entry its own name.
            val airplayServiceName = "$airplayName AirPlay"
            nsdManager.register(
                listOf(
                    MdnsService(raopName, RAOP_SERVICE_TYPE, port, raopTxt),
                    MdnsService(airplayServiceName, AIRPLAY_SERVICE_TYPE, port, airplayTxt),
                )
            )
            Log.i(TAG, "AirPlay audio receiver ready: $raopName / $airplayName on $port")
        } catch (t: Throwable) {
            Log.e(TAG, "failed to start AirPlay audio receiver", t)
            teardown()
            stopSelf()
        }
    }

    private fun stopReceiver() {
        teardown()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    @Synchronized
    private fun teardown() {
        val handle = serverHandle
        serverHandle = 0L
        if (handle != 0L) {
            try {
                audioRenderer.detachEngine()
                NativeBridge.nativeStop(handle)
                NativeBridge.nativeDestroy(handle)
            } catch (t: Throwable) {
                Log.w(TAG, "error while stopping native receiver: ${t.message}")
            }
        }
        nsdManager.release()
        wakeLock?.let { lock -> if (lock.isHeld) lock.release() }
        wakeLock = null
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    private fun promoteToForeground() {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.airplay_audio_icon)
            .setContentTitle(getString(R.string.airplay_notification_title))
            .setContentText(getString(R.string.airplay_notification_text))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.airplay_notification_channel),
            NotificationManager.IMPORTANCE_LOW,
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun airPlayName(): String {
        getSharedPreferences("identity", Context.MODE_PRIVATE)
            .getString("serviceName", null)
            ?.takeIf { it.isNotBlank() }
            ?.let { return it }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
            Settings.Global.getString(contentResolver, "device_name")
                ?.takeIf { it.isNotBlank() }
                ?.let { return it }
        }
        return Build.MODEL.ifBlank { "Android AirPlay" }
    }

    private fun hardwareAddress(): ByteArray {
        val prefs = getSharedPreferences("airplay_audio", Context.MODE_PRIVATE)
        val saved = prefs.getString(KEY_HW_ADDRESS, null)
        if (saved != null) {
            val parts = saved.split(":")
            if (parts.size == 6) {
                val parsed = ByteArray(6)
                for (i in parts.indices) {
                    parsed[i] = parts[i].toInt(16).toByte()
                }
                return parsed
            }
        }
        val bytes = ByteArray(6)
        UUID.randomUUID().toString().replace("-", "").take(12).chunked(2)
            .forEachIndexed { index, part -> bytes[index] = part.toInt(16).toByte() }
        // Locally administered, unicast.
        bytes[0] = ((bytes[0].toInt() and 0x0F) or 0x02).toByte()
        prefs.edit().putString(
            KEY_HW_ADDRESS,
            bytes.joinToString(":") { "%02X".format(it.toInt() and 0xFF) },
        ).apply()
        return bytes
    }

    private val receiverCallbacks = object : RaopCallbackHandler, LogListener {
        override fun onLog(msg: String) {
            Log.d("AirPlayNative", msg)
        }

        override fun onAudioFormat(ct: Int, spf: Int, usingScreen: Boolean) {
            audioRenderer.setFormat(ct, spf)
            audioRenderer.start()
            Log.i(TAG, "audio format ct=$ct spf=$spf screen=$usingScreen")
        }

        override fun onClientVolume(db: Float) {
            senderGain = dbToGain(db)
            audioRenderer.setClientGain(senderGain)
        }

        override fun onClientVolumeQuery(): Float = gainToDb(senderGain)

        override fun onAudioTeardown() {
            audioRenderer.stop()
        }

        override fun onConnectionInit() {
            Log.i(TAG, "sender connected")
        }

        override fun onConnectionDestroy() {
            audioRenderer.stop()
            Log.i(TAG, "sender disconnected")
        }

        override fun onConnectionReset(reason: Int) {
            Log.w(TAG, "connection reset: $reason")
        }

        override fun onDisplayPin(pin: String) {
            Log.i(TAG, "AirPlay PIN requested (pairing disabled)")
        }

        // All video/mirroring callbacks are intentionally no-ops.
        override fun onVideoData(data: ByteArray, ntpTimeNs: Long, isH265: Boolean) = Unit
        override fun onVideoSize(srcW: Float, srcH: Float, w: Float, h: Float) = Unit
        override fun onMetadata(data: ByteArray) = Unit
        override fun onCoverArt(data: ByteArray) = Unit
        override fun onProgress(start: Long, curr: Long, end: Long) = Unit
        override fun onDacpId(dacpId: String, activeRemote: String) = Unit
        override fun onMirrorRunning(running: Boolean) = Unit
        override fun onVideoPlay(location: String, startPositionSeconds: Float) = Unit
        override fun onVideoScrub(positionSeconds: Float) = Unit
        override fun onVideoRate(rate: Float) = Unit
        override fun onVideoStop() = Unit
        override fun onVideoSessionPoll() = Unit
    }

    private fun dbToGain(db: Float): Float = when {
        db <= -30f -> 0f
        db >= 0f -> 1f
        else -> (db + 30f) / 30f
    }

    private fun gainToDb(gain: Float): Float =
        if (gain <= 0.001f) -144f
        else (20.0 * log10(gain.toDouble())).toFloat().coerceIn(-30f, 0f)

    companion object {
        private const val TAG = "AirPlayAudio"
        private const val CHANNEL_ID = "airplay_audio_receiver"
        private const val NOTIFICATION_ID = 7917
        private const val DEFAULT_PORT = 7000
        private const val RAOP_SERVICE_TYPE = "_raop._tcp"
        private const val AIRPLAY_SERVICE_TYPE = "_airplay._tcp"
        private const val WAKE_LOCK_TIMEOUT_MS = 10L * 60 * 1000
        private const val KEY_HW_ADDRESS = "hwAddress"

        const val ACTION_START = "app.opendisplay.android.airplay.audio.START"
        const val ACTION_STOP = "app.opendisplay.android.airplay.audio.STOP"
        const val PREF_FILE = "settings"
        const val PREF_KEY_ENABLED = "airplayAudioReceiver"

        // AirPlay feature bits for video, photos, HLS, slideshow and H.265.
        private val AUDIO_ONLY_DISABLED_BITS = intArrayOf(0, 1, 2, 4, 5, 6, 7, 8, 13, 33, 34, 42)

        fun isEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE)
                .getBoolean(PREF_KEY_ENABLED, true)

        fun start(context: Context) {
            val intent = Intent(context, AirPlayReceiverService::class.java).setAction(ACTION_START)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, AirPlayReceiverService::class.java).setAction(ACTION_STOP)
            context.stopService(intent)
        }
    }
}
