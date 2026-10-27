package app.opendisplay.android.ui

import android.os.Build
import android.view.View
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager

/**
 * Full screen without system bars, swipe to peek. The main screen and its
 * sheets share it, so a sheet never draws under a status bar the stream hid.
 */
@Suppress("DEPRECATION")
fun Window.enterImmersive() {
    addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)
    if (Build.VERSION.SDK_INT >= 30) {
        setDecorFitsSystemWindows(false)
        insetsController?.let {
            it.hide(WindowInsets.Type.systemBars())
            it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    } else {
        decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN)
    }
}

/**
 * Android's safe area: the system bars (as if shown, so content stays clear
 * of where a swiped-in status bar lands) plus the camera cutout. The iOS
 * sheets and idle screen sit inside the safe area; the stream does not.
 */
fun safeInsets(insets: WindowInsets): android.graphics.Rect {
    val r = android.graphics.Rect()
    if (Build.VERSION.SDK_INT >= 30) {
        val bars = insets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars())
        val cutout = insets.getInsets(WindowInsets.Type.displayCutout())
        r.set(maxOf(bars.left, cutout.left), maxOf(bars.top, cutout.top),
            maxOf(bars.right, cutout.right), maxOf(bars.bottom, cutout.bottom))
    } else {
        @Suppress("DEPRECATION")
        r.set(insets.stableInsetLeft, insets.stableInsetTop, insets.stableInsetRight, insets.stableInsetBottom)
        if (Build.VERSION.SDK_INT >= 28) {
            insets.displayCutout?.let { c ->
                r.set(maxOf(r.left, c.safeInsetLeft), maxOf(r.top, c.safeInsetTop),
                    maxOf(r.right, c.safeInsetRight), maxOf(r.bottom, c.safeInsetBottom))
            }
        }
    }
    return r
}

/** Pads this view by the safe area on top of its own padding, kept current on rotation. */
fun View.padToSafeArea() {
    val base = android.graphics.Rect(paddingLeft, paddingTop, paddingRight, paddingBottom)
    setOnApplyWindowInsetsListener { v, insets ->
        val s = safeInsets(insets)
        v.setPadding(base.left + s.left, base.top + s.top, base.right + s.right, base.bottom + s.bottom)
        insets
    }
    requestApplyInsets()
}
