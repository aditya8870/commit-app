package com.commit.app

import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.inputmethod.InputMethodManager

/**
 * PRIMARY detector. Android tells this service the moment any app's window
 * comes to the front, so the locked app is covered straight away instead of
 * being noticed by a periodic check.
 *
 * Android itself keeps this service bound, restarts it after a reboot, and lets
 * it open the blocking screen from the background.
 *
 * Privacy: it only receives TYPE_WINDOW_STATE_CHANGED events and only looks at
 * the event's package name. It is declared with canRetrieveWindowContent="false",
 * so Android gives it no access to what is on screen. Nothing is logged or
 * stored. While no commitment is running the event filter is narrowed to
 * Commit's own package, so it hears nothing about other apps.
 */
class CommitAccessibilityService : AccessibilityService() {

    companion object {
        private const val RECHECK_MS = 30_000L

        fun isEnabled(ctx: Context): Boolean {
            val enabled = Settings.Secure.getString(
                ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            val me = ComponentName(ctx, CommitAccessibilityService::class.java)
            return enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val recheck = Runnable { evaluate() }
    private var lock: LockState? = null
    private var foregroundPkg: String? = null
    private var ignoredPkgs: Set<String> = emptySet()
    private var receiverRegistered = false

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = evaluate()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Blocker.accessibility = this
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        registerReceiver(screenReceiver, filter)
        receiverRegistered = true
        refresh()
        // Also (re)start the backup service, e.g. after a reboot.
        BlockerService.sync(this)
    }

    /** Called after Flutter saves new state, and when the service (re)connects. */
    fun refresh() {
        handler.post {
            lock = LockState.read(this)
            PaymentApps.invalidate()
            ignoredPkgs = loadIgnoredPackages()
            evaluate()
        }
    }

    /** Keyboards and the system UI open windows over the app in front; they are not "the app in front". */
    private fun loadIgnoredPackages(): Set<String> {
        val set = mutableSetOf("com.android.systemui")
        try {
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.enabledInputMethodList.forEach { set.add(it.packageName) }
        } catch (e: Exception) {}
        return set
    }

    /** Applies the current state: event filter, immediate block if due, next time-based check. */
    private fun evaluate() {
        handler.removeCallbacks(recheck)
        val now = TrustedClock.now(this)
        val current = lock?.takeIf { it.isLive(now) }
        applyEventFilter(current != null)
        if (current == null) {
            Blocker.hideOverlay()
            return
        }
        Blocker.onTimeCheck(this, current, now)
        // Keep the backup service alive in case Android stopped it.
        if (!BlockerService.running) BlockerService.sync(this)
        if (current.blocks(now)) {
            // Covers "emergency access just ended while the app is still open".
            val front = foregroundPkg
            if (front != null && current.locksNow(this, front, now)) {
                Blocker.block(this, current.nameOf(front), current.inCheckout(now))
            }
        } else {
            Blocker.hideOverlay() // emergency access is running
        }
        var boundary = if (current.inEmergency(now)) current.emergencyEnd!! else current.endTime
        if (current.inCheckout(now) && current.checkoutUntil < boundary) boundary = current.checkoutUntil
        handler.postDelayed(recheck, (boundary - now + 50L).coerceIn(250L, RECHECK_MS))
    }

    private fun applyEventFilter(commitmentRunning: Boolean) {
        val info = serviceInfo ?: return
        // null = all packages (needed to know which app is in front);
        // otherwise only our own package, i.e. effectively nothing.
        info.packageNames = if (commitmentRunning) null else arrayOf(packageName)
        serviceInfo = info
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null || event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        // Our own windows (including the lock overlay) say nothing about what is underneath.
        if (pkg == packageName || pkg in ignoredPkgs) return
        foregroundPkg = pkg
        val current = lock
        val now = TrustedClock.now(this)
        if (current != null && current.locksNow(this, pkg, now)) {
            Blocker.block(this, current.nameOf(pkg), current.inCheckout(now))
        } else {
            Blocker.hideOverlaySoon() // a different app is in front now
        }
    }

    /** Commit's own screen is in front (called from MainActivity). */
    fun onCommitResumed() {
        foregroundPkg = packageName
    }

    override fun onInterrupt() {}

    /** Android calls this when the user switches the service off in Settings. */
    override fun onUnbind(intent: Intent?): Boolean {
        if (IntegrityLog.isLive(this)) {
            IntegrityLog.record(this, IntegrityLog.ACCESSIBILITY_OFF)
            // If the backup cannot take over either, tell the user straight away.
            if (!BlockerService.hasUsageAccess(this) || !BlockerService.hasOverlay(this)) {
                IntegrityLog.notifyInterrupted(this)
            }
        }
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        // The overlay belongs to this service's window token; remove it before going away.
        Blocker.hideOverlay()
        Blocker.accessibility = null
        handler.removeCallbacks(recheck)
        if (receiverRegistered) {
            try { unregisterReceiver(screenReceiver) } catch (e: Exception) {}
            receiverRegistered = false
        }
        super.onDestroy()
    }
}
