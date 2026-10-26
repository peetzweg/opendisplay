package app.opendisplay.android.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import androidx.appcompat.widget.AppCompatImageView
import android.widget.PopupMenu
import app.opendisplay.android.R
import kotlin.math.hypot

/**
 * The floating Mac actions button, as on the iOS receiver: tap for a menu of
 * the sender's system actions (`welcome.actions`), drag it to either edge. It
 * remembers the side and height in [AppPrefs], so it survives rotation. Only
 * touches inside the circle are taken; the corners fall through to the desktop.
 */
@SuppressLint("ViewConstructor")
class ActionsButton(
    context: Context,
    private val prefs: AppPrefs,
    private val onAction: (String) -> Unit,
) : AppCompatImageView(context) {

    /** Actions the sender offers, in its order; unknown names are not shown. */
    var actions: List<String> = emptyList()

    private val size = dp(52)
    private val margin = dp(8)
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var startX = 0f
    private var startY = 0f
    private var dragging = false

    init {
        setImageResource(R.drawable.ic_mac_actions)
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.argb(140, 0, 0, 0))
        }
        val pad = dp(14)
        setPadding(pad, pad, pad, pad)
        alpha = IDLE_ALPHA
        contentDescription = context.getString(R.string.mac_actions)
        elevation = dp(4).toFloat()
    }

    val sizePx: Int get() = size

    /** Place the button from the saved side and height inside the parent. */
    fun place() {
        val parent = parent as? View ?: return
        val travel = (parent.height - 2 * margin - size).coerceAtLeast(0)
        x = if (prefs.actionsButtonRight) (parent.width - margin - size).toFloat() else margin.toFloat()
        y = margin + prefs.actionsButtonY * travel
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val r = width / 2f
                if (hypot(event.x - r, event.y - r) > r) return false
                downX = event.rawX
                downY = event.rawY
                startX = x
                startY = y
                dragging = false
                alpha = 1f
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - downX
                val dy = event.rawY - downY
                if (!dragging && hypot(dx, dy) > touchSlop) dragging = true
                if (dragging) {
                    x = startX + dx
                    y = startY + dy
                }
            }
            MotionEvent.ACTION_UP -> {
                if (dragging) snap() else showMenu()
                alpha = IDLE_ALPHA
            }
            MotionEvent.ACTION_CANCEL -> {
                if (dragging) snap()
                alpha = IDLE_ALPHA
            }
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        showMenu()
        return true
    }

    /** Snap to the nearer side edge and remember side and height. */
    private fun snap() {
        val parent = parent as? View ?: return
        val travel = (parent.height - 2 * margin - size).coerceAtLeast(1)
        prefs.actionsButtonRight = x + size / 2f > parent.width / 2f
        prefs.actionsButtonY = ((y - margin) / travel).coerceIn(0f, 1f)
        val target = if (prefs.actionsButtonRight) (parent.width - margin - size).toFloat() else margin.toFloat()
        animate().x(target).y(margin + prefs.actionsButtonY * travel).setDuration(200).start()
    }

    private fun showMenu() {
        val menu = PopupMenu(context, this)
        val shown = actions.mapNotNull { name -> LABELS[name]?.let { name to it } }
        shown.forEachIndexed { i, (_, label) -> menu.menu.add(0, i, i, label) }
        menu.setOnMenuItemClickListener { item ->
            onAction(shown[item.itemId].first)
            true
        }
        menu.show()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val IDLE_ALPHA = 0.7f

        /** Wire names (PROTOCOL.md 6.1 `gesture`) to menu labels. */
        private val LABELS = mapOf(
            "missionControl" to R.string.action_mission_control,
            "appExpose" to R.string.action_app_expose,
            "showDesktop" to R.string.action_show_desktop,
            "apps" to R.string.action_apps,
            "spotlight" to R.string.action_spotlight,
            "spaceLeft" to R.string.action_space_left,
            "spaceRight" to R.string.action_space_right,
        )
    }
}
