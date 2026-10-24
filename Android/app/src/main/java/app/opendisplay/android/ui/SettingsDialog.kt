package app.opendisplay.android.ui

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.fragment.app.DialogFragment
import androidx.preference.EditTextPreference
import androidx.preference.Preference
import androidx.preference.PreferenceCategory
import androidx.preference.PreferenceFragmentCompat
import androidx.preference.SwitchPreferenceCompat
import app.opendisplay.android.R
import com.google.android.material.appbar.MaterialToolbar

/**
 * The iOS receiver's SettingsView, laid out the same (sections, order, copy)
 * but built from stock Android preferences. A full-screen dialog rather than
 * an Activity, so the stream keeps running underneath, as the iOS sheet does.
 */
class SettingsDialog : DialogFragment() {

    /** What the sheet reads and changes; implemented by MainActivity. */
    interface Host {
        val isConnected: Boolean
        val streamSummary: String?
        val uiKind: String
        fun onNameChanged(name: String?)
        fun onOverlayChanged(enabled: Boolean)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setStyle(STYLE_NO_TITLE, R.style.Theme_OpenDisplay_Sheet)
    }

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, saved: Bundle?): View {
        val context = requireContext()
        val root = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        root.addView(MaterialToolbar(context).apply {
            title = getString(R.string.title)
            setNavigationIcon(R.drawable.ic_close)
            setNavigationContentDescription(R.string.done)
            setNavigationOnClickListener { dismiss() }
        })
        root.addView(FrameLayout(context).apply { id = R.id.settings_container },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.padToSafeArea()
        if (saved == null) {
            childFragmentManager.beginTransaction()
                .replace(R.id.settings_container, Screen())
                .commit()
        }
        return root
    }

    override fun onStart() {
        super.onStart()
        dialog?.window?.apply {
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            enterImmersive()
        }
    }

    class Screen : PreferenceFragmentCompat() {
        private val ui = Handler(Looper.getMainLooper())
        private lateinit var connection: Preference
        private lateinit var stream: Preference
        private val host get() = requireActivity() as Host

        private val refresh = object : Runnable {
            override fun run() {
                connection.summary = getString(
                    if (host.isConnected) R.string.row_connected else R.string.row_waiting)
                val summary = host.streamSummary
                stream.isVisible = summary != null
                stream.summary = summary
                ui.postDelayed(this, 1000)
            }
        }

        override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
            // Same file and keys as AppPrefs, so the switch persists itself.
            preferenceManager.sharedPreferencesName = AppPrefs.FILE
            val ctx = preferenceManager.context
            val screen = preferenceManager.createPreferenceScreen(ctx)
            preferenceScreen = screen
            val kind = host.uiKind

            screen.category(R.string.section_status) {
                addPreference(info(R.string.row_listening, getString(R.string.row_listening_value)))
                connection = info(R.string.row_connection, null).also { addPreference(it) }
                stream = info(R.string.row_stream, null).also { addPreference(it) }
            }

            screen.category(R.string.section_name) {
                addPreference(EditTextPreference(ctx).apply {
                    key = "serviceNameEditor"
                    isPersistent = false // DeviceIdentity owns the name
                    title = getString(R.string.section_name)
                    dialogTitle = getString(R.string.section_name)
                    dialogMessage = getString(R.string.name_footer)
                    text = DeviceIdentity.serviceName(ctx)
                    summary = text
                    isIconSpaceReserved = false
                    setOnPreferenceChangeListener { pref, value ->
                        val name = (value as String).trim().ifEmpty { null }
                        host.onNameChanged(name)
                        pref.summary = DeviceIdentity.serviceName(ctx)
                        (pref as EditTextPreference).text = pref.summary.toString()
                        false
                    }
                })
                addPreference(footer(getString(R.string.name_footer)))
            }

            screen.category(R.string.section_analytics) {
                addPreference(SwitchPreferenceCompat(ctx).apply {
                    key = AppPrefs.KEY_SHOW_ANALYTICS
                    title = getString(R.string.performance_overlay)
                    summary = getString(R.string.analytics_footer)
                    setDefaultValue(false)
                    isIconSpaceReserved = false
                    setOnPreferenceChangeListener { _, value ->
                        // Persisted by the preference; the activity re-reads it.
                        ui.post { host.onOverlayChanged(value as Boolean) }
                        true
                    }
                })
            }

            screen.category(R.string.section_diagnostics) {
                addPreference(Preference(ctx).apply {
                    title = getString(R.string.connection_log)
                    summary = getString(R.string.diagnostics_footer, kind)
                    isIconSpaceReserved = false
                    setOnPreferenceClickListener {
                        LogDialog().show(parentFragmentManager, "log")
                        true
                    }
                })
            }

            screen.category(R.string.section_how) {
                listOf(
                    getString(R.string.how_wifi, kind),
                    getString(R.string.how_rotate, kind),
                    getString(R.string.how_touch),
                    getString(R.string.how_pen),
                ).forEach { addPreference(footer(it)) }
            }

            screen.category(null) {
                addPreference(link(R.string.get_mac_app, MAC_APP_URL, getString(R.string.mac_app_footer)))
            }

            screen.category(R.string.section_about) {
                addPreference(info(R.string.row_version, versionName()))
                addPreference(link(R.string.link_website, "https://opendisplay.app", null))
                addPreference(link(R.string.link_github, "https://github.com/peetzweg/opendisplay", null))
                addPreference(link(R.string.link_kofi, "https://ko-fi.com/peetzweg", null))
            }
        }

        override fun onResume() {
            super.onResume()
            ui.post(refresh)
        }

        override fun onPause() {
            super.onPause()
            ui.removeCallbacks(refresh)
        }

        private fun androidx.preference.PreferenceScreen.category(
            title: Int?,
            build: PreferenceCategory.() -> Unit,
        ) {
            val category = PreferenceCategory(context).apply {
                title?.let { this.title = getString(it) }
                isIconSpaceReserved = false
            }
            addPreference(category)
            category.build()
        }

        /** A row that shows a value and does nothing when tapped. */
        private fun info(title: Int, value: String?) = Preference(preferenceManager.context).apply {
            this.title = getString(title)
            summary = value
            isSelectable = false
            isIconSpaceReserved = false
        }

        /** Explanatory text, the counterpart of an iOS section footer. */
        private fun footer(text: String) = Preference(preferenceManager.context).apply {
            summary = text
            isSelectable = false
            isIconSpaceReserved = false
        }

        private fun link(title: Int, url: String, summary: String?) = Preference(preferenceManager.context).apply {
            this.title = getString(title)
            this.summary = summary
            intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            isIconSpaceReserved = false
        }

        private fun versionName(): String = try {
            val ctx = requireContext()
            ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: "dev"
        } catch (_: Exception) {
            "dev"
        }
    }

    companion object {
        const val MAC_APP_URL = "https://opendisplay.app/"
    }
}
