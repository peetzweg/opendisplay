package app.opendisplay.android.net

import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * The sender over USB accessory mode (AOA): the Mac switched this device
 * into accessory mode and the bulk endpoints carry the TCP byte stream as
 * is. One attachment is one session; the Mac ends it by resetting the
 * device, which surfaces here as EIO.
 */
internal class AccessoryLink private constructor(
    private val fd: ParcelFileDescriptor,
    accessory: UsbAccessory,
) : Link {
    override val input: InputStream = PacketInputStream { b, off, len ->
        try {
            Os.read(fd.fileDescriptor, b, off, len)
        } catch (e: ErrnoException) {
            throw IOException("accessory read: ${e.message}", e)
        }
    }
    override val output: OutputStream = FileOutputStream(fd.fileDescriptor)
    override val transport = "USB"
    override val remote = "USB accessory ${accessory.manufacturer} ${accessory.model}"
    override fun close() = fd.close()

    companion object {
        const val MANUFACTURER = "OpenDisplay"
        const val MODEL = "OpenDisplay Receiver"

        fun isOurs(accessory: UsbAccessory) =
            accessory.manufacturer == MANUFACTURER && accessory.model == MODEL

        /** Null without permission, or when another process holds it. */
        fun open(manager: UsbManager, accessory: UsbAccessory): AccessoryLink? {
            if (!manager.hasPermission(accessory)) return null
            // The sender can reset the device between the check and the open:
            // the attachment is gone (IllegalArgumentException) or its
            // permission with it (SecurityException). A fresh one follows.
            val fd = try {
                manager.openAccessory(accessory)
            } catch (e: IllegalArgumentException) {
                null
            } catch (e: SecurityException) {
                null
            } ?: return null
            return AccessoryLink(fd, accessory)
        }
    }
}

/**
 * Serves arbitrary reads from whole 16 KB reads of the accessory. The
 * gadget driver keeps one request of that size in flight, and a smaller
 * read can drop the rest of a packet. A 0-byte read is a zero-length packet
 * that ended a transfer, not EOF (FileInputStream would report it as EOF).
 */
internal class PacketInputStream(
    private val readPacket: (ByteArray, Int, Int) -> Int,
) : InputStream() {
    private val buffer = ByteArray(PACKET_READ)
    private var position = 0
    private var limit = 0

    override fun read(): Int {
        if (!fill()) return -1
        return buffer[position++].toInt() and 0xff
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (!fill()) return -1
        val n = minOf(len, limit - position)
        System.arraycopy(buffer, position, b, off, n)
        position += n
        return n
    }

    override fun available(): Int = limit - position

    /** False at EOF. */
    private fun fill(): Boolean {
        if (position < limit) return true
        var empty = 0
        while (true) {
            val n = readPacket(buffer, 0, PACKET_READ)
            if (n < 0) return false
            if (n > 0) {
                position = 0
                limit = n
                return true
            }
            // A zero-length packet only ever follows data; a run of them
            // means the endpoint is gone without an error.
            if (++empty >= MAX_EMPTY_READS) return false
        }
    }

    companion object {
        const val PACKET_READ = 16384
        private const val MAX_EMPTY_READS = 64
    }
}
