package app.opendisplay.android.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import app.opendisplay.android.Log
import app.opendisplay.android.protocol.WireProtocol

/**
 * Bonjour advertisement (PROTOCOL.md 2.1): `_opensidecar._tcp` with TXT `id`
 * (must equal hello.id) and `pv`. The name is display-only.
 */
class Advertiser(private val context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var registration: NsdManager.RegistrationListener? = null
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private var retries = 0
    private var multicastLock: WifiManager.MulticastLock? = null
    private val hotspotMdns = HotspotMdnsBroadcaster()

    var registeredName: String? = null
        private set

    fun register(name: String, installId: String, port: Int = WireProtocol.TCP_PORT) {
        main.removeCallbacksAndMessages(null)
        retries = 0
        acquireMulticastLock()
        unregisterQuietly()
        // In hotspot mode NSD registers on the uplink (wlan0) and its name
        // collides with our ap0 announcement, producing endless "(2)/(3)"
        // renames. Announce only on ap0 there; NSD stays authoritative on a
        // normal Wi-Fi network where it reaches every client.
        if (hotspotMdns.hasHotspot()) {
            registeredName = name
            Log.i(TAG, "hotspot active: advertising '$name' via ap0 mDNS only")
            hotspotMdns.start(name, installId, WireProtocol.VERSION, port)
        } else {
            hotspotMdns.stop()
            registerOnce(name, installId, port)
        }
    }

    /**
     * mDNS uses multicast, which Android drops unless a MulticastLock is held.
     * Without this the service is invisible to peers on a Wi-Fi hotspot, where
     * the phone is the AP and multicast replies to clients are dropped.
     */
    private fun acquireMulticastLock() {
        if (multicastLock != null) return
        try {
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = wifi?.createMulticastLock("opensidecar_mdns")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "MulticastLock unavailable: $e")
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.release()
        } catch (e: Exception) {
            Log.w(TAG, "MulticastLock release: $e")
        }
        multicastLock = null
    }

    private fun registerOnce(name: String, installId: String, port: Int) {
        unregisterQuietly()
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = WireProtocol.SERVICE_TYPE
            setPort(port)
            setAttribute("id", installId)
            setAttribute("pv", WireProtocol.VERSION.toString())
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                registeredName = info.serviceName
                Log.i(TAG, "advertising '${info.serviceName}' as ${WireProtocol.SERVICE_TYPE}")
                // NSD renames on a collision ("Pixel 10a (2)"). Usually the
                // collision is our own previous process, whose record lingers
                // after a kill. The Mac remembers devices by name, so a renamed
                // service would not auto-reconnect: claim the real name back.
                if (info.serviceName != name && retries < MAX_RETRIES && registration === this) {
                    retries++
                    main.postDelayed({
                        if (registration === this) registerOnce(name, installId, port)
                    }, RETRY_DELAY_MS)
                }
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD registration failed: $errorCode")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }
        registration = listener
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    fun unregister() {
        main.removeCallbacksAndMessages(null)
        unregisterQuietly()
        hotspotMdns.stop()
        releaseMulticastLock()
    }

    private fun unregisterQuietly() {
        val listener = registration ?: return
        registration = null
        registeredName = null
        try {
            nsd.unregisterService(listener)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "NSD unregister: $e")
        }
    }

    private companion object {
        const val TAG = "OpenDisplay"
        const val MAX_RETRIES = 6
        const val RETRY_DELAY_MS = 5000L
    }
}
