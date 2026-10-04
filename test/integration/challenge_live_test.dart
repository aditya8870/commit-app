// End-to-end, Phase 5: the real controller and HttpCommitBackend against the
// real server handler and a real local database. Skipped unless
// COMMIT_LOCAL_API is set (see backend/tests/run_client_e2e.sh). It never
// contacts Supabase.
import 'dart:convert';
import 'dart:io';

import 'package:app/core/backend.dart';
import 'package:app/core/commitment.dart';
import 'package:app/core/installation.dart';
import 'package:app/core/payment.dart';
import 'package:app/data/api_client.dart';
import 'package:app/data/commit_controller.dart';
import 'package:app/data/http_backend.dart';
import 'package:app/data/installation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes.dart';
import '../installation_test.dart' show FakePlatform;

class _Loopback implements ApiTransport {
  _Loopback(this.target);
  final Uri target;

  @override
  Future<ApiRawResponse> send(ApiRequest r) async {
    final client = HttpClient();
    final req = await client.openUrl(
      r.method,
      target.replace(
        path: r.uri.path,
        query: r.uri.hasQuery ? r.uri.query : null,
      ),
    );
    r.headers.forEach(req.headers.set);
    if (r.body != null) req.add(utf8.encode(r.body!));
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    client.close();
    return ApiRawResponse(res.statusCode, body, const {});
  }
}

class _Phone {
  _Phone(this.target, String tag)
    : platform = FakePlatform(
        rawAndroidId: '$tag${DateTime.now().microsecondsSinceEpoch}',
      );
  final Uri target;
  final FakePlatform platform;
  FakeBridge bridge = FakeBridge();
  final clock = FakeClock(DateTime.now());
  late HttpCommitBackend backend;
  late InstallationService installation;

  Future<CommitController> open() async {
    final api = ApiClient(
      baseUrl: 'https://local.test/functions/v1/api',
      transport: _Loopback(target),
      onServerTime: (t, _) async => clock.time = t,
    );
    installation = InstallationService(platform: platform, api: api);
    await installation.start();
    expect(installation.status, InstallationStatus.registered);
    backend = HttpCommitBackend(api: api, installation: installation);
    final app = await boot(bridge, clock, backend: backend);
    await app.syncWithBackend();
    return app;
  }
}

void main() {
  final local = Platform.environment['COMMIT_LOCAL_API'];
  final skip = local == null ? 'COMMIT_LOCAL_API is not set' : null;

  test('create, emergency, events, refusals, reinstall restore', () async {
    final phone = _Phone(Uri.parse(local!), 'p5a');
    final app = await phone.open();
    expect(app.active, isNull);

    // Create: the server's clock sets start and end.
    await app.startInstagram(minutes: 60, amount: 500, emergencyLimit: 1);
    final c = app.active!;
    expect(c.serverIssued, isTrue);
    expect(c.endTime.difference(c.startTime), const Duration(minutes: 60));
    expect(
      c.startTime.difference(DateTime.now()).inSeconds.abs(),
      lessThan(30),
    );
    final server = await phone.backend.currentChallenge();
    expect(server!.terms.challengeId, c.id);
    expect(server.details!.apps.single.packageName, instagram);

    // A second challenge is refused by the real database rule.
    await expectLater(
      phone.backend.registerChallenge(
        sampleRequest(phone.clock),
        idempotencyKey: IdempotencyKey.generate(),
      ),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'ACTIVE_CHALLENGE_EXISTS',
        ),
      ),
    );

    // Emergency access, reported twice, counted once.
    await app.startEmergency();
    final queued = [...app.outbox];
    await phone.backend.reportEvents(queued);
    await app.flushOutbox();
    expect(app.outbox, isEmpty);
    expect(
      (await phone.backend.fetchChallenge(c.id))!.details!.emergencyUsed,
      1,
    );

    // Observations and an early "complete" request.
    await phone.backend.reportEvents([
      for (final t in [
        IntegrityEvent.forceStopped,
        ChallengeEvent.clockJump,
        ChallengeEvent.completedOnDevice,
      ])
        ChallengeEvent(
          eventId: IdempotencyKey.generate(),
          challengeId: c.id,
          type: t,
          at: phone.clock.time,
        ),
    ]);
    expect(
      (await phone.backend.fetchChallenge(c.id))!.status,
      ServerChallengeStatus.active,
      reason: 'the phone cannot complete a challenge early',
    );

    // Ending early is refused: there is no payment system.
    final d = await phone.backend.authorizePaymentAttempt(
      c.id,
      idempotencyKey: IdempotencyKey.generate(),
    );
    expect(d.allowed, isFalse);
    expect(d.current!.status, PaymentStatus.notStarted);
    expect(
      (await phone.backend.fetchChallenge(c.id))!.status,
      ServerChallengeStatus.active,
    );

    // A finished-challenge list exists and is empty.
    expect((await phone.backend.fetchHistory(limit: 5)).items, isEmpty);

    // Another phone sees nothing of it.
    final other = _Phone(Uri.parse(local), 'p5b');
    final otherApp = await other.open();
    expect(otherApp.active, isNull);
    expect(await other.backend.fetchChallenge(c.id), isNull);

    // Reinstall: everything on the phone is gone; the challenge comes back.
    phone.bridge = FakeBridge();
    phone.platform.store.clear();
    final again = await phone.open();
    expect(again.active!.id, c.id);
    expect(again.active!.endTime, c.endTime);
    expect(again.active!.emergencyAccessCount, 1);
    expect(again.active!.status, CommitmentStatus.active);
    // A background sync may still be sending; wait for it, then flush.
    for (var i = 0; i < 50 && again.outbox.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await again.flushOutbox();
    }
    expect(again.outbox, isEmpty, reason: 'the restore was reported');
  }, skip: skip);
}
