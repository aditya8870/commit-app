package com.commit.app

import android.app.AppOpsManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.provider.Settings

/**
 * BACKUP detector, and the visible "Commitment active" notification.
 *
 * Runs as a foreground service only while a commitment is live. Its job is to
 * keep blocking if the Accessibility service is not connected (never enabled,
 * or switched off during a commitment):
 *  - a few times a second, while the screen is on, it asks Android's usage log
 *    (Usage access) which app is in front;
 *  - if that is the committed app and it should be blocked, it calls [Blocker],
 *    which covers it using "Display over other apps".
 *
 * While the Accessibility service IS connected, this service does no detection
 * of its own (one detector at a time, so they cannot disagree) and only checks
 * every few seconds whether it needs to take over.
 *
 * Privacy: only app package names from the usage log are looked at, they are
 * kept in memory only, and nothing is stored or sent anywhere.
 */
class BlockerService : Service() {

    companion object {
        private const val CHANNEL_ID = "commitment"
        private const val NOTIFICATION_ID = 1
        private const val POLL_MS = 250L
        private const val STANDBY_MS = 3000L

        @Volatile
        var running = false

        /** Starts the service if a commitment is live, stops it otherwise. */
        fun sync(ctx: Context) {
            val app = ctx.applicationContext
            val intent = Intent(app, BlockerService::class.java)
            val live = LockState.read(app)?.isLive(TrustedClock.now(app)) == true
            try {
                if (live) {
                    if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(intent) else app.startService(intent)
                } else if (running) {
                    app.stopService(intent)
                }
            } catch (e: Exception) {
                // Android refused a background start; it is retried when Commit is next opened.
            }
        }

        fun hasUsageAccess(ctx: Context): Boolean {
            val ops = ctx.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= 29) {
                ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName)
            } else {
                @Suppress("DEPRECATION")
                ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), ctx.packageName)
            }
            return mode == AppOpsManager.MODE_ALLOWED
        }

        fun hasOverlay(ctx: Context): Boolean = Settings.canDrawOverlays(ctx)
    }

    private val handler = Handler(Looper.getMainLooper())
    private val poll = Runnable { tick() }
    private var lock: LockState? = null

    /** "package/activity" entries currently resumed, rebuilt from usage events. */
    private val resumed = HashSet<String>()
    private var lastEventTime = 0L
    private var detecting = false

    /** True while no detector can work (edge-triggered, so it is logged once). */
    private var lost = false
    private var receiverRegistered = false

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            handler.removeCallbacks(poll)
            if (intent?.action != Intent.ACTION_SCREEN_OFF) handler.post(poll)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        registerReceiver(screenReceiver, filter)
        receiverRegistered = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lock = LockState.read(this)
        PaymentApps.invalidate()
        try {
            val n = buildNotification()
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
        } catch (e: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        handler.removeCallbacks(poll)
        handler.post(poll)
        // START_STICKY: if Android kills the service it is recreated and re-reads the saved state.
        return START_STICKY
    }

    private fun tick() {
        handler.removeCallbacks(poll)
        val now = TrustedClock.now(this)
        val current = lock?.takeIf { it.isLive(now) }
        if (current == null) {
            // Commitment finished (or was removed): nothing left to protect.
            if (detecting) Blocker.hideOverlay()
            stopSelf()
            return
        }
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager

        if (Blocker.accessibility != null) {
            // Primary detector is connected: stand by.
            detecting = false
            if (lost) {
                lost = false
                IntegrityLog.record(this, IntegrityLog.PROTECTION_RESTORED, now)
                IntegrityLog.clearNotification(this)
            }
            if (pm.isInteractive) handler.postDelayed(poll, STANDBY_MS)
            return
        }
        Blocker.onTimeCheck(this, current, now)
        // No Accessibility. The backup needs both of its permissions.
        val canBackup = hasUsageAccess(this) && hasOverlay(this)
        if (!canBackup && !lost) {
            lost = true
            IntegrityLog.record(this, IntegrityLog.PROTECTION_LOST, now)
            IntegrityLog.notifyInterrupted(this)
        } else if (canBackup && lost) {
            lost = false
            IntegrityLog.record(this, IntegrityLog.PROTECTION_RESTORED, now)
            IntegrityLog.clearNotification(this)
        }
        if (!detecting) {
            // Taking over: start from a clean picture of what is in front.
            detecting = true
            resumed.clear()
            lastEventTime = 0L
        }
        readUsageEvents()
        val front = resumed.map { it.substringBefore('/') }.firstOrNull { current.locksNow(this, it, now) }
        if (front != null) Blocker.block(this, current.nameOf(front), current.inCheckout(now)) else Blocker.hideOverlay()

        if (pm.isInteractive) handler.postDelayed(poll, POLL_MS)
    }

    /** Updates [resumed] from Android's usage log. Returns nothing if Usage access is off. */
    private fun readUsageEvents() {
        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val end = System.currentTimeMillis()
        // First run: look back far enough to learn what is in front right now.
        val begin = if (lastEventTime == 0L) end - 6 * 60 * 60 * 1000L else lastEventTime - 2000L
        val events = try { usm.queryEvents(begin, end) } catch (e: Exception) { null } ?: return
        val ev = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(ev)
            if (ev.timeStamp <= lastEventTime) continue
            val key = ev.packageName + "/" + (ev.className ?: "")
            when (ev.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> resumed.add(key)
                UsageEvents.Event.ACTIVITY_PAUSED, 23 /* ACTIVITY_STOPPED */ -> resumed.remove(key)
                26, 27 /* device shutdown / startup */ -> resumed.clear()
                else -> continue
            }
            lastEventTime = ev.timeStamp
        }
        if (lastEventTime == 0L) lastEventTime = end - 1
    }

    // ------------------------------------------------------------ notification

    private fun buildNotification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Active commitment", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        return b.setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setContentTitle("Commitment active")
            .setContentText("${lock?.summary() ?: "Your selected app"} locked until your commitment ends.")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        running = false
        handler.removeCallbacks(poll)
        if (detecting) Blocker.hideOverlay()
        if (receiverRegistered) {
            try { unregisterReceiver(screenReceiver) } catch (e: Exception) {}
            receiverRegistered = false
        }
        super.onDestroy()
    }
}

/** Restarts protection after the phone reboots or Commit is updated. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON" -> BlockerService.sync(context)
        }
    }
}
