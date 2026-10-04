package com.commit.app

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The one place that actually blocks an app. Both detectors call into it:
 *
 *  - [CommitAccessibilityService] (primary): event-driven, reacts the moment
 *    the locked app's window appears.
 *  - [BlockerService] (backup): polls Android's usage log, and only acts while
 *    the Accessibility service is not connected.
 *
 * Blocking is three steps, in this order, to keep the locked app from being
 * visible, audible or usable:
 *  1. draw an opaque lock screen over it immediately,
 *  2. pause whatever is playing (media "pause" key + taking audio focus),
 *  3. open Commit's blocked screen on top of it.
 *
 * We deliberately do NOT press Home: for a video app that counts as "the user
 * left", which makes it shrink into a picture-in-picture window and keep
 * playing. Opening Commit with FLAG_ACTIVITY_NO_USER_ACTION avoids that.
 *
 * Everything here runs on the main thread.
 */
object Blocker {
    const val EXTRA_ACTION = "commit_action"
    const val ACTION_BLOCKED = "blocked"
    private const val RELAUNCH_MS = 1500L

    /** Set while the Accessibility service is connected. */
    @Volatile
    var accessibility: CommitAccessibilityService? = null

    private var overlay: View? = null
    private var overlayWm: WindowManager? = null
    private var lastLaunchAt = 0L

    val overlayShown: Boolean get() = overlay != null

    private val handler = Handler(Looper.getMainLooper())
    private val delayedHide = Runnable { hideOverlay() }
    private const val HIDE_DELAY_MS = 400L

    /**
     * [duringCheckout]: a payment checkout is open inside Commit. Commit is
     * then brought forward exactly as it is, so the checkout screen on top
     * of it is not closed.
     */
    fun block(ctx: Context, appName: String, duringCheckout: Boolean = false) {
        handler.removeCallbacks(delayedHide)
        showOverlay(ctx, appName)
        val t = SystemClock.elapsedRealtime()
        if (t - lastLaunchAt < RELAUNCH_MS) return
        lastLaunchAt = t
        pauseMedia(ctx)
        if (duringCheckout) bringCommitForward(ctx) else openCommit(ctx)
    }

    /** Brings Commit's task to the front without touching the screens in it. */
    private fun bringCommitForward(ctx: Context) {
        try {
            val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: return
            ctx.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION))
        } catch (e: Exception) {}
    }

    private var wasInEmergency = false

    /**
     * Called by the active detector on every time check. When emergency access
     * has just ended, playback is paused even if the locked app is not in front
     * (it may be playing in the background or in a picture-in-picture window).
     */
    fun onTimeCheck(ctx: Context, lock: LockState, now: Long) {
        val inEmergency = lock.inEmergency(now)
        if (wasInEmergency && !inEmergency && lock.blocks(now)) pauseMedia(ctx)
        wasInEmergency = inEmergency
    }

    /** Asks the playing app to pause, the same way a headset's pause button does. */
    fun pauseMedia(ctx: Context) {
        try {
            val am = ctx.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (!am.isMusicActive) return
            am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PAUSE))
            am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PAUSE))
            // Taking audio focus makes well-behaved players stop and not resume by themselves.
            if (Build.VERSION.SDK_INT >= 26) {
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN).build()
                am.requestAudioFocus(req)
                handler.postDelayed({ try { am.abandonAudioFocusRequest(req) } catch (e: Exception) {} }, 1500L)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
                @Suppress("DEPRECATION")
                handler.postDelayed({ try { am.abandonAudioFocus(null) } catch (e: Exception) {} }, 1500L)
            }
        } catch (e: Exception) {}
    }

    fun goHome(ctx: Context) {
        val acc = accessibility
        if (acc != null && acc.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME)) return
        try {
            ctx.startActivity(
                Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (e: Exception) {}
    }

    fun openCommit(ctx: Context) {
        try {
            ctx.startActivity(Intent(ctx, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NO_USER_ACTION
                )
                putExtra(EXTRA_ACTION, ACTION_BLOCKED)
            })
        } catch (e: Exception) {}
    }

    /**
     * Full-screen opaque cover. Drawn through the Accessibility service when it
     * is connected (needs no extra permission), otherwise through
     * "Display over other apps".
     */
    private fun showOverlay(appCtx: Context, appName: String) {
        if (overlay != null) return
        val acc = accessibility
        val ctx: Context
        val type: Int
        if (acc != null) {
            ctx = acc
            type = WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY
        } else if (Settings.canDrawOverlays(appCtx)) {
            ctx = appCtx
            @Suppress("DEPRECATION")
            type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else WindowManager.LayoutParams.TYPE_PHONE
        } else {
            return
        }

        val d = ctx.resources.displayMetrics.density
        fun dp(v: Int) = (v * d).toInt()
        val ink = Color.parseColor("#1E2A2B")
        val green = Color.parseColor("#2F5D62")

        fun text(s: String, sp: Float, bold: Boolean, top: Int) = TextView(ctx).apply {
            text = s
            textSize = sp
            setTextColor(ink)
            gravity = Gravity.CENTER
            if (bold) setTypeface(typeface, Typeface.BOLD)
            setPadding(0, dp(top), 0, 0)
        }

        fun button(s: String, filled: Boolean, onClick: () -> Unit) = Button(ctx).apply {
            text = s
            textSize = 16f
            isAllCaps = true
            setTextColor(if (filled) Color.WHITE else green)
            setBackgroundColor(if (filled) green else Color.parseColor("#E3E1DA"))
            setOnClickListener { onClick() }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(56)).apply { topMargin = dp(12) }
        }

        val root = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#F7F6F2"))
            setPadding(dp(28), dp(28), dp(28), dp(28))
            isClickable = true // swallow touches so the app underneath cannot be used
            addView(text("🔒 $appName is locked", 26f, true, 0))
            addView(text("Your commitment is still active.", 18f, false, 16))
            addView(text("Your decision was made before the temptation.", 15f, false, 6))
            addView(View(ctx), LinearLayout.LayoutParams(1, dp(28)))
            addView(button("Open Commit", true) { pauseMedia(ctx); openCommit(ctx) })
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.OPAQUE,
        )
        params.windowAnimations = 0 // appear instantly, no fade-in
        try {
            val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.addView(root, params)
            overlay = root
            overlayWm = wm
        } catch (e: Exception) {
            overlay = null
            overlayWm = null
        }
    }

    /**
     * Removes the cover a moment later, so the locked app is not seen sliding
     * away during the transition to the home screen. Cancelled if the app is
     * blocked again in the meantime.
     */
    fun hideOverlaySoon() {
        if (overlay == null) return
        handler.removeCallbacks(delayedHide)
        handler.postDelayed(delayedHide, HIDE_DELAY_MS)
    }

    fun hideOverlay() {
        handler.removeCallbacks(delayedHide)
        val v = overlay ?: return
        val wm = overlayWm
        overlay = null
        overlayWm = null
        try { wm?.removeView(v) } catch (e: Exception) {}
    }
}
