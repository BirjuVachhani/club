import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:club_core/club_core.dart';

import 'exceptions.dart';

/// Typed Dart client for interacting with a club server.
///
/// ```dart
/// final client = ClubClient(
///   serverUrl: Uri.parse('https://club.example.com'),
///   token: 'club_a1b2c3d4...',
/// );
///
/// final pkg = await client.listVersions('my_package');
/// ```
class ClubClient {
  ClubClient({
    required this.serverUrl,
    required this.token,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Uri serverUrl;
  final String token;
  final http.Client _http;

  Map<String, String> get _headers => {
    'authorization': 'Bearer $token',
    'accept': 'application/vnd.pub.v2+json',
  };

  Map<String, String> get _jsonHeaders => {
    ..._headers,
    'content-type': 'application/json',
  };

  /// Close the underlying HTTP client.
  void close() => _http.close();

  // ── Packages ───────────────────────────────────────────────

  /// List all versions of a package (pub spec v2 format).
  Future<PackageData> listVersions(String package) async {
    final res = await _get('/api/packages/$package');
    return PackageData.fromJson(res);
  }

  /// Get info for a specific version.
  Future<VersionInfo> getVersion(String package, String version) async {
    final res = await _get('/api/packages/$package/versions/$version');
    return VersionInfo.fromJson(res);
  }

  /// Download a package archive as bytes.
  Future<List<int>> downloadArchive(String package, String version) async {
    final url = serverUrl.resolve('/api/archives/$package-$version.tar.gz');
    final req = http.Request('GET', url)..headers.addAll(_headers);
    final streamedRes = await _http.send(req);

    // Follow redirects manually if needed
    if (streamedRes.statusCode == 302 || streamedRes.statusCode == 303) {
      final location = streamedRes.headers['location'];
      if (location != null) {
        final redirectRes = await _http.get(Uri.parse(location));
        return redirectRes.bodyBytes;
      }
    }

    if (streamedRes.statusCode != 200) {
      _throwForStatus(streamedRes.statusCode, 'Failed to download archive');
    }

    return await streamedRes.stream.toBytes();
  }

  /// Get package options.
  Future<PkgOptions> getOptions(String package) async {
    final res = await _get('/api/packages/$package/options');
    return PkgOptions.fromJson(res);
  }

  /// Set package options.
  Future<PkgOptions> setOptions(String package, PkgOptions options) async {
    final res = await _put('/api/packages/$package/options', options.toJson());
    return PkgOptions.fromJson(res);
  }

  /// Get version options.
  Future<VersionOptions> getVersionOptions(
    String package,
    String version,
  ) async {
    final res = await _get('/api/packages/$package/versions/$version/options');
    return VersionOptions.fromJson(res);
  }

  /// Set version options (retract/unretract).
  Future<VersionOptions> setVersionOptions(
    String package,
    String version,
    VersionOptions options,
  ) async {
    final res = await _put(
      '/api/packages/$package/versions/$version/options',
      options.toJson(),
    );
    return VersionOptions.fromJson(res);
  }

  /// Get package score.
  Future<VersionScore> getScore(String package, {String? version}) async {
    final path = version != null
        ? '/api/packages/$package/versions/$version/score'
        : '/api/packages/$package/score';
    final res = await _get(path);
    return VersionScore.fromJson(res);
  }

  /// Get like count for a package.
  Future<int> getLikeCount(String package) async {
    final res = await _get('/api/packages/$package/likes');
    return res['likes'] as int;
  }

  /// Get all package names.
  Future<List<String>> listAllNames() async {
    final res = await _get('/api/package-name-completion-data');
    return (res['packages'] as List).cast<String>();
  }

  // ── Publishing ─────────────────────────────────────────────

  /// Publish a package from a tarball file path.
  /// Handles the full 3-step upload flow.
  Future<String> publishFile(String filePath, {bool force = false}) async {
    final file = File(filePath);
    return publish(
      file.openRead(),
      length: await file.length(),
      force: force,
    );
  }

  /// Publish a package from a tarball byte stream.
  ///
  /// When [force] is true, appends `?force=true` to the finalize URL so
  /// the server will overwrite an existing version with different content.
  /// Club extension over the pub protocol.
  Future<String> publish(
    Stream<List<int>> tarballBytes, {
    int? length,
    bool force = false,
  }) async {
    // Step 1: Get upload URL
    final uploadInfo = await _get('/api/packages/versions/new');
    final uploadUrl = uploadInfo['url'] as String;
    final fields = Map<String, String>.from(
      (uploadInfo['fields'] as Map).cast<String, String>(),
    );

    // Step 2: Upload tarball as multipart
    final uri = Uri.parse(uploadUrl);
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(_headers)
      ..fields.addAll(fields);

    if (length != null) {
      request.files.add(
        http.MultipartFile(
          'file',
          tarballBytes,
          length,
          filename: 'package.tar.gz',
        ),
      );
    } else {
      final bytes = await tarballBytes.fold<List<int>>(
        [],
        (a, b) => a..addAll(b),
      );
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: 'package.tar.gz',
        ),
      );
    }

    final uploadRes = await _http.send(request);

    // Step 3: Finalize (follow the redirect URL)
    String finalizeUrl;
    if (uploadRes.statusCode == 302 || uploadRes.statusCode == 303) {
      finalizeUrl = uploadRes.headers['location'] ?? '';
    } else if (uploadRes.statusCode == 200) {
      // Some implementations return 200 with the finalize URL in body
      final body = await uploadRes.stream.bytesToString();
      finalizeUrl = body;
    } else {
      final body = await uploadRes.stream.bytesToString();
      _throwForBody(uploadRes.statusCode, body);
    }

    // Make sure the finalize URL is absolute
    final finalizeUri = Uri.parse(finalizeUrl);
    final absoluteUri = finalizeUri.isAbsolute
        ? finalizeUri
        : serverUrl.resolveUri(finalizeUri);
    // Club extension: propagate `force` to the finalize endpoint so the
    // server knows to overwrite an existing version.
    final withForce = force
        ? absoluteUri.replace(
            queryParameters: {
              ...absoluteUri.queryParameters,
              'force': 'true',
            },
          )
        : absoluteUri;

    final finalizeRes = await _http.get(withForce, headers: _headers);
    final finalizeBody = jsonDecode(finalizeRes.body) as Map<String, dynamic>;

    if (finalizeRes.statusCode != 200) {
      final error = finalizeBody['error'] as Map<String, dynamic>?;
      _throwForStatus(
        finalizeRes.statusCode,
        error?['message'] as String? ?? 'Upload finalization failed',
      );
    }

    final success = finalizeBody['success'] as Map<String, dynamic>?;
    return success?['message'] as String? ?? 'Published successfully.';
  }

  // ── Auth ───────────────────────────────────────────────────

  /// Login with email and password. Returns the full login response.
  Future<Map<String, dynamic>> login(String email, String password) async {
    final res = await _http.post(
      serverUrl.resolve('/api/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    _checkResponse(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Create a new personal access token (API key).
  Future<Map<String, dynamic>> createApiKey({
    required String name,
    List<String> scopes = const ['read', 'write'],
    int? expiresInDays,
  }) async {
    return _post('/api/auth/keys', {
      'name': name,
      'scopes': scopes,
      'expiresInDays': ?expiresInDays,
    });
  }

  /// List all API keys for the current user.
  Future<List<Map<String, dynamic>>> listApiKeys() async {
    final res = await _get('/api/auth/keys');
    return (res['keys'] as List).cast<Map<String, dynamic>>();
  }

  /// Revoke an API key.
  Future<void> revokeApiKey(String keyId) async {
    await _delete('/api/auth/keys/$keyId');
  }

  // ── Search ─────────────────────────────────────────────────

  /// Search for packages.
  Future<Map<String, dynamic>> search(
    String query, {
    int page = 1,
    String sort = 'relevance',
  }) async {
    return _get(
      '/api/search?q=${Uri.encodeComponent(query)}&page=$page&sort=$sort',
    );
  }

  // ── Likes ──────────────────────────────────────────────────

  /// Like a package.
  Future<void> like(String package) async {
    await _put('/api/account/likes/$package', {});
  }

  /// Unlike a package.
  Future<void> unlike(String package) async {
    await _delete('/api/account/likes/$package');
  }

  /// Get liked packages.
  Future<List<String>> likedPackages() async {
    final res = await _get('/api/account/likes');
    return (res['likedPackages'] as List)
        .map((p) => (p as Map)['package'] as String)
        .toList();
  }

  // ── Admin ──────────────────────────────────────────────────

  /// List users (admin only).
  Future<Map<String, dynamic>> listUsers({int page = 1, String? email}) async {
    var path = '/api/admin/users?page=$page';
    if (email != null) path += '&email=${Uri.encodeComponent(email)}';
    return _get(path);
  }

  /// Create a user (admin only). [mode] picks the credential-delivery
  /// flow:
  ///
  /// - `'password'` → server generates a random password. The response
  ///   contains `generatedPassword`, shown exactly once. User is forced
  ///   to reset on first login.
  /// - `'invite'`   → server issues a one-time invite URL. The response
  ///   contains `inviteUrl` and `inviteExpiresInHours`.
  ///
  /// [role] is one of `owner`, `admin`, `editor`, `viewer`. Only the
  /// owner can create another owner.
  Future<Map<String, dynamic>> createUser({
    required String email,
    required String displayName,
    String role = 'viewer',
    String mode = 'password',
    int? expiresInHours,
  }) async {
    return _post('/api/admin/users', {
      'email': email,
      'displayName': displayName,
      'role': role,
      'mode': mode,
      'expiresInHours': ?expiresInHours,
    });
  }

  /// Change a user's role and/or active state (admin only).
  Future<Map<String, dynamic>> updateUser({
    required String userId,
    String? role,
    bool? isActive,
    String? displayName,
  }) async {
    return _put('/api/admin/users/$userId', {
      'role': ?role,
      'isActive': ?isActive,
      'displayName': ?displayName,
    });
  }

  /// Delete a user (admin only).
  Future<void> deleteUser(String userId) async {
    await _delete('/api/admin/users/$userId');
  }

  /// Reset a user's password (admin only). If [password] is null the
  /// server generates a random one and returns it in the response.
  Future<Map<String, dynamic>> resetUserPassword({
    required String userId,
    String? password,
  }) async {
    return _post('/api/admin/users/$userId/reset-password', {
      'password': ?password,
    });
  }

  /// Transfer the owner role. Owner-only. Previous owner is demoted to
  /// admin in the same transaction.
  Future<void> transferOwnership(String email) async {
    await _post('/api/admin/transfer-ownership', {'email': email});
  }

  /// Delete a package (admin only).
  Future<void> deletePackage(String package) async {
    await _delete('/api/admin/packages/$package');
  }

  // ── HTTP helpers ───────────────────────────────────────────

  Future<Map<String, dynamic>> _get(String path) async {
    final res = await _http.get(serverUrl.resolve(path), headers: _headers);
    _checkResponse(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final res = await _http.post(
      serverUrl.resolve(path),
      headers: _jsonHeaders,
      body: jsonEncode(body),
    );
    _checkResponse(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _put(
    String path,
    Map<String, dynamic> body,
  ) async {
    final res = await _http.put(
      serverUrl.resolve(path),
      headers: _jsonHeaders,
      body: jsonEncode(body),
    );
    _checkResponse(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> _delete(String path) async {
    final res = await _http.delete(serverUrl.resolve(path), headers: _headers);
    _checkResponse(res);
  }

  void _checkResponse(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    _throwForBody(res.statusCode, res.body);
  }

  Never _throwForBody(int statusCode, String body) {
    String code = 'Unknown';
    String message = 'Request failed with status $statusCode';
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'] as Map<String, dynamic>?;
      code = error?['code'] as String? ?? code;
      message = error?['message'] as String? ?? message;
    } catch (_) {}
    _throwForStatus(statusCode, message, code);
  }

  Never _throwForStatus(int statusCode, String message, [String? code]) {
    throw switch (statusCode) {
      401 => ClubAuthException(message),
      403 => ClubForbiddenException(message),
      404 => ClubNotFoundException(message),
      409 => ClubConflictException(message),
      400 => ClubBadRequestException(code ?? 'InvalidInput', message),
      _ => ClubServerException(message),
    };
  }
}
