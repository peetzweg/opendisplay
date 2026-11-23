package app.opendisplay.android.net

import android.os.Handler
import android.os.HandlerThread
import app.opendisplay.android.Log
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.net.SocketException

/**
 * Emits `_opensidecar._tcp` mDNS responses on the Wi-Fi hotspot (ap0) network.
 *
 * Android's NsdManager responder binds to the uplink interface (wlan0) when
 * the phone both joins a Wi-Fi network and shares it as a hotspot. Clients on
 * the hotspot never see that advertisement. This broadcaster binds a
 * MulticastSocket directly to the hotspot interface and announces the same
 * service there, so a browser on ap0 can discover the receiver.
 *
 * It is a supplement to NsdManager, active only while a hotspot interface is
 * present. The caller holds the MulticastLock for the lifetime of discovery.
 */
internal class HotspotMdnsBroadcaster {
    private val thread = HandlerThread("od-hotspot-mdns").apply { start() }
    private val handler = Handler(thread.looper)
    private var socket: MulticastSocket? = null
    private var iface: NetworkInterface? = null
    private var ipv4: Inet4Address? = null
    private var ipv6: Inet6Address? = null
    private var announcement: ByteArray? = null
    private var running = false
    private var announceCount = 0

    private val sendLoop = object : Runnable {
        override fun run() {
            if (!running) return
            try {
                val bytes = announcement
                val address = ipv4
                if (bytes != null && address != null) {
                    val packet = java.net.DatagramPacket(
                        bytes, bytes.size, GROUP, MDNS_PORT
                    )
                    socket?.send(packet)
                    announceCount++
                    if (announceCount <= INITIAL_BURST || announceCount % QUIET_EVERY == 0) {
                        Log.i(TAG, "hotspot mDNS announced #$announceCount via ${iface?.name} " +
                            "($address:$MDNS_PORT)")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "hotspot mDNS send failed: $e")
            }
            val delay = if (announceCount < INITIAL_BURST) BURST_INTERVAL_MS else STEADY_INTERVAL_MS
            handler.postDelayed(this, delay)
        }
    }

    /** True when a Wi-Fi hotspot (AP) interface is currently up. */
    fun hasHotspot(): Boolean = findHotspotInterface() != null

    /**
     * Start announcing on the hotspot interface, if one exists.
     * Safe to call repeatedly; a previous run is replaced.
     */
    fun start(
        instanceName: String,
        installId: String,
        version: Int,
        port: Int,
    ) {
        handler.post {
            stopLocked()
            val hotspot = findHotspotInterface()
            if (hotspot == null) {
                Log.i(TAG, "no hotspot interface; hotspot mDNS disabled")
                return@post
            }
            val v4 = hotspot.inetAddresses.toList().filterIsInstance<Inet4Address>()
                .firstOrNull { !it.isLoopbackAddress }
            if (v4 == null) {
                Log.w(TAG, "hotspot ${hotspot.name} has no IPv4; hotspot mDNS disabled")
                return@post
            }
            val v6 = hotspot.inetAddresses.toList().filterIsInstance<Inet6Address>()
                .firstOrNull { it.isLinkLocalAddress }

            val sock = openSocket(hotspot, v4)
            if (sock == null) return@post

            iface = hotspot
            ipv4 = v4
            ipv6 = v6
            socket = sock
            announcement = MdnsPacket.buildAnnouncement(
                instanceName, installId, version, port, v4, v6
            )
            announceCount = 0
            running = true
            Log.i(TAG, "hotspot mDNS started on ${hotspot.name} ($v4${v6?.let { ", $it" } ?: ""})")
            sendLoop.run()
        }
    }

    fun stop() {
        handler.post { stopLocked() }
    }

    private fun stopLocked() {
        running = false
        handler.removeCallbacks(sendLoop)
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
        iface = null
        ipv4 = null
        ipv6 = null
        announcement = null
        announceCount = 0
    }

    /** Bind a multicast socket to the hotspot interface, preferring port 5353. */
    private fun openSocket(hotspot: NetworkInterface, v4: Inet4Address): MulticastSocket? {
        // Unbound socket so we can set the interface before binding.
        val sock = try {
            MulticastSocket(null)
        } catch (e: Exception) {
            Log.w(TAG, "MulticastSocket create failed: $e")
            return null
        }
        return try {
            sock.reuseAddress = true
            sock.networkInterface = hotspot
            try {
                sock.bind(InetSocketAddress(v4, MDNS_PORT))
            } catch (e: Exception) {
                // Port 5353 may be held by the system responder; a random
                // source port still delivers multicast responses to browsers.
                Log.i(TAG, "bind $MDNS_PORT failed (${e.message}); using ephemeral port")
                sock.bind(InetSocketAddress(v4, 0))
            }
            sock.joinGroup(GROUP)
            sock
        } catch (e: Exception) {
            Log.w(TAG, "hotspot socket setup failed: $e")
            try { sock.close() } catch (_: Exception) {}
            null
        }
    }

    /** Find the AP interface by name; hotspot naming varies by vendor. */
    private fun findHotspotInterface(): NetworkInterface? {
        val interfaces = try {
            NetworkInterface.getNetworkInterfaces().toList()
        } catch (e: SocketException) {
            Log.w(TAG, "enumerate interfaces failed: $e")
            return null
        }
        // Preferred: well-known hotspot interface names.
        interfaces.firstOrNull { nic ->
            val n = nic.name.lowercase()
            nic.isUp && (n == "ap0" || n.startsWith("ap") && n.drop(2).all { it.isDigit() } ||
                n.startsWith("softap"))
        }?.let { return it }

        // Fallback: an UP wifi-like interface (not the station wlan0/lo/cellular)
        // carrying a private 192.168.x address.
        return interfaces.firstOrNull { nic ->
            if (!nic.isUp || nic.isLoopback) return@firstOrNull false
            val n = nic.name.lowercase()
            if (n.startsWith("wlan0") || n.startsWith("ccmni") || n.startsWith("rmnet")) {
                return@firstOrNull false
            }
            val hasPrivateV4 = nic.inetAddresses.toList().filterIsInstance<Inet4Address>()
                .any { it.hostAddress?.startsWith("192.168.") == true }
            (n.startsWith("wlan") || n.startsWith("ap")) && hasPrivateV4
        }
    }

    private companion object {
        const val TAG = "OpenDisplay"
        val GROUP: InetAddress = InetAddress.getByName("224.0.0.251")
        const val MDNS_PORT = 5353
        const val INITIAL_BURST = 4
        const val BURST_INTERVAL_MS = 1200L
        const val STEADY_INTERVAL_MS = 15_000L
        const val QUIET_EVERY = 4
    }
}
