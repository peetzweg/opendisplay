package app.opendisplay.android.airplay.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicBoolean

data class MdnsService(val name: String, val type: String, val port: Int, val txt: Map<String, String>)

class NsdServiceManager(private val ctx: Context) {

    private val nsdManager = ctx.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val lock = Any()
    private val pending = ArrayDeque<MdnsService>()
    // Every listener we ever handed to NsdManager, including timed-out ones.
    // A late onServiceRegistered() after a timeout must still be cleaned up.
    private val tracked = mutableSetOf<NsdManager.RegistrationListener>()
    private val active = mutableSetOf<NsdManager.RegistrationListener>()
    private val timeouts = mutableMapOf<NsdManager.RegistrationListener, Runnable>()
    private var registering = false
    private var released = false
    private var multicastLock: WifiManager.MulticastLock? = null
    private val handler = Handler(Looper.getMainLooper())

    fun acquireMulticastLock() {
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("airplay_mdns").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    /** Queue registrations: Android's NsdManager rejects overlapping requests. */
    fun register(services: List<MdnsService>) {
        val start = synchronized(lock) {
            if (released) return
            pending.addAll(services)
            if (!registering) {
                registering = true
                true
            } else {
                false
            }
        }
        if (start) registerNext()
    }

    private fun unregisterQuietly(listener: NsdManager.RegistrationListener) {
        try { nsdManager.unregisterService(listener) } catch (_: Exception) {}
    }

    private fun clearTimeout(listener: NsdManager.RegistrationListener) {
        timeouts.remove(listener)?.let { handler.removeCallbacks(it) }
    }

    private fun registerNext() {
        val next = synchronized(lock) {
            if (released) {
                registering = false
                null
            } else {
                pending.pollFirst()
            }
        }

        if (next == null) {
            synchronized(lock) {
                if (pending.isEmpty()) registering = false
            }
            return
        }

        val info = NsdServiceInfo().apply {
            serviceName = next.name
            serviceType = next.type
            port = next.port
            next.txt.forEach { (k, v) -> setAttribute(k, v) }
        }

        // Some OEM builds never deliver the registration callback. Without a
        // fallback the queue would stop after the first service and never
        // advertise _airplay._tcp, which macOS needs to list the device.
        val settled = AtomicBoolean(false)
        var timeoutRunnable: Runnable? = null
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                var continueQueue = false
                synchronized(lock) {
                    clearTimeout(this)
                    if (!settled.compareAndSet(false, true)) {
                        // Success arrived after the fallback timeout: the
                        // record may be live even though we moved on. Drop it
                        // here as well as in the timeout path.
                        Log.w(TAG, "${next.type} registered after timeout; unregistering")
                        active -= this
                        tracked -= this
                        unregisterQuietly(this)
                    } else if (released) {
                        active -= this
                        tracked -= this
                        unregisterQuietly(this)
                    } else {
                        tracked += this
                        active += this
                        continueQueue = true
                    }
                }
                if (continueQueue) {
                    Log.i(TAG, "${next.type} registered: ${info.serviceName}")
                    registerNext()
                }
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {
                if (!settled.compareAndSet(false, true)) return
                synchronized(lock) {
                    clearTimeout(this)
                    active -= this
                    tracked -= this
                }
                Log.e(TAG, "${next.type} registration failed: $code")
                registerNext()
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i(TAG, "${next.type} unregistered")
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {
                Log.e(TAG, "${next.type} unregister failed: $code")
            }
        }

        timeoutRunnable = Runnable {
            if (!settled.compareAndSet(false, true)) return@Runnable
            synchronized(lock) {
                timeouts -= listener
                active -= listener
                tracked -= listener
            }
            Log.w(TAG, "${next.type} registration callback timed out; continuing")
            // The OEM stack may still have the record half-alive; drop it so
            // the retry does not end up as "Name (2)" on the Mac.
            unregisterQuietly(listener)
            registerNext()
        }

        synchronized(lock) {
            if (released) return
            tracked += listener
            timeoutRunnable?.let { timeouts[listener] = it }
        }

        try {
            Log.i(TAG, "registering ${next.type} as ${next.name} on ${next.port}")
            nsdManager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            timeoutRunnable?.let { handler.postDelayed(it, REGISTRATION_TIMEOUT_MS) }
        } catch (t: Throwable) {
            if (settled.compareAndSet(false, true)) {
                synchronized(lock) {
                    clearTimeout(listener)
                    active -= listener
                    tracked -= listener
                }
                Log.e(TAG, "${next.type} registerService threw", t)
                registerNext()
            }
        }
    }

    fun release() {
        val (toUnregister, pendingTimeouts) = synchronized(lock) {
            released = true
            pending.clear()
            val callbacks = timeouts.values.toList()
            timeouts.clear()
            val listeners = tracked.toList()
            tracked.clear()
            active.clear()
            listeners to callbacks
        }
        pendingTimeouts.forEach { handler.removeCallbacks(it) }
        toUnregister.forEach { unregisterQuietly(it) }
        multicastLock?.release()
        multicastLock = null
    }

    companion object {
        private const val TAG = "NsdServiceManager"
        // OEM stacks sometimes need >2s to finish mDNS probing; too short a
        // timeout would unregister a service that was about to succeed.
        private const val REGISTRATION_TIMEOUT_MS = 5_000L
    }
}
