package app.opendisplay.android.ui

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import app.opendisplay.android.R
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import com.google.android.material.color.MaterialColors

/**
 * Shown while nothing streams. Same layout as the iOS receiver's IdleView
 * (logo, title, status dot, a card of hints, "Settings & Help", shake tip),
 * built from Material components in the system's light or dark theme.
 */
class IdleView(context: Context, kind: String, onSettings: () -> Unit) : ScrollView(context) {
    private val dot = View(context)
    private val status = TextView(context)

    private fun color(attr: Int) = MaterialColors.getColor(this, attr)

    init {
        isFillViewport = true
        setBackgroundColor(color(com.google.android.material.R.attr.colorSurface))
        val column = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(16), dp(24), dp(16), dp(16))
        }
        addView(column, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        // The status bar may be hidden, the camera and gesture bar are not.
        column.padToSafeArea()

        column.addView(View(context), LinearLayout.LayoutParams(1, 0, 1f))
        column.addView(ImageView(context).apply { setImageResource(R.drawable.app_logo) },
            LinearLayout.LayoutParams(dp(132), dp(132)).apply { bottomMargin = dp(24) })
        column.addView(text(R.string.title, com.google.android.material.R.attr.textAppearanceHeadlineMedium,
            com.google.android.material.R.attr.colorOnSurface), LinearLayout.LayoutParams(WRAP, WRAP))

        val statusRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        statusRow.addView(dot, LinearLayout.LayoutParams(dp(8), dp(8)).apply { rightMargin = dp(8) })
        statusRow.addView(status.apply {
            androidx.core.widget.TextViewCompat.setTextAppearance(this, attrRes(com.google.android.material.R.attr.textAppearanceBodyMedium))
            setTextColor(color(com.google.android.material.R.attr.colorOnSurfaceVariant))
        })
        column.addView(statusRow, LinearLayout.LayoutParams(WRAP, WRAP).apply {
            topMargin = dp(6)
            bottomMargin = dp(24)
        })

        val hints = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(6))
        }
        hints.addView(hint(R.drawable.ic_laptop, context.getString(R.string.hint_open_mac)))
        hints.addView(hint(R.drawable.ic_wifi, context.getString(R.string.hint_pick_wifi, kind)))
        hints.addView(hint(R.drawable.ic_play, context.getString(R.string.hint_keep_open)))
        val card = MaterialCardView(ContextThemeWrapper(context,
            com.google.android.material.R.style.Widget_Material3_CardView_Filled)).apply { addView(hints) }
        column.addView(card, LinearLayout.LayoutParams(minOf(dp(420), screenWidth() - dp(32)), WRAP))

        column.addView(View(context), LinearLayout.LayoutParams(1, 0, 1f))
        column.addView(MaterialButton(ContextThemeWrapper(context,
            com.google.android.material.R.style.Widget_Material3_Button_TonalButton)).apply {
            text = context.getString(R.string.settings_and_help)
            setOnClickListener { onSettings() }
        }, LinearLayout.LayoutParams(WRAP, WRAP).apply { topMargin = dp(24) })
        column.addView(TextView(context).apply {
            text = context.getString(R.string.shake_tip, kind)
            androidx.core.widget.TextViewCompat.setTextAppearance(this, attrRes(com.google.android.material.R.attr.textAppearanceBodySmall))
            setTextColor(color(com.google.android.material.R.attr.colorOutline))
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(WRAP, WRAP).apply { topMargin = dp(8); bottomMargin = dp(8) })
    }

    fun setStatus(text: String, connected: Boolean) {
        status.text = text
        dot.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(if (connected) GREEN else ORANGE)
        }
    }

    private fun text(res: Int, appearance: Int, colorAttr: Int) = TextView(context).apply {
        text = context.getString(res)
        androidx.core.widget.TextViewCompat.setTextAppearance(this, attrRes(appearance))
        setTextColor(color(colorAttr))
    }

    private fun hint(icon: Int, text: String) = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(ImageView(context).apply {
            setImageResource(icon)
            imageTintList = ColorStateList.valueOf(color(com.google.android.material.R.attr.colorOnSurfaceVariant))
        }, LinearLayout.LayoutParams(dp(22), dp(22)).apply { rightMargin = dp(14) })
        addView(TextView(context).apply {
            this.text = text
            androidx.core.widget.TextViewCompat.setTextAppearance(this, attrRes(com.google.android.material.R.attr.textAppearanceBodyMedium))
            setTextColor(color(com.google.android.material.R.attr.colorOnSurface))
        }, LinearLayout.LayoutParams(0, WRAP, 1f))
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, WRAP).apply {
            bottomMargin = dp(14)
        }
    }

    /** Resolves a theme attribute that points at a style resource. */
    private fun attrRes(attr: Int): Int {
        val tv = TypedValue()
        context.theme.resolveAttribute(attr, tv, true)
        return tv.resourceId
    }

    private fun screenWidth() = resources.displayMetrics.widthPixels
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private companion object {
        const val WRAP = LinearLayout.LayoutParams.WRAP_CONTENT
        // Status semantics, the same green/orange as the iOS dot.
        val GREEN = Color.rgb(52, 199, 89)
        val ORANGE = Color.rgb(255, 149, 0)
    }
}
