package com.commit.app

import android.content.Context
import android.content.SharedPreferences
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONObject

/**
 * Single persisted source of truth for commitment data.
 *
 * The Flutter side is the only writer: it stores one JSON document here via the
 * method channel. The native side only READS it (see [LockState]) so the blocking
 * service keeps working when the Flutter UI is not running.
 */
object NativeStore {
    private const val PREFS = "commit_store"
    private const val KEY_STATE = "state_json"

    fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load(ctx: Context): String? = prefs(ctx).getString(KEY_STATE, null)

    /** Synchronous commit so the state is on disk before we report success. */
    fun save(ctx: Context, json: String): Boolean =
        prefs(ctx).edit().putString(KEY_STATE, json).commit()
}

/**
 * The minimum the blocking service needs to know: which package is locked and
 * the four timestamps. Whether the app is blocked is always DERIVED from these
 * timestamps and the current trusted time, never from a running countdown.
 */
data class LockState(
    /** Locked apps: package name -> display name. */
    val apps: Map<String, String>,
    val endTime: Long,
    val emergencyStart: Long?,
    val emergencyEnd: Long?,
    /** While a payment checkout is open: payment apps are let through until this time. 0 = no checkout. */
    val checkoutUntil: Long = 0L,
) {
    fun isLive(now: Long) = now < endTime

    fun inEmergency(now: Long): Boolean {
        val s = emergencyStart ?: return false
        val e = emergencyEnd ?: return false
        return now >= s && now < e
    }

    fun blocks(now: Long) = isLive(now) && !inEmergency(now)

    fun locks(pkg: String?) = pkg != null && apps.containsKey(pkg)

    fun inCheckout(now: Long) = now < checkoutUntil

    /**
     * Whether [pkg] must be blocked right now. During an open payment
     * checkout, payment apps are exempt so that the user can always pay;
     * every other locked app is still blocked.
     */
    fun locksNow(ctx: Context, pkg: String?, now: Long): Boolean {
        if (!locks(pkg) || !blocks(now)) return false
        if (inCheckout(now) && pkg in PaymentApps.packages(ctx)) return false
        return true
    }

    fun nameOf(pkg: String) = apps[pkg] ?: pkg

    /** Text for the notification: "Instagram", "Instagram + 2 more". */
    fun summary(): String {
        val names = apps.values.toList()
        return when {
            names.isEmpty() -> "Your selected app"
            names.size == 1 -> names[0]
            else -> "${names[0]} + ${names.size - 1} more"
        }
    }

    companion object {
        /** Returns the live (ACTIVE/EMERGENCY) commitment, or null. */
        fun read(ctx: Context): LockState? {
            val raw = NativeStore.load(ctx) ?: return null
            return try {
                val doc = JSONObject(raw)
                val checkoutUntil = doc.optJSONObject("checkout")?.optLong("until", 0L) ?: 0L
                val list = doc.optJSONArray("commitments") ?: return null
                for (i in 0 until list.length()) {
                    val c = list.optJSONObject(i) ?: continue
                    val status = c.optString("status")
                    if (status != "ACTIVE" && status != "EMERGENCY") continue
                    val end = c.optLong("endTime", 0L)
                    if (end <= 0L) continue

                    val apps = LinkedHashMap<String, String>()
                    val pkgs = c.optJSONArray("packageNames")
                    val names = c.optJSONArray("appNames")
                    if (pkgs != null) {
                        for (k in 0 until pkgs.length()) {
                            val pkg = pkgs.optString(k)
                            if (pkg.isNotEmpty()) apps[pkg] = names?.optString(k)?.ifEmpty { pkg } ?: pkg
                        }
                    } else {
                        // Saved by a version before 2.0: a single app.
                        val pkg = c.optString("packageName")
                        if (pkg.isNotEmpty()) apps[pkg] = c.optString("appName", pkg)
                    }
                    if (apps.isEmpty()) continue

                    return LockState(
                        apps,
                        end,
                        if (c.isNull("lastEmergencyStart")) null else c.optLong("lastEmergencyStart"),
                        if (c.isNull("lastEmergencyEnd")) null else c.optLong("lastEmergencyEnd"),
                        checkoutUntil,
                    )
                }
                null
            } catch (e: Exception) {
                null
            }
        }
    }
}

/**
 * Time source that does not follow manual changes of the system clock.
 *
 * It keeps an anchor (trusted time + monotonic elapsedRealtime + boot count).
 * Within one boot, time advances with the monotonic clock, so moving the system
 * clock forwards or backwards has no effect. After a reboot the monotonic clock
 * restarts, so we fall back to the wall clock but never let time go backwards.
 */
object TrustedClock {
    private const val K_TRUSTED = "anchor_trusted"
    private const val K_ELAPSED = "anchor_elapsed"
    private const val K_BOOT = "anchor_boot"
    private const val PERSIST_EVERY_MS = 15_000L

    private fun bootCount(ctx: Context): Int = try {
        Settings.Global.getInt(ctx.contentResolver, Settings.Global.BOOT_COUNT, -1)
    } catch (e: Exception) {
        -1
    }

    @Synchronized
    fun now(ctx: Context): Long {
        val p = NativeStore.prefs(ctx)
        val wall = System.currentTimeMillis()
        val elapsed = SystemClock.elapsedRealtime()
        val boot = bootCount(ctx)
        val aTrusted = p.getLong(K_TRUSTED, -1L)
        val aElapsed = p.getLong(K_ELAPSED, 0L)
        val aBoot = p.getInt(K_BOOT, -2)

        val sameBoot = aTrusted >= 0 && boot != -1 && boot == aBoot && elapsed >= aElapsed
        val now = when {
            aTrusted < 0 -> wall
            sameBoot -> aTrusted + (elapsed - aElapsed)
            else -> maxOf(wall, aTrusted)
        }
        if (!sameBoot || elapsed - aElapsed > PERSIST_EVERY_MS) write(p, now, elapsed, boot)
        return now
    }

    /** Re-sync with the wall clock. Only called when no commitment is running. */
    @Synchronized
    fun reanchor(ctx: Context) {
        write(NativeStore.prefs(ctx), System.currentTimeMillis(), SystemClock.elapsedRealtime(), bootCount(ctx))
    }

    /**
     * Sets the trusted time to the server's time. The server's clock is the
     * authority for challenges, so unlike [reanchor] this is allowed while a
     * challenge is running: it corrects a phone clock that was moved, in
     * either direction.
     */
    @Synchronized
    fun anchorTo(ctx: Context, serverMillis: Long) {
        if (serverMillis <= 0L) return
        write(NativeStore.prefs(ctx), serverMillis, SystemClock.elapsedRealtime(), bootCount(ctx))
    }

    private fun write(p: SharedPreferences, trusted: Long, elapsed: Long, boot: Int) {
        p.edit().putLong(K_TRUSTED, trusted).putLong(K_ELAPSED, elapsed).putInt(K_BOOT, boot).apply()
    }
}
