package app.opendisplay.android.ui

import android.content.Context

/** The receiver's own settings; same keys and meaning as the iOS app's @AppStorage. */
class AppPrefs(context: Context) {
    private val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    var showAnalytics: Boolean
        get() = prefs.getBoolean(KEY_SHOW_ANALYTICS, false)
        set(v) = prefs.edit().putBoolean(KEY_SHOW_ANALYTICS, v).apply()

    /** Opt-out: AirPlay audio is accepted by default. */
    var airplayAudioReceiver: Boolean
        get() = prefs.getBoolean(KEY_AIRPLAY_AUDIO_RECEIVER, true)
        set(v) = prefs.edit().putBoolean(KEY_AIRPLAY_AUDIO_RECEIVER, v).apply()

    var hasConnectedBefore: Boolean
        get() = prefs.getBoolean("hasConnectedBefore", false)
        set(v) = prefs.edit().putBoolean("hasConnectedBefore", v).apply()

    var onboardingDismissed: Boolean
        get() = prefs.getBoolean("onboardingDismissed", false)
        set(v) = prefs.edit().putBoolean("onboardingDismissed", v).apply()

    companion object {
        const val FILE = "settings"
        const val KEY_SHOW_ANALYTICS = "showAnalytics"
        const val KEY_AIRPLAY_AUDIO_RECEIVER = "airplayAudioReceiver"
    }
}
