package app.opendisplay.android.ui

import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.util.TypedValue
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.fragment.app.DialogFragment
import app.opendisplay.android.Log
import app.opendisplay.android.R
import com.google.android.material.appbar.MaterialToolbar

/** The iOS DiagnosticsLogView: the connection log, newest at the bottom, with Share. */
class LogDialog : DialogFragment() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setStyle(STYLE_NO_TITLE, R.style.Theme_OpenDisplay_Sheet)
    }

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, saved: Bundle?): View {
        val context = requireContext()
        // Shared as text: no FileProvider needed. The tail is what matters for
        // a GitHub issue and keeps the share Intent small.
        val log = Log.read().takeLast(200_000)
        val root = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        root.addView(MaterialToolbar(context).apply {
            title = getString(R.string.connection_log)
            setNavigationIcon(R.drawable.ic_close)
            setNavigationContentDescription(R.string.done)
            setNavigationOnClickListener { dismiss() }
            menu.add(R.string.share).setIcon(R.drawable.ic_share)
                .setShowAsAction(android.view.MenuItem.SHOW_AS_ACTION_ALWAYS)
            setOnMenuItemClickListener {
                startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_SUBJECT, "OpenDisplay connection log")
                    putExtra(Intent.EXTRA_TEXT, log)
                }, null))
                true
            }
        })
        val scroll = ScrollView(context)
        scroll.addView(TextView(context).apply {
            text = log.ifEmpty { getString(R.string.log_empty) }
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            typeface = Typeface.MONOSPACE
            setTextIsSelectable(true)
            val pad = (12 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad / 2, pad, pad * 2)
        })
        root.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.padToSafeArea()
        scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
        return root
    }

    override fun onStart() {
        super.onStart()
        dialog?.window?.apply {
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            enterImmersive()
        }
    }
}
