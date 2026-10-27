package app.opendisplay.android

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Logcat plus a small on-device file, the Android side of the iOS receiver's
 * connection log (Settings > Diagnostics). What the device saw while
 * connecting: sessions, restarts, decoder trouble; never screen content.
 */
object Log {
    private const val MAX_BYTES = 512 * 1024L
    private const val KEEP_BYTES = 256 * 1024

    private val writer = Executors.newSingleThreadExecutor { r -> Thread(r, "od-log").apply { isDaemon = true } }
    private val stamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
    @Volatile private var file: File? = null

    fun init(context: Context) {
        file = File(context.filesDir, "opendisplay-receiver.log")
    }

    fun i(tag: String, message: String) {
        android.util.Log.i(tag, message)
        append("I", message)
    }

    fun w(tag: String, message: String, error: Throwable? = null) {
        android.util.Log.w(tag, message, error)
        append("W", if (error == null) message else "$message: $error")
    }

    /** The whole log, oldest first. Blocking; call off the main thread if it matters. */
    fun read(): String = try {
        writer.submit<String> { file?.takeIf { it.exists() }?.readText() ?: "" }.get()
    } catch (_: Exception) {
        ""
    }

    private fun append(level: String, message: String) {
        val f = file ?: return
        val line = "[${synchronized(stamp) { stamp.format(Date()) }}] $level $message\n"
        writer.execute {
            try {
                f.appendText(line)
                if (f.length() > MAX_BYTES) {
                    val text = f.readText()
                    val cut = text.indexOf('\n', text.length - KEEP_BYTES)
                    f.writeText(if (cut >= 0) text.substring(cut + 1) else text.takeLast(KEEP_BYTES))
                }
            } catch (_: Exception) {
                // Diagnostics must never take the app down.
            }
        }
    }
}
