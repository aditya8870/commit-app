package com.commit.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and exposes the small native API it needs
 * (channel "com.commit.app/native"). All blocking logic lives in [BlockerService].
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingAction: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingAction = intent?.getStringExtra(Blocker.EXTRA_ACTION)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val action = intent.getStringExtra(Blocker.EXTRA_ACTION) ?: return
        pendingAction = action
        channel?.invokeMethod("onLaunchAction", action)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.commit.app/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "loadState" -> result.success(NativeStore.load(this))
                    "saveState" -> {
                        val ok = NativeStore.save(this, call.arguments as String)
                        Blocker.accessibility?.refresh()
                        BlockerService.sync(this)
                        if (ok) result.success(null) else result.error("save_failed", "Could not save data", null)
                    }
                    "trustedNow" -> result.success(TrustedClock.now(this))
                    "reanchorClock" -> { TrustedClock.reanchor(this); result.success(null) }
                    "anchorClock" -> {
                        TrustedClock.anchorTo(this, (call.arguments as Number).toLong())
                        // Blocking re-reads the corrected time at once.
                        Blocker.accessibility?.refresh()
                        BlockerService.sync(this)
                        result.success(null)
                    }
                    "isAccessibilityEnabled" -> result.success(CommitAccessibilityService.isEnabled(this))
                    "openAccessibilitySettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    }
                    "isBatteryUnrestricted" -> result.success(
                        (getSystemService(POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(packageName)
                    )
                    "openBatterySettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        } catch (e: Exception) {
                            openSettings(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        }
                        result.success(null)
                    }
                    "openUrl" -> {
                        // Only https pages (the privacy policy) are ever opened.
                        val url = call.arguments as? String
                        if (url != null && url.startsWith("https://")) {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            } catch (e: Exception) {}
                        }
                        result.success(null)
                    }
                    "drainIntegrityEvents" -> result.success(IntegrityLog.drain(this))
                    "isUsageAccessEnabled" -> result.success(BlockerService.hasUsageAccess(this))
                    "isOverlayEnabled" -> result.success(BlockerService.hasOverlay(this))
                    "openUsageAccessSettings" -> {
                        openSettings(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                        result.success(null)
                    }
                    "openOverlaySettings" -> {
                        openSettings(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                        result.success(null)
                    }
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                        }
                        result.success(null)
                    }
                    "consumeLaunchAction" -> { result.success(pendingAction); pendingAction = null }
                    "goHome" -> {
                        startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    }
                    "launchApp" -> {
                        val launch = packageManager.getLaunchIntentForPackage(call.arguments as String)
                        if (launch != null) startActivity(launch)
                        result.success(launch != null)
                    }
                    "isAppInstalled" -> result.success(AppListProvider.isInstalled(this, call.arguments as String))
                    "isBlockable" -> result.success(AppListProvider.isBlockable(this, call.arguments as String))
                    "appVersion" -> result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                    // Installation identity (no blocking logic involved).
                    "secureRead" -> result.success(SecureStore.read(this, call.arguments as String))
                    "secureWrite" -> {
                        val args = call.arguments as Map<*, *>
                        val ok = SecureStore.write(this, args["name"] as String, args["value"] as String)
                        if (ok) result.success(null) else result.error("secure_write_failed", "Could not store value", null)
                    }
                    "secureDelete" -> {
                        SecureStore.delete(this, call.arguments as String)
                        result.success(null)
                    }
                    "recoveryMaterial" -> result.success(RecoveryMaterial.forThisDevice(this))
                    "androidVersion" -> result.success(Build.VERSION.RELEASE)
                    "getInstalledApps" -> Thread {
                        val apps = try { AppListProvider.list(applicationContext) } catch (e: Exception) { null }
                        runOnUiThread {
                            if (apps != null) result.success(apps) else result.error("apps_failed", "Could not read installed apps", null)
                        }
                    }.start()
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("native_error", e.message, null)
            }
        }
    }

    /** Opens a settings page for this app; falls back to the general list if needed. */
    private fun openSettings(action: String) {
        try {
            startActivity(Intent(action, Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    override fun onResume() {
        super.onResume()
        // Commit is in front: the lock overlay has done its job.
        Blocker.hideOverlay()
        Blocker.accessibility?.onCommitResumed()
        // Make sure the backup service is running whenever Commit is opened.
        BlockerService.sync(this)
    }
}
