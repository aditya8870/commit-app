import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/installation.dart';

/// Address of the Commit API. The development server by default; a release
/// build for another server passes --dart-define=COMMIT_API_BASE=...
/// This is a public address, not a secret.
const commitApiBase = String.fromEnvironment(
  'COMMIT_API_BASE',
  defaultValue: 'https://sgnmsjduvffrxkjieyfy.supabase.co/functions/v1/api',
);

class ApiRequest {
  const ApiRequest({
    required this.method,
    required this.uri,
    required this.headers,
    this.body,
  });
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;
}

class ApiRawResponse {
  const ApiRawResponse(this.status, this.body, [this.headers = const {}]);
  final int status;
  final String body;

  /// Header names in lower case.
  final Map<String, String> headers;
}

/// Sends one request over the network. Replaced by a fake in tests.
abstract class ApiTransport {
  Future<ApiRawResponse> send(ApiRequest request);
}

/// Real transport. Uses the platform's own certificate checks: there is no
/// override, so a wrong or untrusted certificate simply fails.
class HttpApiTransport implements ApiTransport {
  HttpApiTransport({Duration connectTimeout = const Duration(seconds: 10)})
    : _client = HttpClient()..connectionTimeout = connectTimeout;

  final HttpClient _client;
  static const _maxResponseBytes = 64 * 1024;

  @override
  Future<ApiRawResponse> send(ApiRequest request) async {
    if (request.uri.scheme != 'https') {
      throw const ApiException(ApiException.network);
    }
    final req = await _client.openUrl(request.method, request.uri);
    // A redirect could carry the credential header to another host.
    req.followRedirects = false;
    request.headers.forEach(req.headers.set);
    final body = request.body;
    if (body != null) req.add(utf8.encode(body));
    final res = await req.close();

    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
      if (bytes.length > _maxResponseBytes) {
        throw const ApiException(ApiException.malformedResponse);
      }
    }
    final headers = <String, String>{};
    res.headers.forEach((name, values) => headers[name] = values.join(','));
    return ApiRawResponse(
      res.statusCode,
      utf8.decode(bytes, allowMalformed: true),
      headers,
    );
  }
}

/// The one place every API call goes through: HTTPS only, credentials only in
/// headers, one timeout, one way of reading errors. It never logs anything.
class ApiClient {
  ApiClient({
    required String baseUrl,
    required this.transport,
    this.timeout = const Duration(seconds: 15),
    this.onServerTime,
  }) : _base = Uri.parse(baseUrl) {
    if (_base.scheme != 'https' || _base.host.isEmpty || _base.hasQuery) {
      throw ArgumentError('The API address must be a plain https:// address.');
    }
  }

  final Uri _base;
  final ApiTransport transport;
  final Duration timeout;

  /// Called with the server's clock reading from every answer, together with
  /// how long the request took. Used to keep the phone's trusted clock right.
  Future<void> Function(DateTime serverNow, Duration roundTrip)? onServerTime;

  /// The only values that may ever be put in an address. Never a credential.
  static const _allowedQuery = {'limit', 'before'};

  /// Sends a request and returns the JSON object of a successful answer.
  /// Throws [ApiException] for everything else.
  Future<Map<String, Object?>> send(
    String method,
    String path, {
    Map<String, Object?>? body,
    InstallationIdentity? auth,
    Map<String, String>? query,
    String? idempotencyKey,
  }) async {
    // Nothing may be passed in the address: no query, no fragment.
    if (!path.startsWith('/') || path.contains('?') || path.contains('#')) {
      throw ArgumentError('Invalid API path.');
    }
    if (query != null && !query.keys.every(_allowedQuery.contains)) {
      throw ArgumentError('Invalid API query.');
    }
    final request = ApiRequest(
      method: method,
      uri: _base.replace(
        path: '${_base.path}$path',
        queryParameters: query == null || query.isEmpty ? null : query,
      ),
      headers: {
        'accept': 'application/json',
        if (body != null) 'content-type': 'application/json',
        if (auth != null) 'authorization': 'Bearer ${auth.credential}',
        if (auth != null) 'x-installation-id': auth.id,
        'idempotency-key': ?idempotencyKey,
      },
      body: body == null ? null : jsonEncode(body),
    );

    final ApiRawResponse raw;
    final timer = Stopwatch()..start();
    try {
      raw = await transport.send(request).timeout(timeout);
    } on TimeoutException {
      throw const ApiException(ApiException.timeout, retryable: true);
    } on ApiException {
      rethrow;
    } on TlsException {
      // A certificate that cannot be trusted. Never bypassed.
      throw const ApiException(ApiException.network, retryable: true);
    } on IOException {
      throw const ApiException(ApiException.network, retryable: true);
    } catch (_) {
      // The original error is dropped on purpose: it may describe the request.
      throw const ApiException(ApiException.network, retryable: true);
    }

    Map<String, Object?>? json;
    try {
      final decoded = jsonDecode(raw.body);
      if (decoded is Map) json = decoded.cast<String, Object?>();
    } catch (_) {}

    final epochMs = json?['epochMs'];
    final listener = onServerTime;
    if (listener != null && epochMs is int && epochMs > 0) {
      try {
        await listener(
          DateTime.fromMillisecondsSinceEpoch(epochMs),
          timer.elapsed,
        );
      } catch (_) {}
    }

    if (raw.status >= 200 && raw.status < 300) {
      if (json == null) {
        throw ApiException(ApiException.malformedResponse, status: raw.status);
      }
      return json;
    }
    final code = json?['code'];
    final retryAfter = int.tryParse(raw.headers['retry-after'] ?? '');
    throw ApiException(
      code is String && code.isNotEmpty ? code : 'HTTP_${raw.status}',
      status: raw.status,
      retryable: json?['retryable'] == true || raw.status >= 500,
      retryAfter: retryAfter == null || retryAfter < 0
          ? null
          : Duration(seconds: retryAfter.clamp(1, 86400)),
      details: json ?? const {},
    );
  }
}
