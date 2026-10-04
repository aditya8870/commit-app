import 'package:flutter/services.dart';

class AppInfo {
  const AppInfo({required this.packageName, required this.appName, this.icon});
  final String packageName;
  final String appName;
  final Uint8List? icon;
}

/// Everything the Dart side needs from Android. Faked in tests.
abstract class PlatformBridge {
  Future<String?> loadState();
  Future<void> saveState(String json);
  Future<int> trustedNowMillis();
  Future<void> reanchorClock();

  /// Sets the tamper-resistant clock to the server's time. From then on it
  /// keeps counting with the phone's monotonic clock, as before.
  Future<void> anchorClock(int serverMillis);
  Future<bool> isAccessibilityEnabled();
  Future<void> openAccessibilitySettings();
  Future<bool> isBatteryUnrestricted();
  Future<void> openBatterySettings();

  /// Opens an https page (the privacy policy) in the browser.
  Future<void> openUrl(String url);

  /// Interruption events recorded natively since the last call, as JSON.
  Future<String> drainIntegrityEvents();
  Future<bool> isUsageAccessEnabled();
  Future<bool> isOverlayEnabled();
  Future<void> openUsageAccessSettings();
  Future<void> openOverlaySettings();
  Future<void> requestNotificationPermission();
  Future<List<AppInfo>> installedApps();
  Future<bool> isAppInstalled(String packageName);
  Future<bool> isBlockable(String packageName);
  Future<bool> launchApp(String packageName);
  Future<void> goHome();
  Future<String> appVersion();

  /// "blocked" if the app was opened by the blocking service, else null.
  Future<String?> consumeLaunchAction();
  void setLaunchActionHandler(void Function(String action)? handler);
}

class MethodChannelBridge implements PlatformBridge {
  MethodChannelBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLaunchAction' && call.arguments is String) {
        _handler?.call(call.arguments as String);
      }
    });
  }

  static const _channel = MethodChannel('com.commit.app/native');
  void Function(String action)? _handler;

  @override
  Future<String?> loadState() => _channel.invokeMethod<String>('loadState');

  @override
  Future<void> saveState(String json) =>
      _channel.invokeMethod<void>('saveState', json);

  @override
  Future<int> trustedNowMillis() async =>
      (await _channel.invokeMethod<int>('trustedNow'))!;

  @override
  Future<void> reanchorClock() => _channel.invokeMethod<void>('reanchorClock');

  @override
  Future<void> anchorClock(int serverMillis) =>
      _channel.invokeMethod<void>('anchorClock', serverMillis);

  @override
  Future<bool> isAccessibilityEnabled() async =>
      await _channel.invokeMethod<bool>('isAccessibilityEnabled') ?? false;

  @override
  Future<void> openAccessibilitySettings() =>
      _channel.invokeMethod<void>('openAccessibilitySettings');

  @override
  Future<bool> isBatteryUnrestricted() async =>
      await _channel.invokeMethod<bool>('isBatteryUnrestricted') ?? false;

  @override
  Future<void> openBatterySettings() =>
      _channel.invokeMethod<void>('openBatterySettings');

  @override
  Future<void> openUrl(String url) =>
      _channel.invokeMethod<void>('openUrl', url);

  @override
  Future<String> drainIntegrityEvents() async =>
      await _channel.invokeMethod<String>('drainIntegrityEvents') ?? '[]';

  @override
  Future<bool> isUsageAccessEnabled() async =>
      await _channel.invokeMethod<bool>('isUsageAccessEnabled') ?? false;

  @override
  Future<bool> isOverlayEnabled() async =>
      await _channel.invokeMethod<bool>('isOverlayEnabled') ?? false;

  @override
  Future<void> openUsageAccessSettings() =>
      _channel.invokeMethod<void>('openUsageAccessSettings');

  @override
  Future<void> openOverlaySettings() =>
      _channel.invokeMethod<void>('openOverlaySettings');

  @override
  Future<void> requestNotificationPermission() =>
      _channel.invokeMethod<void>('requestNotificationPermission');

  @override
  Future<List<AppInfo>> installedApps() async {
    final raw = await _channel.invokeListMethod<Map>('getInstalledApps') ?? [];
    return [
      for (final m in raw)
        AppInfo(
          packageName: m['packageName'] as String,
          appName: m['appName'] as String,
          icon: m['icon'] as Uint8List?,
        ),
    ];
  }

  @override
  Future<bool> isAppInstalled(String packageName) async =>
      await _channel.invokeMethod<bool>('isAppInstalled', packageName) ?? true;

  @override
  Future<bool> isBlockable(String packageName) async =>
      await _channel.invokeMethod<bool>('isBlockable', packageName) ?? false;

  @override
  Future<bool> launchApp(String packageName) async =>
      await _channel.invokeMethod<bool>('launchApp', packageName) ?? false;

  @override
  Future<void> goHome() => _channel.invokeMethod<void>('goHome');

  @override
  Future<String> appVersion() async =>
      await _channel.invokeMethod<String>('appVersion') ?? '';

  @override
  Future<String?> consumeLaunchAction() =>
      _channel.invokeMethod<String>('consumeLaunchAction');

  @override
  void setLaunchActionHandler(void Function(String action)? handler) =>
      _handler = handler;
}
