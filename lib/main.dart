import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/clock.dart';
import 'data/api_client.dart';
import 'data/commit_controller.dart';
import 'data/http_backend.dart';
import 'data/installation_service.dart';
import 'data/server_time.dart';
import 'platform/installation_platform.dart';
import 'platform/platform_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final bridge = MethodChannelBridge();
  final clock = SyncedClock(bridge.trustedNowMillis);

  // One client for every request. Whenever the server answers, its clock
  // corrects the phone's trusted clock.
  final aligner = ServerTimeAligner(bridge: bridge, clock: clock);
  final api = ApiClient(
    baseUrl: commitApiBase,
    transport: HttpApiTransport(),
    onServerTime: aligner.onServerTime,
  );

  // Anonymous installation identity. Runs in the background: nothing waits
  // for it and blocking works the same with no network.
  final installation = InstallationService(
    platform: MethodChannelInstallationPlatform(),
    api: api,
  );

  final controller = CommitController(
    bridge: bridge,
    clock: clock,
    // The server decides challenge IDs, times and lifecycle. The phone keeps
    // a copy and keeps blocking from it when the server is unreachable.
    backend: HttpCommitBackend(api: api, installation: installation),
  );
  unawaited(controller.load());
  controller.startTicker();
  unawaited(installation.start());

  runApp(CommitApp(controller: controller, onResumed: installation.start));
}
