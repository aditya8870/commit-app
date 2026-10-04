/// Source of "now". Injected so logic can be tested with a fake clock.
abstract class Clock {
  DateTime now();
}

class SystemClock implements Clock {
  const SystemClock();
  @override
  DateTime now() => DateTime.now();
}

/// Follows the native tamper-resistant clock (see TrustedClock in Kotlin).
/// Between syncs it advances with a monotonic stopwatch, so changing the
/// phone's date/time while the app is open has no effect.
class SyncedClock implements Clock {
  SyncedClock(this._fetchTrustedMillis);

  final Future<int> Function() _fetchTrustedMillis;
  final Stopwatch _sinceSync = Stopwatch();
  int? _baseMillis;

  Future<void> sync() async {
    try {
      _baseMillis = await _fetchTrustedMillis();
      _sinceSync
        ..reset()
        ..start();
    } catch (_) {
      // Keep the previous base; falls back to the system clock if never synced.
    }
  }

  @override
  DateTime now() {
    final base = _baseMillis;
    if (base == null) return DateTime.now();
    return DateTime.fromMillisecondsSinceEpoch(
      base + _sinceSync.elapsedMilliseconds,
    );
  }
}
