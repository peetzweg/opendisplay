package app.opendisplay.android.airplay.bridge

/**
 * log lines from native code, forwarded to UI; called directly from native threads
 * (attached to JVM for the call), implementations must be thread-safe and cheap
 */
interface LogListener {
    fun onLog(msg: String)
}
