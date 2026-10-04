// End-to-end: the real Flutter client code against the real server handler
// and a real local database. Skipped unless COMMIT_LOCAL_API is set, e.g.
//   COMMIT_LOCAL_API=http://127.0.0.1:8787 flutter test test/integration
// (started by backend/tests/run_client_e2e.sh). It never contacts Supabase.
import 'dart:convert';
import 'dart:io';

import 'package:app/core/installation.dart';
import 'package:app/data/api_client.dart';
import 'package:app/data/installation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../installation_test.dart' show FakePlatform;

/// Sends https://local.test/... to the local test server over loopback.
class _LoopbackTransport implements ApiTransport {
  _LoopbackTransport(this.target);
  final Uri target;
  final List<ApiRequest> requests = [];

  @override
  Future<ApiRawResponse> send(ApiRequest r) async {
    requests.add(r);
    final client = HttpClient();
    final req = await client.openUrl(
      r.method,
      target.replace(path: r.uri.path),
    );
    r.headers.forEach(req.headers.set);
    if (r.body != null) req.add(utf8.encode(r.body!));
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    final headers = <String, String>{};
    res.headers.forEach((n, v) => headers[n] = v.join(','));
    client.close();
    return ApiRawResponse(res.statusCode, body, headers);
  }
}

void main() {
  final local = Platform.environment['COMMIT_LOCAL_API'];
  final skip = local == null ? 'COMMIT_LOCAL_API is not set' : null;

  test('register, verify, reinstall, recover: same installation, new credential', () async {
    final transport = _LoopbackTransport(Uri.parse(local!));
    ApiClient api() => ApiClient(
      baseUrl: 'https://local.test/functions/v1/api',
      transport: transport,
    );
    final phone = FakePlatform(
      rawAndroidId: 'e2e${DateTime.now().microsecondsSinceEpoch}',
    );

    // A. Brand-new install.
    final first = InstallationService(platform: phone, api: api());
    await first.start();
    expect(
      first.status,
      InstallationStatus.registered,
      reason: '${first.lastErrorCode}',
    );
    final id = first.identity!.id;
    final oldCredential = first.identity!.credential;
    expect(InstallationIdentity.isId(id), isTrue);

    // B. Restart: no registration call, /me accepted.
    final sent = transport.requests.length;
    final restarted = InstallationService(platform: phone, api: api());
    expect(await restarted.ensureRegistered(), InstallationStatus.registered);
    expect(transport.requests.length, sent);
    expect(await restarted.verify(), isTrue);

    // E/F/G. Uninstall wipes encrypted storage; reinstall recovers the same ID.
    phone.store.clear();
    final reinstalled = InstallationService(platform: phone, api: api());
    await reinstalled.start();
    expect(
      reinstalled.status,
      InstallationStatus.registered,
      reason: '${reinstalled.lastErrorCode}',
    );
    expect(reinstalled.identity!.id, id);
    expect(reinstalled.identity!.credential, isNot(oldCredential));

    // H. New credential accepted, old one rejected by the real server.
    expect(await reinstalled.verify(), isTrue);
    await expectLater(
      api().send(
        'GET',
        '/v1/installations/me',
        auth: InstallationIdentity(id: id, credential: oldCredential),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'UNAUTHENTICATED'),
      ),
    );

    // Nothing sent ever contained the raw identifier or put a credential in an address.
    for (final r in transport.requests) {
      expect('${r.uri} ${r.body}', isNot(contains(phone.rawAndroidId)));
      expect(r.uri.hasQuery, isFalse);
    }
  }, skip: skip);

  test('a second phone gets its own installation and cannot use the first one\'s ID', () async {
    final transport = _LoopbackTransport(Uri.parse(local!));
    ApiClient api() => ApiClient(
      baseUrl: 'https://local.test/functions/v1/api',
      transport: transport,
    );
    final a = InstallationService(
      platform: FakePlatform(
        rawAndroidId: 'a${DateTime.now().microsecondsSinceEpoch}',
      ),
      api: api(),
    );
    final b = InstallationService(
      platform: FakePlatform(
        rawAndroidId: 'b${DateTime.now().microsecondsSinceEpoch}',
      ),
      api: api(),
    );
    await a.ensureRegistered();
    await b.ensureRegistered();
    expect(a.identity!.id, isNot(b.identity!.id));
    await expectLater(
      api().send(
        'GET',
        '/v1/installations/me',
        auth: InstallationIdentity(
          id: a.identity!.id,
          credential: b.identity!.credential,
        ),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'UNAUTHENTICATED'),
      ),
    );
  }, skip: skip);
}
