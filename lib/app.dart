import 'dart:async';

import 'package:flutter/material.dart';

import 'core/commitment.dart';
import 'core/commitment_engine.dart';
import 'data/commit_controller.dart';
import 'ui/screens/commitment_screens.dart';
import 'ui/screens/end_challenge.dart';
import 'ui/screens/welcome_home.dart';
import 'ui/widgets.dart';

class CommitApp extends StatefulWidget {
  const CommitApp({super.key, required this.controller, this.onResumed});
  final CommitController controller;

  /// Called whenever the app comes to the front (background housekeeping
  /// that the UI does not wait for).
  final Future<void> Function()? onResumed;

  @override
  State<CommitApp> createState() => _CommitAppState();
}

class _CommitAppState extends State<CommitApp> with WidgetsBindingObserver {
  final _navKey = GlobalKey<NavigatorState>();
  String? _shownCompletionId;

  CommitController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c.addListener(_onChanged);
    _c.bridge.setLaunchActionHandler(_onLaunchAction);
    unawaited(_checkLaunchAction());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_onChanged);
    _c.bridge.setLaunchActionHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_c.onResume());
      final extra = widget.onResumed;
      if (extra != null) unawaited(extra());
    }
  }

  /// When a commitment completes, return to the root, which then shows the
  /// completion screen instead of Home.
  void _onChanged() {
    final id = _c.pendingCompletion?.id;
    if (id != null && id != _shownCompletionId) {
      _navKey.currentState?.popUntil((r) => r.isFirst);
    }
    _shownCompletionId = id;
  }

  /// Cold start: was the app opened by the blocking service?
  Future<void> _checkLaunchAction() async {
    try {
      final action = await _c.bridge.consumeLaunchAction();
      if (action != null) await _showBlocked();
    } catch (_) {}
  }

  /// Warm start: the blocking service brought the app to the front.
  void _onLaunchAction(String action) {
    unawaited(() async {
      try {
        await _c.bridge.consumeLaunchAction();
      } catch (_) {}
      await _showBlocked();
    }());
  }

  Future<void> _showBlocked() async {
    while (!_c.loaded) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await _c.onResume();
    final nav = _navKey.currentState;
    final a = _c.active;
    if (nav == null || a == null || !CommitmentEngine.isBlocking(a, _c.now)) {
      return; // completed meanwhile, or emergency access is running
    }
    final relocked = _c.relockNotice;
    _c.dismissRelockNotice();
    nav.popUntil((r) => r.isFirst);
    unawaited(
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => BlockedScreen(relocked: relocked),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CommitScope(
      controller: _c,
      child: MaterialApp(
        title: 'Commit',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navKey,
        theme: buildTheme(),
        home: const RootGate(),
      ),
    );
  }
}

/// Decides what the bottom-most screen is.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final c = CommitScope.of(context);
    if (!c.loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!c.onboarded) return const WelcomeScreen();
    final done = c.pendingCompletion;
    if (done != null) {
      return done.status == CommitmentStatus.endedEarly
          ? EndedEarlyScreen(commitment: done)
          : CompletedScreen(commitment: done);
    }
    return const HomeScreen();
  }
}
