package app.opendisplay.android.net

import app.opendisplay.android.protocol.WireProtocol
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.Inet6Address
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets

/**
 * Minimal mDNS/DNS-SD response encoder for the `_opensidecar._tcp` service.
 *
 * This is a fallback for Wi-Fi hotspot mode only: Android's NsdManager binds
 * its responder to the uplink (wlan0), so its advertisement never reaches
 * clients on the hotspot (ap0) network. We emit an unsolicited response with
 * the same records on ap0 so a browser there can discover the receiver.
 *
 * Records: PTR (service -> instance), SRV (instance -> host:port), TXT
 * (id, pv), A/AAAA (host -> address). DNS name compression is not used;
 * browsers accept uncompressed names.
 */
internal object MdnsPacket {
    private const val TYPE_A = 1
    private const val TYPE_PTR = 12
    private const val TYPE_TXT = 16
    private const val TYPE_AAAA = 28
    private const val TYPE_SRV = 33
    private const val CLASS_IN = 1
    const val CLASS_CACHE_FLUSH = 0x8001
    const val TTL_SECONDS = 120

    /** Stable host label derived from the install id, so reboots keep identity. */
    fun hostLabel(installId: String): String {
        val digits = installId.filter { it.isLetterOrDigit() }.take(12).lowercase()
        return "opendisplay-${digits.ifEmpty { "receiver" }}"
    }

    private fun writeName(out: ByteArrayOutputStream, value: String) {
        if (value.isEmpty() || value == ".") {
            out.write(0)
            return
        }
        val trimmed = value.trimEnd('.')
        for (raw in trimmed.split('.')) {
            val label = if (raw.length > 63) raw.substring(0, 63) else raw
            val bytes = label.toByteArray(StandardCharsets.UTF_8)
            out.write(bytes.size)
            out.write(bytes, 0, bytes.size)
        }
        out.write(0)
    }

    private fun encodedNameSize(value: String): Int {
        if (value.isEmpty() || value == ".") return 1
        return value.trimEnd('.').split('.').sumOf { label ->
            1 + minOf(label.length, 63)
        } + 1
    }

    private fun writeHeader(out: ByteArrayOutputStream, answers: Int) {
        val h = ByteBuffer.allocate(12)
        h.putShort(0) // transaction id
        h.putShort(0x8400.toShort()) // QR=1 (response), AA=1 (authoritative)
        h.putShort(0) // QDCOUNT
        h.putShort(answers.toShort()) // ANCOUNT
        h.putShort(0) // NSCOUNT
        h.putShort(0) // ARCOUNT
        out.write(h.array())
    }

    private fun writeAnswer(
        out: ByteArrayOutputStream,
        name: String,
        type: Int,
        clazz: Int,
        rdata: ByteArray,
    ) {
        writeName(out, name)
        val head = ByteBuffer.allocate(10)
        head.putShort(type.toShort())
        head.putShort(clazz.toShort())
        head.putInt(TTL_SECONDS)
        head.putShort(rdata.size.toShort())
        out.write(head.array())
        out.write(rdata)
    }

    /**
     * Build a complete mDNS response advertising one service instance.
     *
     * @param instanceName Bonjour name as shown to the user (may contain spaces).
     * @param installId stable id matching the hello's `id`.
     * @param version protocol version for the TXT `pv` key.
     * @param port TCP port the receiver listens on.
     * @param ipv4 address on the hotspot network (ap0).
     * @param ipv6 optional link-local address on the hotspot network.
     */
    fun buildAnnouncement(
        instanceName: String,
        installId: String,
        version: Int,
        port: Int,
        ipv4: Inet4Address,
        ipv6: Inet6Address? = null,
    ): ByteArray {
        val serviceFqdn = "${WireProtocol.SERVICE_TYPE}.local."
        val instanceFqdn = "$instanceName.$serviceFqdn"
        val hostFqdn = "${hostLabel(installId)}.local."

        val answerCount = 4 + (if (ipv6 != null) 1 else 0)
        val out = ByteArrayOutputStream()
        writeHeader(out, answerCount)

        // PTR: service type -> instance (shared record, no cache-flush).
        val ptr = ByteArrayOutputStream().also { writeName(it, instanceFqdn) }.toByteArray()
        writeAnswer(out, serviceFqdn, TYPE_PTR, CLASS_IN, ptr)

        // SRV: instance -> host:port.
        val srv = ByteBuffer.allocate(6 + encodedNameSize(hostFqdn))
        srv.putShort(0) // priority
        srv.putShort(0) // weight
        srv.putShort(port.toShort())
        val hostBytes = ByteArrayOutputStream().also { writeName(it, hostFqdn) }.toByteArray()
        srv.put(hostBytes)
        writeAnswer(out, instanceFqdn, TYPE_SRV, CLASS_CACHE_FLUSH, srv.array().copyOf(srv.position()))

        // TXT: id and pv, each as a length-prefixed string.
        val txt = ByteArrayOutputStream()
        for (entry in listOf("id=$installId", "pv=$version")) {
            val bytes = entry.toByteArray(StandardCharsets.UTF_8)
            txt.write(bytes.size)
            txt.write(bytes, 0, bytes.size)
        }
        writeAnswer(out, instanceFqdn, TYPE_TXT, CLASS_CACHE_FLUSH, txt.toByteArray())

        // A: host -> hotspot IPv4.
        writeAnswer(out, hostFqdn, TYPE_A, CLASS_CACHE_FLUSH, ipv4.address)

        // AAAA (optional): host -> hotspot link-local IPv6.
        if (ipv6 != null) {
            writeAnswer(out, hostFqdn, TYPE_AAAA, CLASS_CACHE_FLUSH, ipv6.address)
        }

        return out.toByteArray()
    }
}
