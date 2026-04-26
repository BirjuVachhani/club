import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:barbecue/barbecue.dart';
import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';

/// Onboarding / initial setup API.
///
/// Active only when no users exist in the database. Once the admin account
/// is created, these endpoints return 404.
///
/// Flow:
/// 1. Server starts, detects no users → generates a setup code, prints to logs
/// 2. User opens /setup → enters admin email + the code from logs
/// 3. User sets a new password
/// 4. Admin account created, setup mode ends
class SetupApi {
  SetupApi({
    required this.authService,
    required this.metadataStore,
    this.signupEnabled = false,
    this.trustProxy = false,
  }) : _setupCode = _generateCode();

  final AuthService authService;
  final MetadataStore metadataStore;

  /// Mirrors [AppConfig.signupEnabled]. Surfaced via `/api/setup/status`
  /// so the web UI can show/hide the "Create account" link.
  final bool signupEnabled;

  /// Mirrors [AppConfig.trustProxy] for client-IP pinning during setup.
  final bool trustProxy;

  /// The one-time setup code, generated at startup and printed to logs.
  final String _setupCode;
  bool _verified = false;
  String? _verifiedEmail;

  /// The first client IP to successfully call `/api/setup/verify`. Once
  /// set, subsequent calls to `/verify` and `/complete` are rejected if
  /// they come from a different IP — so an attacker who snoops the code
  /// from server logs can't use it from somewhere else, and an operator
  /// completing setup isn't racing an external attacker on the same code.
  String? _verifiedFromIp;

  /// The setup code — call this from bootstrap to print it.
  String get setupCode => _setupCode;

  DecodedRouter get router {
    final router = DecodedRouter();
    router.get('/api/setup/status', _status);
    router.post('/api/setup/verify', _verify);
    router.post('/api/setup/complete', _complete);
    return router;
  }

  Future<bool> _needsSetup() async {
    final users = await metadataStore.listUsers(limit: 1);
    return users.items.isEmpty;
  }

  Future<Response> _status(Request request) async {
    return Response.ok(
      jsonEncode({
        'needsSetup': await _needsSetup(),
        'signupEnabled': signupEnabled,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Verify email + setup code from logs.
  Future<Response> _verify(Request request) async {
    if (!await _needsSetup()) {
      return _setupCompleteResponse();
    }

    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final email = (body['email'] as String?)?.trim() ?? '';
    final code = (body['code'] as String?)?.trim() ?? '';
    final ip = _clientIp(request);

    // Fail-closed on missing client IP. If we can't identify the caller,
    // we can't enforce the IP-pin guarantee, and an attacker behind an
    // unusual deployment (no connection_info exposed, no proxy) could
    // walk through the front door alongside the legitimate operator.
    // Operators who hit this need to configure TRUST_PROXY correctly or
    // run the server on an adapter that exposes connection info.
    if (ip == null) {
      return Response(
        500,
        body: jsonEncode({
          'error': {
            'code': 'SetupIpUnavailable',
            'message':
                'Cannot perform setup: server could not determine the client IP. '
                'Check your reverse-proxy / TRUST_PROXY configuration.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    if (email.isEmpty || !email.contains('@')) {
      return Response(
        400,
        body: jsonEncode({
          'error': {
            'code': 'InvalidInput',
            'message': 'A valid email is required.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    // Pin to first IP. Once someone has successfully verified, only that
    // IP can keep going; anyone else has to wait for the server owner to
    // either finish setup or restart.
    if (_verifiedFromIp != null && _verifiedFromIp != ip) {
      return Response(
        403,
        body: jsonEncode({
          'error': {
            'code': 'SetupLocked',
            'message': 'Setup is already in progress from another address.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    // Constant-time comparison so an attacker can't derive the code
    // character-by-character from response-timing differences.
    if (!_constantTimeEquals(code, _setupCode)) {
      return Response(
        403,
        body: jsonEncode({
          'error': {
            'code': 'InvalidCode',
            'message': 'Invalid setup code.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    _verified = true;
    _verifiedEmail = email;
    _verifiedFromIp = ip;

    return Response.ok(
      jsonEncode({'verified': true, 'email': email}),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Create admin account after verification.
  Future<Response> _complete(Request request) async {
    if (!await _needsSetup()) {
      return _setupCompleteResponse();
    }

    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final email = (body['email'] as String?)?.trim() ?? '';
    final displayName = (body['displayName'] as String?)?.trim() ?? '';
    final password = body['password'] as String? ?? '';
    final confirmPassword = body['confirmPassword'] as String? ?? '';

    if (!_verified || email != _verifiedEmail) {
      return Response(
        403,
        body: jsonEncode({
          'error': {
            'code': 'NotVerified',
            'message': 'Complete verification first.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    // Tighten further: the same IP that verified must also complete. An
    // attacker who obtained the code from logs can't race in between.
    // Fail-closed on null IP (same reasoning as /verify).
    final completeIp = _clientIp(request);
    if (completeIp == null) {
      return Response(
        500,
        body: jsonEncode({
          'error': {
            'code': 'SetupIpUnavailable',
            'message':
                'Cannot complete setup: server could not determine the client IP.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }
    if (_verifiedFromIp != null && _verifiedFromIp != completeIp) {
      return Response(
        403,
        body: jsonEncode({
          'error': {
            'code': 'SetupLocked',
            'message':
                'Setup must be completed from the same address that verified it.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    if (displayName.isEmpty) {
      return Response(
        400,
        body: jsonEncode({
          'error': {
            'code': 'InvalidInput',
            'message': 'Name is required.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    if (password.length < 8) {
      return Response(
        400,
        body: jsonEncode({
          'error': {
            'code': 'WeakPassword',
            'message': 'Password must be at least 8 characters.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }
    if (password.length > AuthService.maxPasswordLength) {
      return Response(
        400,
        body: jsonEncode({
          'error': {
            'code': 'WeakPassword',
            'message':
                'Password must be at most ${AuthService.maxPasswordLength} characters.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    if (password != confirmPassword) {
      return Response(
        400,
        body: jsonEncode({
          'error': {
            'code': 'PasswordMismatch',
            'message': 'Passwords do not match.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    // The very first user becomes the server owner. They are the one
    // person with operator-level privileges (see Permissions).
    //
    // We intentionally do NOT create an API token here. The web client
    // should sign in via /api/auth/login with the password the user just
    // set — that flow owns token issuance, so setup doesn't leave a
    // "default" token lying around for the user to accidentally revoke.
    final user = await authService.createUser(
      email: email,
      password: password,
      displayName: displayName,
      role: UserRole.owner,
    );

    _verified = false;
    _verifiedEmail = null;

    // ignore: avoid_print
    print('Setup complete. Admin account created: $email');

    return Response.ok(
      jsonEncode({
        'message': 'Admin account created successfully.',
        'userId': user.userId,
        'email': user.email,
        'displayName': user.displayName,
        'role': user.role.name,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Response _setupCompleteResponse() => Response(
    404,
    body: jsonEncode({
      'error': {
        'code': 'SetupComplete',
        'message': 'Setup already completed.',
      },
    }),
    headers: {'content-type': 'application/json'},
  );

  /// Generate a setup code. 12-character alphanumeric — ~62¹² ≈ 3×10²¹
  /// combinations, far out of brute-force range even without the rate
  /// limiter on top. Avoids ambiguous chars (0/O, 1/I/l) so users who
  /// have to type it from logs don't misread.
  static String _generateCode() {
    const chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(12, (_) => chars[random.nextInt(chars.length)]).join();
  }

  /// Constant-time string comparison — no early exit on mismatch means
  /// response timing is independent of how much of the code the attacker
  /// guessed right.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  String? _clientIp(Request request) {
    if (trustProxy) {
      final forwarded = request.headers['x-forwarded-for'];
      if (forwarded != null && forwarded.isNotEmpty) {
        return forwarded.split(',').first.trim();
      }
    }
    final conn = request.context['shelf.io.connection_info'];
    if (conn is HttpConnectionInfo) {
      return conn.remoteAddress.address;
    }
    return null;
  }

  /// Print the setup code to logs using barbecue table.
  static void printSetupCode(String code) {
    final table = Table(
      tableStyle: const TableStyle(border: true),
      body: TableSection(
        rows: [
          Row(
            cells: [
              Cell(
                'club — Setup Code\n'
                '\n'
                'Your one-time setup code:\n'
                '\n'
                '    $code\n'
                '\n'
                'Enter this code in the setup wizard at /setup\n'
                'to create your admin account.',
                style: const CellStyle(
                  paddingLeft: 2,
                  paddingRight: 2,
                  paddingTop: 1,
                  paddingBottom: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
    // ignore: avoid_print
    print(table.render());
  }
}
