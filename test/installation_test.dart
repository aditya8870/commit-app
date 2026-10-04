import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/app.dart';
import 'package:app/core/installation.dart';
import 'package:app/data/api_client.dart';
import 'package:app/data/installation_service.dart';
import 'package:app/platform/installation_platform.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _base = 'https://api.example.test/functions/v1/api';

/// Stands in for Android. The raw Android ID exists only in here, exactly as
/// on a real phone it exists only in native code.
class FakePlatform implements InstallationPlatform {
  FakePlatform({this._rawAndroidId = '3f9a1c0b7e5d2468'});

  final String _rawAndroidId;
  final Map<String, String> store = {};
  bool hasAndroidId = true;
  bool failRead = false;
  bool failWrite = false;
  int writes = 0;

  String get rawAndroidId => _rawAndroidId;

  /// A stand-in for the native SHA-256: 64 hex characters that depend on the
  /// ID but do not contain it.
  String get material {
    var h = 0x811c9dc5;
    final out = StringBuffer();
    for (var round = 0; round < 8; round++) {
      for (final c in 'commit-recovery-v1:$_rawAndroidId#$round'.codeUnits) {
        h = ((h ^ c) * 0x01000193) & 0xffffffff;
      }
      out.write(h.toRadixString(16).padLeft(8, '0'));
    }
    return out.toString();
  }

  @override
  Future<String?> secureRead(String name) async {
    if (failRead) throw Exception('keystore unavailable');
    return store[name];
  }

  @override
  Future<void> secureWrite(String name, String value) async {
    if (failWrite) throw Exception('keystore unavailable');
    writes++;
    store[name] = value;
  }

  @override
  Future<void> secureDelete(String name) async => store.remove(name);

  @override
  Future<String?> recoveryMaterial() async => hasAndroidId ? material : null;

  @override
  Future<String> appVersion() async => '2.7.0';

  @override
  Future<String?> androidVersion() async => '14';
}

/// A stand-in server that follows the Phase 3 API contract and records every
/// request it receives.
class FakeServer implements ApiTransport {
  final List<ApiRequest> requests = [];
  final List<Map<String, String?>> installations =
      []; // id, credential, material
  int _nextId = 1;

  /// Overrides for failure tests.
  bool offline = false;
  bool hang = false;
  ApiRawResponse? Function(ApiRequest)? intercept;
  Duration delay = Duration.zero;
  bool recoveryUpToDate = true;

  String get all => requests
      .map((r) => '${r.method} ${r.uri} ${r.headers} ${r.body ?? ''}')
      .join('\n');
  int count(String method, String pathEnd) => requests
      .where((r) => r.method == method && r.uri.path.endsWith(pathEnd))
      .length;

  static ApiRawResponse _json(
    int status,
    Map<String, Object?> body, [
    Map<String, String> h = const {},
  ]) => ApiRawResponse(
    status,
    jsonEncode({
      ...body,
      'serverTime': '2026-10-05T10:00:00.000Z',
      'epochMs': 1,
    }),
    h,
  );
  static ApiRawResponse _error(
    int status,
    String code, {
    bool retryable = false,
    Map<String, String> h = const {},
  }) =>
      _json(status, {'code': code, 'message': 'x', 'retryable': retryable}, h);

  String _id() =>
      '00000000-0000-4000-8000-${(_nextId++).toString().padLeft(12, '0')}';

  @override
  Future<ApiRawResponse> send(ApiRequest r) async {
    requests.add(r);
    if (hang) return Completer<ApiRawResponse>().future;
    if (offline) throw const SocketException('no route to host');
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final forced = intercept?.call(r);
    if (forced != null) return forced;

    final path = r.uri.path.replaceFirst('/functions/v1/api', '');
    final body = r.body == null
        ? <String, Object?>{}
        : (jsonDecode(r.body!) as Map).cast<String, Object?>();

    if (r.method == 'POST' && path == '/v1/installations') {
      final cred = body['credential'], material = body['recoveryMaterial'];
      if (!InstallationIdentity.isCredential(cred)) {
        return _error(422, 'VALIDATION_FAILED');
      }
      final same = installations.where((i) => i['credential'] == cred);
      if (same.isNotEmpty) {
        return _json(200, {'installationId': same.first['id']});
      }
      if (material != null &&
          installations.any((i) => i['material'] == material)) {
        return _error(409, 'RECOVERY_REQUIRED');
      }
      final id = _id();
      installations.add({
        'id': id,
        'credential': cred as String,
        'material': material as String?,
      });
      return _json(201, {'installationId': id});
    }
    if (r.method == 'POST' && path == '/v1/installations/recover') {
      final cred = body['credential'], material = body['recoveryMaterial'];
      final found = installations.where(
        (i) => i['material'] != null && i['material'] == material,
      );
      if (found.isEmpty) return _error(404, 'RECOVERY_NOT_FOUND');
      found.first['credential'] = cred as String;
      return _json(200, {
        'installationId': found.first['id'],
        'recoveryCount': 1,
        'hasActiveChallenge': false,
      });
    }
    final auth = r.headers['authorization'] ?? '';
    final who = installations.where(
      (i) =>
          'Bearer ${i['credential']}' == auth &&
          i['id'] == r.headers['x-installation-id'],
    );
    if (r.method == 'GET' && path == '/v1/installations/me') {
      if (who.isEmpty) return _error(401, 'UNAUTHENTICATED');
      return _json(200, {
        'installationId': who.first['id'],
        'status': 'active',
        'recoveryCount': 0,
        'recoveryUpToDate': recoveryUpToDate,
      });
    }
    if (r.method == 'POST' && path == '/v1/installations/me/recovery') {
      if (who.isEmpty) return _error(401, 'UNAUTHENTICATED');
      recoveryUpToDate = true;
      return _json(200, {'recoveryUpToDate': true, 'changed': true});
    }
    return _error(404, 'NOT_FOUND');
  }
}

void main() {
  late FakePlatform phone;
  late FakeServer server;
  late DateTime now;

  InstallationService service([
    FakePlatform? p,
    Duration timeout = const Duration(seconds: 2),
  ]) => InstallationService(
    platform: p ?? phone,
    api: ApiClient(baseUrl: _base, transport: server, timeout: timeout),
    now: () => now,
  );

  setUp(() {
    phone = FakePlatform();
    server = FakeServer();
    now = DateTime.utc(2026, 10, 5, 10);
  });

  group('credential', () {
    test(
      'first launch generates a 256-bit credential in the required format',
      () async {
        await service().ensureRegistered();
        final credential = phone.store[InstallationService.kCredential]!;
        expect(InstallationIdentity.isCredential(credential), isTrue);
        expect(
          base64Url.decode('$credential=').length,
          32,
          reason: '32 bytes = 256 bits',
        );
      },
    );

    test('every install gets a different credential', () async {
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        final p = FakePlatform(rawAndroidId: 'id$i')..hasAndroidId = false;
        await service(p).ensureRegistered();
        seen.add(p.store[InstallationService.kCredential]!);
      }
      expect(seen.length, 50);
    });

    test('the default random source is the cryptographic one', () {
      final src = File('lib/data/installation_service.dart').readAsStringSync();
      expect(src, contains('random ?? Random.secure()'));
      expect(
        RegExp(r'Random\((?!\.)')
            .hasMatch(src.replaceAll('Random.secure()', '')),
        isFalse,
        reason: 'no predictable Random() anywhere',
      );
    });

    test('a credential is never hard-coded: none appears in the source', () {
      for (final f in Directory(
        'lib',
      ).listSync(recursive: true).whereType<File>()) {
        final text = f.readAsStringSync();
        expect(
          RegExp(r'''['"][A-Za-z0-9_-]{43}['"]''').hasMatch(text),
          isFalse,
          reason: f.path,
        );
      }
    });
  });

  group('secure storage', () {
    test(
      'credential and ID are written to encrypted storage and read back',
      () async {
        final first = service();
        expect(await first.ensureRegistered(), InstallationStatus.registered);
        expect(phone.store.keys.toSet(), {
          InstallationService.kId,
          InstallationService.kCredential,
        });
        expect(
          InstallationIdentity.isId(phone.store[InstallationService.kId]),
          isTrue,
        );

        final afterRestart = service();
        expect(
          await afterRestart.ensureRegistered(),
          InstallationStatus.registered,
        );
        expect(afterRestart.identity!.id, first.identity!.id);
        expect(afterRestart.identity!.credential, first.identity!.credential);
      },
    );

    test('only the secure-storage channel is used: nothing goes to ordinary app storage', () {
      final service = File('lib/data/installation_service.dart')
          .readAsStringSync();
      expect(service, isNot(contains('saveState')));
      expect(service, isNot(contains('SharedPreferences')));
      expect(service, isNot(contains('File(')));
      final controller = File('lib/data/commit_controller.dart')
          .readAsStringSync();
      expect(controller, isNot(contains('installation_credential')));
    });

    test(
      'if encrypted storage cannot be read, nothing is registered',
      () async {
        phone.failRead = true;
        final s = service();
        expect(await s.ensureRegistered(), InstallationStatus.unknown);
        expect(server.requests, isEmpty);
        expect(s.lastErrorCode, 'STORAGE');
      },
    );

    test(
      'if encrypted storage cannot be written, no request is sent',
      () async {
        phone.failWrite = true;
        expect(
          await service().ensureRegistered(),
          InstallationStatus.unregistered,
        );
        expect(
          server.requests,
          isEmpty,
          reason: 'a credential that cannot be kept is never registered',
        );
      },
    );
  });

  group('registration', () {
    test('success: one request, server-issued ID stored', () async {
      final s = service();
      expect(await s.ensureRegistered(), InstallationStatus.registered);
      expect(server.count('POST', '/v1/installations'), 1);
      expect(s.identity!.id, server.installations.single['id']);
      final sent = jsonDecode(server.requests.single.body!) as Map;
      expect(sent.keys.toSet(), {
        'credential',
        'recoveryMaterial',
        'appVersion',
        'androidVersion',
      });
      expect(
        sent.containsKey('installationId'),
        isFalse,
        reason: 'the phone never proposes an ID',
      );
      expect(sent['appVersion'], '2.7.0');
    });

    test('idempotent: later starts send nothing and create nothing', () async {
      await service().ensureRegistered();
      for (var i = 0; i < 5; i++) {
        await service().ensureRegistered();
      }
      expect(server.count('POST', '/v1/installations'), 1);
      expect(server.installations.length, 1);
    });

    test('crash after the server answered but before saving: the same credential is re-sent', () async {
      // First attempt: the server registers, then the app "dies" before saving.
      server.intercept = (r) => null;
      final s1 = service();
      phone.failWrite = false;
      await s1.ensureRegistered();
      final pendingCredential = phone.store[InstallationService.kCredential]!;
      // Simulate the crash: only the pending credential survived.
      phone.store
        ..clear()
        ..[InstallationService.kPending] = pendingCredential;

      final s2 = service();
      expect(await s2.ensureRegistered(), InstallationStatus.registered);
      expect(server.installations.length, 1, reason: 'no second installation');
      expect(s2.identity!.credential, pendingCredential);
      expect(phone.store.containsKey(InstallationService.kPending), isFalse);
    });

    test('concurrent startup: many callers share one registration', () async {
      server.delay = const Duration(milliseconds: 30);
      final s = service();
      final results = await Future.wait([
        for (var i = 0; i < 10; i++) s.ensureRegistered(),
        s.start(),
        s.start(),
      ]);
      expect(results.whereType<InstallationStatus>().toSet(), {
        InstallationStatus.registered,
      });
      expect(server.count('POST', '/v1/installations'), 1);
      expect(server.installations.length, 1);
    });

    test(
      'a phone with no Android ID still registers, without recovery data',
      () async {
        phone.hasAndroidId = false;
        await service().ensureRegistered();
        final sent = jsonDecode(server.requests.single.body!) as Map;
        expect(sent['recoveryMaterial'], isNull);
      },
    );
  });

  group('reinstall recovery', () {
    Future<InstallationService> installAndReinstall() async {
      final before = service();
      await before.ensureRegistered();
      phone.store.clear(); // uninstall wipes encrypted storage and its key
      return before;
    }

    test('recovery required leads to recovery, not a duplicate', () async {
      final before = await installAndReinstall();
      final after = service();
      expect(await after.ensureRegistered(), InstallationStatus.registered);
      expect(server.count('POST', '/v1/installations/recover'), 1);
      expect(
        server.installations.length,
        1,
        reason: 'no duplicate installation',
      );
      expect(
        after.identity!.id,
        before.identity!.id,
        reason: 'same installation ID',
      );
    });

    test('recovery replaces the credential: the new one is stored and works, the old one does not', () async {
      final before = await installAndReinstall();
      final after = service();
      await after.ensureRegistered();
      expect(after.identity!.credential, isNot(before.identity!.credential));
      expect(
        phone.store[InstallationService.kCredential],
        after.identity!.credential,
      );
      expect(await after.verify(), isTrue);

      // The old credential is rejected by the server.
      final api = ApiClient(baseUrl: _base, transport: server);
      await expectLater(
        api.send('GET', '/v1/installations/me', auth: before.identity),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'UNAUTHENTICATED'),
        ),
      );
    });

    test('recovery does not touch challenge data on the phone', () async {
      final bridge = FakeBridge();
      final clock = FakeClock();
      final controller = await boot(bridge, clock);
      await controller.completeOnboarding();
      await controller.startInstagram();
      final saved = bridge.disk;

      await installAndReinstall();
      await service().ensureRegistered();

      expect(bridge.disk, saved, reason: 'the app state was not rewritten');
      expect(controller.active, isNotNull);
    });

    test('a stored credential the server no longer accepts triggers recovery, once', () async {
      final s = service();
      await s.ensureRegistered();
      final id = s.identity!.id;
      // Someone else recovered this installation: our credential is dead.
      server.installations.single['credential'] = 'x' * 43;

      expect(await s.verify(), isFalse);
      expect(
        s.status,
        InstallationStatus.registered,
        reason: 'recovered straight away',
      );
      expect(s.identity!.id, id);
      expect(server.installations.length, 1);
      expect(await s.verify(), isTrue);
    });
  });

  group('authenticated requests', () {
    test(
      'GET /v1/installations/me succeeds with the stored identity',
      () async {
        final s = service();
        await s.ensureRegistered();
        expect(await s.verify(), isTrue);
        final me = server.requests.last;
        expect(me.method, 'GET');
        expect(me.headers['authorization'], 'Bearer ${s.identity!.credential}');
        expect(me.headers['x-installation-id'], s.identity!.id);
        expect(me.body, isNull);
      },
    );

    test(
      'an unauthenticated request is rejected and surfaces a safe error',
      () async {
        final api = ApiClient(baseUrl: _base, transport: server);
        await expectLater(
          api.send('GET', '/v1/installations/me'),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', 'UNAUTHENTICATED')
                .having((e) => e.status, 'status', 401),
          ),
        );
      },
    );

    test('the credential is only ever in a header: never in an address or a body after registration', () async {
      final s = service();
      await s.start();
      final credential = s.identity!.credential;
      for (final r in server.requests) {
        expect(r.uri.toString(), isNot(contains(credential)));
        expect(r.uri.hasQuery, isFalse);
        expect(r.uri.scheme, 'https');
        if (r.uri.path.endsWith('/me')) {
          expect(r.body ?? '', isNot(contains(credential)));
        }
      }
    });

    test('paths cannot smuggle a query string', () {
      final api = ApiClient(baseUrl: _base, transport: server);
      expect(
        () => api.send('GET', '/v1/installations/me?credential=x'),
        throwsArgumentError,
      );
      expect(() => api.send('GET', 'v1/time'), throwsArgumentError);
    });

    test(
      'an out-of-date recovery key is refreshed in the background',
      () async {
        server.recoveryUpToDate = false;
        final s = service();
        await s.start();
        expect(server.count('POST', '/v1/installations/me/recovery'), 1);
        final sent = jsonDecode(server.requests.last.body!) as Map;
        expect(sent, {'recoveryMaterial': phone.material});
      },
    );
  });

  group('transport security', () {
    test('a non-HTTPS address is refused outright', () {
      for (final bad in [
        'http://api.example.test',
        'ftp://x',
        'api.example.test',
        'https://x.test/?a=1',
      ]) {
        expect(
          () => ApiClient(baseUrl: bad, transport: server),
          throwsArgumentError,
          reason: bad,
        );
      }
      expect(Uri.parse(commitApiBase).scheme, 'https');
    });

    test('the real transport refuses a non-HTTPS request and has no certificate override', () async {
      await expectLater(
        HttpApiTransport().send(
          ApiRequest(
            method: 'GET',
            uri: Uri.parse('http://example.test/'),
            headers: const {},
          ),
        ),
        throwsA(isA<ApiException>()),
      );
      final src = File('lib/data/api_client.dart').readAsStringSync();
      expect(src, isNot(contains('badCertificateCallback')));
      expect(src, contains('followRedirects = false'));
    });

    test('Android allows no cleartext traffic', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest, contains('android:usesCleartextTraffic="false"'));
      expect(manifest, contains('android:allowBackup="false"'));
    });
  });

  group('failures', () {
    test('network timeout: stays unregistered, keeps the pending credential, retries later', () async {
      server.hang = true;
      final s = service(null, const Duration(milliseconds: 40));
      expect(await s.ensureRegistered(), InstallationStatus.unregistered);
      expect(s.lastErrorCode, 'TIMEOUT');
      final pending = phone.store[InstallationService.kPending];
      expect(pending, isNotNull);

      // Too soon: no new request.
      final sent = server.requests.length;
      await s.ensureRegistered();
      expect(server.requests.length, sent);

      // Later, with the network back: the SAME credential is used.
      server.hang = false;
      now = now.add(const Duration(seconds: 61));
      expect(await s.ensureRegistered(), InstallationStatus.registered);
      expect(s.identity!.credential, pending);
      expect(server.installations.length, 1);
    });

    test(
      'offline on first launch: no crash, registers when the network returns',
      () async {
        server.offline = true;
        final s = service();
        await s.start();
        expect(s.status, InstallationStatus.unregistered);
        expect(s.lastErrorCode, 'NETWORK');
        server.offline = false;
        now = now.add(const Duration(minutes: 2));
        await s.start();
        expect(s.status, InstallationStatus.registered);
      },
    );

    test('offline startup after registration: identity is available with no network', () async {
      await service().ensureRegistered();
      server
        ..offline = true
        ..requests.clear();
      final s = service();
      expect(await s.ensureRegistered(), InstallationStatus.registered);
      expect(
        server.requests,
        isEmpty,
        reason: 'registration is local once stored',
      );
      await s.start(); // the background check fails quietly
      expect(s.status, InstallationStatus.registered);
      expect(s.identity, isNotNull);
      expect(phone.store.keys.toSet(), {
        InstallationService.kId,
        InstallationService.kCredential,
      });
    });

    test('server errors (500, misconfigured) are retried later without creating anything', () async {
      for (final code in ['SERVER_ERROR', 'SERVER_MISCONFIGURED']) {
        server = FakeServer()
          ..intercept = (_) => FakeServer._error(500, code, retryable: true);
        phone = FakePlatform();
        final s = service();
        expect(await s.ensureRegistered(), InstallationStatus.unregistered);
        expect(s.lastErrorCode, code);
        expect(server.installations, isEmpty);
        server.intercept = null;
        now = now.add(const Duration(seconds: 61));
        expect(await s.ensureRegistered(), InstallationStatus.registered);
      }
    });

    test('rate limit: waits as long as the server asks', () async {
      server.intercept = (_) => FakeServer._error(
        429,
        'RATE_LIMITED',
        retryable: true,
        h: {'retry-after': '600'},
      );
      final s = service();
      expect(await s.ensureRegistered(), InstallationStatus.unregistered);
      expect(s.lastErrorCode, 'RATE_LIMITED');
      server.intercept = null;
      final sent = server.requests.length;

      now = now.add(const Duration(seconds: 599));
      await s.ensureRegistered();
      expect(server.requests.length, sent, reason: 'still waiting');

      now = now.add(const Duration(seconds: 2));
      expect(await s.ensureRegistered(), InstallationStatus.registered);
    });

    test(
      'a refused request (validation) backs off for longer and does not loop',
      () async {
        server.intercept = (_) => FakeServer._error(422, 'VALIDATION_FAILED');
        final s = service();
        await s.ensureRegistered();
        final sent = server.requests.length;
        now = now.add(const Duration(minutes: 5));
        await s.ensureRegistered();
        expect(server.requests.length, sent);
        now = now.add(const Duration(minutes: 11));
        await s.ensureRegistered();
        expect(server.requests.length, sent + 1);
      },
    );

    test('malformed responses are rejected, never stored', () async {
      final bad = <ApiRawResponse>[
        const ApiRawResponse(200, 'not json'),
        const ApiRawResponse(200, '[]'),
        const ApiRawResponse(201, '{}'),
        const ApiRawResponse(201, '{"installationId": 42}'),
        const ApiRawResponse(201, '{"installationId": "not-a-uuid"}'),
        const ApiRawResponse(201, '{"installationId": "../../etc/passwd"}'),
        const ApiRawResponse(200, ''),
        const ApiRawResponse(302, '<html>redirect</html>', {
          'location': 'https://evil.test/',
        }),
      ];
      for (final response in bad) {
        server = FakeServer()..intercept = (_) => response;
        phone = FakePlatform();
        final s = service();
        expect(
          await s.ensureRegistered(),
          InstallationStatus.unregistered,
          reason: response.body,
        );
        expect(
          phone.store.containsKey(InstallationService.kId),
          isFalse,
          reason: response.body,
        );
        expect(
          phone.store.containsKey(InstallationService.kCredential),
          isFalse,
        );
      }
    });

    test('an error body that is not JSON still gives a safe code', () async {
      server.intercept = (_) =>
          const ApiRawResponse(502, '<html>Bad gateway</html>');
      final api = ApiClient(baseUrl: _base, transport: server);
      await expectLater(
        api.send('GET', '/v1/time'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'HTTP_502')
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });
  });

  group('privacy and secrets', () {
    test('the raw Android ID is never transmitted', () async {
      final s = service();
      await s.start();
      phone.store.clear();
      await service().start(); // includes a recovery
      expect(server.requests.length, greaterThanOrEqualTo(4));
      expect(server.all, isNot(contains(phone.rawAndroidId)));
      // What is sent is the 64-character hash and nothing else about the device.
      final sent = jsonDecode(server.requests.first.body!) as Map;
      expect(sent['recoveryMaterial'], phone.material);
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(sent['recoveryMaterial'] as String),
        isTrue,
      );
    });

    test('a value that is not a hash is never sent as recovery data', () async {
      final leaky = _LeakyPlatform();
      await service(leaky).ensureRegistered();
      final sent = jsonDecode(server.requests.single.body!) as Map;
      expect(sent['recoveryMaterial'], isNull);
      expect(server.all, isNot(contains('9774d56d682e549c')));
    });

    test(
      'Dart has no way to read the raw Android ID; only native code touches it',
      () {
        final iface = File('lib/platform/installation_platform.dart')
            .readAsStringSync();
        expect(
          RegExp(r'Future<[^>]+>\s+(\w+)\(')
              .allMatches(iface)
              .map((m) => m.group(1))
              .toSet(),
          {
            'secureRead',
            'secureWrite',
            'secureDelete',
            'recoveryMaterial',
            'appVersion',
            'androidVersion',
          },
        );
        final kotlin = Directory('android/app/src/main/kotlin')
            .listSync(recursive: true)
            .whereType<File>();
        final users = kotlin
            .where(
              (f) =>
                  f.readAsStringSync().contains('Settings.Secure.ANDROID_ID'),
            )
            .map((f) => f.uri.pathSegments.last);
        expect(users.toList(), ['InstallationSupport.kt']);
        final support = File(
          'android/app/src/main/kotlin/com/commit/app/InstallationSupport.kt',
        ).readAsStringSync();
        expect(support, isNot(contains('Log.')));
        expect(support, contains('"commit-recovery-v1:"'));
      },
    );

    test(
      'nothing sensitive is printed or logged, in success or failure',
      () async {
        final printed = <String>[];
        final oldDebugPrint = debugPrint;
        debugPrint = (String? m, {int? wrapWidth}) => printed.add(m ?? '');
        late String credential;
        await runZoned(
          () async {
            final s = service();
            await s.start();
            credential = s.identity!.credential;
            server.installations.single['credential'] = 'y' * 43;
            await s.verify(); // rejected, then recovered
            server.offline = true;
            await s.verify();
            server
              ..offline = false
              ..intercept = (_) => const ApiRawResponse(500, 'boom');
            await s.verify();
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) => printed.add(line),
          ),
        );
        debugPrint = oldDebugPrint;
        expect(printed, isEmpty, reason: 'the identity code never prints');
        expect(credential.length, 43);
      },
    );

    test(
      'errors and identity never reveal the credential when printed',
      () async {
        final s = service();
        await s.ensureRegistered();
        final credential = s.identity!.credential;
        expect(s.identity.toString(), isNot(contains(credential)));
        server.installations.single['credential'] = 'z' * 43;
        Object? caught;
        try {
          await ApiClient(
            baseUrl: _base,
            transport: server,
          ).send('GET', '/v1/installations/me', auth: s.identity);
        } catch (e) {
          caught = e;
        }
        expect('$caught', 'ApiException(UNAUTHENTICATED, 401)');
        expect('$caught', isNot(contains(credential)));
      },
    );

    test('the identity code contains no print, log or debug output', () {
      for (final path in [
        'lib/core/installation.dart',
        'lib/data/api_client.dart',
        'lib/data/installation_service.dart',
        'lib/platform/installation_platform.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(
          RegExp(r'\b(print|debugPrint|log)\(').hasMatch(src),
          isFalse,
          reason: path,
        );
      }
    });

    test('no secrets in the app source', () {
      final files = [
        ...Directory('lib').listSync(recursive: true).whereType<File>(),
        ...Directory('android/app/src/main')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => RegExp(r'\.(kt|xml|kts)$').hasMatch(f.path)),
        File('pubspec.yaml'),
      ];
      expect(files.length, greaterThan(20));
      for (final f in files) {
        final text = f.readAsStringSync();
        expect(
          RegExp(r'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}').hasMatch(text),
          isFalse,
          reason: '${f.path}: key',
        );
        expect(
          text.contains('service_role') || text.contains('SERVICE_ROLE'),
          isFalse,
          reason: f.path,
        );
        expect(
          text.contains('COMMIT_RECOVERY_SECRET'),
          isFalse,
          reason: f.path,
        );
        expect(
          RegExp(r'sb_(secret|publishable)_').hasMatch(text),
          isFalse,
          reason: f.path,
        );
      }
    });

    test(
      'no new personal data: no name, email, phone, location or advertising ID',
      () {
        final manifest = File('android/app/src/main/AndroidManifest.xml')
            .readAsStringSync();
        for (final p in [
          'ACCESS_FINE_LOCATION',
          'ACCESS_COARSE_LOCATION',
          'READ_CONTACTS',
          'READ_PHONE_STATE',
          'AD_ID',
          'GET_ACCOUNTS',
        ]) {
          expect(manifest, isNot(contains(p)));
        }
        final service = File('lib/data/installation_service.dart')
            .readAsStringSync();
        expect(RegExp(r"'(email|phone|name)'").hasMatch(service), isFalse);
        final pubspec = File('pubspec.yaml').readAsStringSync();
        expect(
          RegExp(
            r'^\s+(google_sign_in|supabase\w*|firebase\w*|http|dio)\s*:',
            multiLine: true,
          ).hasMatch(pubspec),
          isFalse,
          reason: 'no sign-in, analytics or networking packages were added',
        );
      },
    );
  });

  group('existing behaviour', () {
    testWidgets(
      'the app starts and works while identity is offline and never finishes',
      (tester) async {
        final bridge = FakeBridge();
        final clock = FakeClock();
        final controller = await boot(bridge, clock);
        await controller.completeOnboarding();
        await controller.startInstagram();
        var resumes = 0;
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 2.5;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          CommitApp(
            controller: controller,
            onResumed: () {
              resumes++;
              return Completer<void>().future; // identity hangs forever
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text("You're doing great."), findsOneWidget);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(resumes, 1);
        expect(controller.active, isNotNull);
        expect(find.text('Continue challenge'), findsOneWidget);
      },
    );

    test(
      'the challenge controller knows nothing about the installation service',
      () {
        final controller = File('lib/data/commit_controller.dart')
            .readAsStringSync();
        expect(controller, isNot(contains('installation_service')));
        expect(controller, isNot(contains('api_client')));
      },
    );
  });
}

/// A platform that (wrongly) hands back a raw identifier.
class _LeakyPlatform extends FakePlatform {
  @override
  Future<String?> recoveryMaterial() async => '9774d56d682e549c';
}
