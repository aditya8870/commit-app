package com.commit.app

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the Google Play release rules against regressions: Commit must never
 * stop the user from uninstalling it, clearing its data or switching its
 * access off, and its Accessibility service must stay narrow.
 */
class PlayPolicyTest {
    private val main = listOf("src/main", "app/src/main", "android/app/src/main")
        .map { File(it) }.first { it.isDirectory }
    private val manifest = File(main, "AndroidManifest.xml").readText()
    private val sources = File(main, "kotlin").walkTopDown().filter { it.extension == "kt" }.toList()

    @Test
    fun noDeviceAdmin_soUninstallIsNeverBlocked() {
        assertFalse(manifest.contains("BIND_DEVICE_ADMIN"))
        assertFalse(manifest.contains("android.app.device_admin"))
        assertFalse(File(main, "res/xml/device_admin.xml").exists())
        for (f in sources) {
            val code = f.readText()
            assertFalse(f.name, code.contains("DevicePolicyManager"))
            assertFalse(f.name, code.contains("DeviceAdminReceiver"))
        }
    }

    @Test
    fun clearDataIsNotReplaced() {
        assertFalse(manifest.contains("manageSpaceActivity"))
        for (f in sources) assertFalse(f.name, f.readText().contains("clearApplicationUserData"))
    }

    @Test
    fun accessibilityServiceIsNarrowAndNotAnAccessibilityTool() {
        val config = File(main, "res/xml/accessibility_service_config.xml").readText()
        assertTrue(config.contains("android:canRetrieveWindowContent=\"false\""))
        assertTrue(config.contains("android:accessibilityEventTypes=\"typeWindowStateChanged\""))
        assertFalse(config.contains("isAccessibilityTool"))
        assertFalse(config.contains("canPerformGestures"))
        assertFalse(config.contains("canRequestFilterKeyEvents"))
    }

    @Test
    fun settingsAndInstallerCanNeverBeBlocked() {
        val list = File(main, "kotlin/com/commit/app/AppListProvider.kt").readText()
        for (pkg in listOf("com.android.settings", "com.android.packageinstaller",
            "com.google.android.packageinstaller", "com.android.permissioncontroller")) {
            assertTrue(pkg, list.contains("\"$pkg\""))
        }
    }

    @Test
    fun noBroadPackageVisibilityNoPaymentNoCleartext() {
        assertFalse(manifest.contains("permission.QUERY_ALL_PACKAGES"))
        assertFalse(manifest.contains("BILLING"))
        assertFalse(manifest.contains("upi"))
        assertTrue(manifest.contains("android:usesCleartextTraffic=\"false\""))
        assertTrue(manifest.contains("android:allowBackup=\"false\""))
    }
}
