package com.commit.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.Uri
import android.provider.Settings
import android.telecom.TelecomManager
import android.view.inputmethod.InputMethodManager
import java.io.ByteArrayOutputStream

/** Lists launchable apps that may be blocked, excluding critical system apps. */
object AppListProvider {
    private val ALWAYS_EXCLUDED = setOf(
        "com.android.settings",
        "com.android.systemui",
        "com.android.phone",
        "com.android.dialer",
        "com.google.android.dialer",
        "com.samsung.android.dialer",
        "com.android.server.telecom",
        "com.android.emergency",
        "com.google.android.apps.safetyhub",
        "com.android.stk",
        "com.android.packageinstaller",
        "com.google.android.packageinstaller",
        "com.android.permissioncontroller",
        "com.google.android.permissioncontroller",
    )

    fun excluded(ctx: Context): Set<String> {
        val pm = ctx.packageManager
        val set = ALWAYS_EXCLUDED.toMutableSet()
        set.add(ctx.packageName)
        fun resolve(intent: Intent) {
            try {
                pm.queryIntentActivities(intent, 0).forEach { set.add(it.activityInfo.packageName) }
            } catch (e: Exception) {}
        }
        resolve(Intent(Settings.ACTION_SETTINGS))
        resolve(Intent(Intent.ACTION_DIAL, Uri.parse("tel:")))
        resolve(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME))
        try {
            (ctx.getSystemService(Context.TELECOM_SERVICE) as TelecomManager).defaultDialerPackage?.let { set.add(it) }
        } catch (e: Exception) {}
        try {
            (ctx.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                .enabledInputMethodList.forEach { set.add(it.packageName) }
        } catch (e: Exception) {}
        return set
    }

    fun isBlockable(ctx: Context, pkg: String) = pkg.isNotEmpty() && pkg !in excluded(ctx)

    fun isInstalled(ctx: Context, pkg: String): Boolean =
        ctx.packageManager.getLaunchIntentForPackage(pkg) != null || try {
            ctx.packageManager.getPackageInfo(pkg, 0); true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }

    fun list(ctx: Context): List<Map<String, Any?>> {
        val pm = ctx.packageManager
        val skip = excluded(ctx)
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val out = ArrayList<Map<String, Any?>>()
        for (ri in pm.queryIntentActivities(launcher, 0)) {
            val pkg = ri.activityInfo.packageName
            if (pkg in skip || !seen.add(pkg)) continue
            val icon = try { toPng(ri.loadIcon(pm)) } catch (e: Exception) { null }
            out.add(mapOf("packageName" to pkg, "appName" to ri.loadLabel(pm).toString(), "icon" to icon))
        }
        out.sortBy { (it["appName"] as String).lowercase() }
        return out
    }

    private fun toPng(d: Drawable, size: Int = 96): ByteArray {
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        d.setBounds(0, 0, size, size)
        d.draw(canvas)
        val bos = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, bos)
        bmp.recycle()
        return bos.toByteArray()
    }
}
