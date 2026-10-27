package app.opendisplay.android.ui

import android.content.Context
import android.os.Build
import android.provider.Settings
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.UUID

object DeviceIdentity {
    private const val PREFS = "identity"
    private const val KEY_ID = "installId"
    private const val KEY_NAME = "serviceName"

    /** Stable per-install UUID: Bonjour TXT `id` and `hello.id` (2.1). */
    fun installId(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_ID, null)?.let { return it }
        val id = UUID.randomUUID().toString().uppercase()
        prefs.edit().putString(KEY_ID, id).apply()
        return id
    }

    /** The Bonjour name the sender lists: user-set, else the device's own name. */
    fun serviceName(context: Context): String {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_NAME, null)?.takeIf { it.isNotBlank() }?.let { return it }
        if (Build.VERSION.SDK_INT >= 25) {
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
                ?.takeIf { it.isNotBlank() }?.let { return it }
        }
        val model = Build.MODEL
        val maker = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        if (maker.isBlank() || maker.equals("unknown", ignoreCase = true)) return model
        return if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model"
    }

    fun setServiceName(context: Context, name: String?) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_NAME, name?.trim()?.takeIf { it.isNotEmpty() }).apply()
    }

    /** Free-form device kind for the sender's UI text. */
    fun deviceKind(context: Context): String =
        if (context.resources.configuration.smallestScreenWidthDp >= 600) "Android tablet" else "Android phone"

    fun ipv4Addresses(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .map { it.hostAddress ?: "" }
            .filter { it.isNotEmpty() }
    } catch (_: Exception) {
        emptyList()
    }
}
