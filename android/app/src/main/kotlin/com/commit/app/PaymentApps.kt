package com.commit.app

import android.content.Context
import android.content.Intent
import android.net.Uri

/**
 * Apps a payment may need: anything that can handle a UPI payment request,
 * plus the Play Store (which hosts Google Play's own purchase screen).
 *
 * Used for one narrow rule: while a payment checkout is open, these apps are
 * not blocked even if the user chose to block them, so the blocker can never
 * stop someone from paying to end their challenge. Every other blocked app
 * stays blocked. See [LockState.locksNow].
 */
object PaymentApps {
    private const val PLAY_STORE = "com.android.vending"

    @Volatile
    private var cached: Set<String>? = null

    fun packages(ctx: Context): Set<String> {
        cached?.let { return it }
        val set = mutableSetOf(PLAY_STORE)
        try {
            val upi = Intent(Intent.ACTION_VIEW, Uri.parse("upi://pay"))
            ctx.packageManager.queryIntentActivities(upi, 0).forEach { set.add(it.activityInfo.packageName) }
        } catch (e: Exception) {
            // Only the Play Store is exempt then.
        }
        cached = set
        return set
    }

    /** Call when the lock state is re-read, so newly installed apps are seen. */
    fun invalidate() {
        cached = null
    }
}
