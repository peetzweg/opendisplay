package app.opendisplay.android.airplay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import app.opendisplay.android.airplay.service.AirPlayReceiverService

/** Restarts the opt-out AirPlay audio receiver after a device reboot. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != ACTION_QUICKBOOT_POWERON) return
        if (!AirPlayReceiverService.isEnabled(context)) return
        AirPlayReceiverService.start(context)
    }

    private companion object {
        const val ACTION_QUICKBOOT_POWERON = "android.intent.action.QUICKBOOT_POWERON"
    }
}
