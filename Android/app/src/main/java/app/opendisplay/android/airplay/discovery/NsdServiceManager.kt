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
    private val registrations = mutableListOf<NsdManager.RegistrationListener>()
    private val active = mutableSetOf<NsdManager.RegistrationListener>()
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
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                if (!settled.compareAndSet(false, true)) return
                synchronized(lock) {
                    if (!released) {
                        registrations += this
                        active += this
                    }
                }
                Log.i(TAG, "${next.type} registered: ${info.serviceName}")
                registerNext()
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {
                if (!settled.compareAndSet(false, true)) return
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

        try {
            Log.i(TAG, "registering ${next.type} as ${next.name} on ${next.port}")
            nsdManager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            handler.postDelayed({
                if (settled.compareAndSet(false, true)) {
                    Log.w(TAG, "${next.type} registration callback timed out; continuing")
                    // The OEM stack may still have the record half-alive; drop it
                    // so the retry does not end up as "Name (2)" on the Mac.
                    try { nsdManager.unregisterService(listener) } catch (_: Exception) {}
                    registerNext()
                }
            }, REGISTRATION_TIMEOUT_MS)
        } catch (t: Throwable) {
            if (settled.compareAndSet(false, true)) {
                Log.e(TAG, "${next.type} registerService threw", t)
                registerNext()
            }
        }
    }

    fun release() {
        val toUnregister = synchronized(lock) {
            released = true
            pending.clear()
            val list = active.toList()
            active.clear()
            registrations.clear()
            list
        }
        toUnregister.forEach {
            try { nsdManager.unregisterService(it) } catch (_: Exception) {}
        }
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
