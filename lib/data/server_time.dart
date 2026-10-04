import '../core/clock.dart';
import '../platform/platform_bridge.dart';

/// Keeps the phone's tamper-resistant clock in step with the server.
///
/// The server's clock decides when a challenge starts, ends and completes.
/// The phone's clock is only used to show remaining time and to keep blocking
/// while offline, so whenever the server is reachable its time replaces the
/// phone's. A clock that was moved while offline is corrected on the next
/// answer from the server.
class ServerTimeAligner {
  ServerTimeAligner({
    required this.bridge,
    required this.clock,
    this.maxRoundTrip = const Duration(seconds: 5),
    this.tolerance = const Duration(seconds: 2),
  });

  final PlatformBridge bridge;
  final Clock clock;

  /// A slow answer is too imprecise to set a clock from.
  final Duration maxRoundTrip;

  /// Smaller differences than this are left alone.
  final Duration tolerance;

  /// How far the phone was off at the last correction (phone minus server).
  Duration? lastCorrection;

  Future<void> onServerTime(DateTime serverNow, Duration roundTrip) async {
    if (roundTrip > maxRoundTrip) return;
    // The server read its clock about half a round trip ago.
    final target = serverNow.add(roundTrip ~/ 2);
    final diff = clock.now().difference(target);
    if (diff.abs() <= tolerance) return;
    await bridge.anchorClock(target.millisecondsSinceEpoch);
    final c = clock;
    if (c is SyncedClock) await c.sync();
    lastCorrection = diff;
  }
}
