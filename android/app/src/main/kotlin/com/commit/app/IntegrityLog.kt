package com.commit.app

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/**
 * Records things that weaken protection during a live challenge, so they are
 * not silently forgotten:
 *
 *   forceStopped         Commit's process was stopped by the user (found
 *                        afterwards from Android's own exit records)
 *   accessibilityOff     the Accessibility service was switched off
 *   protectionLost       no detector can run any more (all permissions off)
 *   protectionRestored   a detector can run again
 *
 * The native side only APPENDS to this small log. Flutter drains it and stores
 * the events on the challenge they belong to. Nothing here ever charges money
 * or ends a challenge.
 */
object IntegrityLog {
    private const val KEY_EVENTS = "integrity_events"
    private const val KEY_EXIT_SCAN = "integrity_exit_scan"
    private const val MAX_EVENTS = 200
    private const val CHANNEL_ID = "protection"
    private const val NOTIFICATION_ID = 2

    const val FORCE_STOPPED = "forceStopped"
    const val ACCESSIBILITY_OFF = "accessibilityOff"
    const val PROTECTION_LOST = "protectionLost"
    const val PROTECTION_RESTORED = "protectionRestored"

    fun isLive(ctx: Context): Boolean =
        LockState.read(ctx)?.isLive(TrustedClock.now(ctx)) == true

    @Synchronized
    fun record(ctx: Context, type: String, atMillis: Long = TrustedClock.now(ctx)) {
        val p = NativeStore.prefs(ctx)
        val arr = try { JSONArray(p.getString(KEY_EVENTS, "[]")) } catch (e: Exception) { JSONArray() }
        if (arr.length() >= MAX_EVENTS) return
        arr.put(JSONObject().put("type", type).put("at", atMillis))
        p.edit().putString(KEY_EVENTS, arr.toString()).commit()
    }

    /** Returns all recorded events as JSON and empties the log. */
    @Synchronized
    fun drain(ctx: Context): String {
        scanExitReasons(ctx)
        val p = NativeStore.prefs(ctx)
        val raw = p.getString(KEY_EVENTS, "[]") ?: "[]"
        p.edit().remove(KEY_EVENTS).commit()
        return raw
    }

    /**
     * Android 11+ keeps a record of why an app's process ended. A force stop
     * cannot be noticed while it happens (nothing of ours is running), but it
     * can be read back here the next time Commit starts.
     */
    private fun scanExitReasons(ctx: Context) {
        if (Build.VERSION.SDK_INT < 30) return
        try {
            val p = NativeStore.prefs(ctx)
            val since = p.getLong(KEY_EXIT_SCAN, 0L)
            var newest = since
            val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            for (info in am.getHistoricalProcessExitReasons(ctx.packageName, 0, 30)) {
                if (info.timestamp <= since) continue
                if (info.timestamp > newest) newest = info.timestamp
                val text = (info.description ?: "").lowercase()
                val stopped = info.reason == ApplicationExitInfo.REASON_USER_STOPPED ||
                    (info.reason == ApplicationExitInfo.REASON_USER_REQUESTED &&
                        text.contains("stop") && !text.contains("remove task"))
                if (stopped) record(ctx, FORCE_STOPPED, info.timestamp)
            }
            if (newest > since) p.edit().putLong(KEY_EXIT_SCAN, newest).apply()
        } catch (e: Exception) {
            // The record is best-effort; some devices restrict it.
        }
    }

    /** Calm, factual notification. Tapping it opens Commit. */
    fun notifyInterrupted(ctx: Context) {
        try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Protection alerts", NotificationManager.IMPORTANCE_HIGH)
                )
            }
            val open = PendingIntent.getActivity(
                ctx, 1, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            @Suppress("DEPRECATION")
            val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL_ID) else Notification.Builder(ctx)
            nm.notify(
                NOTIFICATION_ID,
                b.setSmallIcon(android.R.drawable.ic_lock_idle_lock)
                    .setContentTitle("Your protection has been interrupted")
                    .setContentText("Your challenge is still active. Tap to restore protection.")
                    .setContentIntent(open)
                    .setAutoCancel(true)
                    .build(),
            )
        } catch (e: Exception) {}
    }

    fun clearNotification(ctx: Context) {
        try {
            (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIFICATION_ID)
        } catch (e: Exception) {}
    }
}
