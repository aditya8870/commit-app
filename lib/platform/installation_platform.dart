import 'package:flutter/services.dart';

/// What installation identity needs from Android. Kept apart from
/// `PlatformBridge` so the blocking code is not touched.
abstract class InstallationPlatform {
  /// Reads a value from encrypted storage. Null if there is none.
  Future<String?> secureRead(String name);

  /// Writes a value to encrypted storage. Throws if it could not be stored.
  Future<void> secureWrite(String name, String value);

  Future<void> secureDelete(String name);

  /// The hash that lets the server recognise this phone after a reinstall:
  /// SHA-256("commit-recovery-v1:" + Android's per-app identifier), computed
  /// natively. The raw identifier never reaches Dart. Null if the phone has
  /// no usable identifier.
  Future<String?> recoveryMaterial();

  Future<String> appVersion();
  Future<String?> androidVersion();
}

class MethodChannelInstallationPlatform implements InstallationPlatform {
  static const _channel = MethodChannel('com.commit.app/native');

  @override
  Future<String?> secureRead(String name) =>
      _channel.invokeMethod<String>('secureRead', name);

  @override
  Future<void> secureWrite(String name, String value) => _channel
      .invokeMethod<void>('secureWrite', {'name': name, 'value': value});

  @override
  Future<void> secureDelete(String name) =>
      _channel.invokeMethod<void>('secureDelete', name);

  @override
  Future<String?> recoveryMaterial() =>
      _channel.invokeMethod<String>('recoveryMaterial');

  @override
  Future<String> appVersion() async =>
      await _channel.invokeMethod<String>('appVersion') ?? 'unknown';

  @override
  Future<String?> androidVersion() =>
      _channel.invokeMethod<String>('androidVersion');
}
