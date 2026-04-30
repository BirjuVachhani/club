import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';

import '../credentials.dart';
import '../util/prompt.dart';

/// OAuth 2.0 Authorization Code flow with PKCE (RFC 7636).
class LoginCommand extends Command<void> {
  LoginCommand() {
    argParser
      ..addOption(
        'key',
        abbr: 'k',
        help:
            'Authenticate with an existing API key (club_pat_...) '
            'instead of opening the browser. Validated against the server.',
      )
      ..addOption(
        'email',
        abbr: 'e',
        help: 'Email (for display when using --key)',
      )
      ..addFlag(
        'no-browser',
        help: 'Skip browser and prompt for email/password in terminal',
      );
  }

  @override
  String get name => 'login';

  @override
  String get description => 'Authenticate with a club server.';

  @override
  String get invocation => 'club login <server-url>';

  @override
  Future<void> run() async {
    if (argResults!.rest.isEmpty) {
      usageException('Server URL is required.');
    }

    final serverUrl = argResults!.rest.first.replaceAll(RegExp(r'/+$'), '');
    final apiKey = argResults!['key'] as String?;
    final noBrowser = argResults!['no-browser'] as bool;

    // API key mode — validate against /api/auth/me before storing so we
    // don't silently persist a typo or a revoked key.
    if (apiKey != null && apiKey.isNotEmpty) {
      await _loginWithApiKey(serverUrl, apiKey);
      return;
    }

    // Both the browser and terminal-prompt flows require a human at the
    // keyboard. In CI or a piped shell they would either hang (browser flow
    // waits 5 minutes for a callback; stdin reads block on nothing) or
    // silently fail. Fail fast with a message that points at the CI-safe
    // path: pass an API key via --key, or set CLUB_TOKEN for downstream
    // commands that don't need to persist credentials.
    if (!isInteractive || isCI) {
      stderr.writeln(
        'Interactive login is not available in this environment.',
      );
      stderr.writeln(
        'Use an API key: club login $serverUrl --key <club_pat_...>',
      );
      stderr.writeln(
        'Or set ${CredentialStore.envVar} to authenticate without logging in.',
      );
      exitCode = 1;
      return;
    }

    // Terminal prompt mode
    if (noBrowser) {
      await _loginWithPrompt(serverUrl);
      return;
    }

    // OAuth PKCE browser flow (default)
    await _loginWithOAuth(serverUrl);
  }

  /// Validate an API key by calling the server's `/api/auth/me` endpoint
  /// with it as a Bearer token. We refuse to save anything that the
  /// server doesn't accept as a live credential.
  Future<void> _loginWithApiKey(String serverUrl, String apiKey) async {
    // Cheap format sanity check up front so the user gets a clear message
    // before any network round-trip.
    if (!apiKey.startsWith('club_pat_')) {
      stderr.writeln(
        'That doesn\'t look like an API key. Keys start with "club_pat_". '
        'Create one from the web UI at /settings/keys.',
      );
      exitCode = 1;
      return;
    }

    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$serverUrl/api/auth/me'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();

      if (res.statusCode != 200) {
        final msg =
            _extractErrorMessage(body) ?? 'API key not accepted by server.';
        stderr.writeln('Login failed: $msg (HTTP ${res.statusCode}).');
        exitCode = 1;
        return;
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final email =
          json['email'] as String? ?? (argResults!['email'] as String? ?? '');

      CredentialStore.save(serverUrl, apiKey, email);
      await _registerWithDartPub(serverUrl, apiKey);

      stdout.writeln('Logged in as $email');
      stdout.writeln('Token stored for $serverUrl');
      stdout.writeln('Token registered with dart pub.');
    } finally {
      client.close();
    }
  }

  String? _extractErrorMessage(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final err = json['error'];
      if (err is Map && err['message'] is String) {
        return err['message'] as String;
      }
      if (err is String) return err;
    } catch (_) {}
    return null;
  }

  /// OAuth 2.0 Authorization Code flow with PKCE.
  Future<void> _loginWithOAuth(String serverUrl) async {
    // Generate PKCE code_verifier and code_challenge
    final codeVerifier = _generateCodeVerifier();
    final codeChallenge = _computeCodeChallenge(codeVerifier);
    final state = _generateState();

    // Start local callback server
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final redirectUri = 'http://localhost:$port/callback';

    final completer = Completer<Map<String, String>>();

    // Listen for the authorization code callback
    server.listen((req) async {
      if (req.uri.path == '/callback') {
        final code = req.uri.queryParameters['code'];
        final returnedState = req.uri.queryParameters['state'];
        final error = req.uri.queryParameters['error'];
        final errorDesc = req.uri.queryParameters['error_description'];

        if (error != null) {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              _callbackHtml(serverUrl: serverUrl, error: errorDesc ?? error),
            );
          await req.response.close();
          completer.completeError(errorDesc ?? error);
          return;
        }

        if (returnedState != state) {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              _callbackHtml(
                serverUrl: serverUrl,
                error: 'State mismatch — possible CSRF attack.',
              ),
            );
          await req.response.close();
          completer.completeError('State mismatch');
          return;
        }

        if (code == null || code.isEmpty) {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              _callbackHtml(
                serverUrl: serverUrl,
                error: 'No authorization code received.',
              ),
            );
          await req.response.close();
          completer.completeError('No code');
          return;
        }

        // Success — show browser confirmation
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(_callbackHtml(serverUrl: serverUrl));
        await req.response.close();

        completer.complete({'code': code});
      } else {
        req.response
          ..statusCode = 404
          ..write('Not found');
        await req.response.close();
      }
    });

    // Build authorization URL
    final authUrl = Uri.parse('$serverUrl/oauth/authorize').replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': 'cli',
        'redirect_uri': redirectUri,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'state': state,
        'scope': 'read,write',
      },
    );

    stdout.writeln('Opening browser for authentication...');
    stdout.writeln('');
    stdout.writeln('  $authUrl');
    stdout.writeln('');

    await _openBrowser(authUrl.toString());

    stdout.writeln('Waiting for authorization (press Ctrl+C to cancel)...');

    try {
      final result = await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException('Authorization timed out.'),
      );

      final code = result['code']!;

      // Exchange authorization code for token
      stdout.writeln('Exchanging authorization code for token...');

      final tokenResponse = await _exchangeCode(
        serverUrl: serverUrl,
        code: code,
        codeVerifier: codeVerifier,
        redirectUri: redirectUri,
      );

      final token = tokenResponse['access_token'] as String;
      final email = tokenResponse['email'] as String? ?? '';

      CredentialStore.save(serverUrl, token, email);

      // Register token with dart pub so dart pub get/publish work
      await _registerWithDartPub(serverUrl, token);

      stdout.writeln('');
      stdout.writeln('Logged in as $email');
      stdout.writeln('Token stored for $serverUrl');
      stdout.writeln('Token registered with dart pub.');
    } on TimeoutException {
      stderr.writeln('Authorization timed out. Try again.');
    } catch (e) {
      stderr.writeln('Authorization failed: $e');
    } finally {
      await server.close();
    }
  }

  /// Exchange authorization code for an access token.
  Future<Map<String, dynamic>> _exchangeCode({
    required String serverUrl,
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$serverUrl/oauth/token'));
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      final body = Uri(
        queryParameters: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri,
          'code_verifier': codeVerifier,
        },
      ).query;
      req.write(body);

      final res = await req.close();
      final resBody = await res.transform(utf8.decoder).join();
      final json = jsonDecode(resBody) as Map<String, dynamic>;

      if (res.statusCode != 200) {
        final error = json['error_description'] ?? json['error'] ?? 'Unknown';
        throw Exception('Token exchange failed: $error');
      }

      return json;
    } finally {
      client.close();
    }
  }

  /// Terminal prompt fallback.
  Future<void> _loginWithPrompt(String serverUrl) async {
    stdout.write('Email: ');
    final email = stdin.readLineSync()?.trim();
    if (email == null || email.isEmpty) {
      stderr.writeln('Email is required.');
      return;
    }

    stdout.write('Password: ');
    stdin.echoMode = false;
    final password = stdin.readLineSync()?.trim();
    stdin.echoMode = true;
    stdout.writeln();
    if (password == null || password.isEmpty) {
      stderr.writeln('Password is required.');
      return;
    }

    try {
      final response = await _postJson(
        '$serverUrl/api/auth/login',
        {'email': email, 'password': password},
      );

      if (response['token'] == null) {
        stderr.writeln('Login failed: no token returned.');
        return;
      }

      final token = response['token'] as String;
      CredentialStore.save(serverUrl, token, email);
      await _registerWithDartPub(serverUrl, token);
      stdout.writeln('Logged in as $email');
      stdout.writeln('Token stored for $serverUrl');
      stdout.writeln('Token registered with dart pub.');
    } catch (e) {
      stderr.writeln('Login failed: $e');
    }
  }

  // ── dart pub integration ───────────────────────────────────

  /// Register the token with `dart pub token add` so dart pub get/publish work.
  Future<void> _registerWithDartPub(String serverUrl, String token) async {
    try {
      final process = await Process.start('dart', [
        'pub',
        'token',
        'add',
        serverUrl,
      ]);
      process.stdin.writeln(token);
      await process.stdin.close();
      final exitCode = await process.exitCode;
      if (exitCode != 0) {
        stderr.writeln('Warning: failed to register token with dart pub.');
      }
    } catch (e) {
      stderr.writeln('Warning: could not run dart pub token add: $e');
    }
  }

  // ── PKCE helpers (RFC 7636) ───────────────────────────────

  /// Generate a cryptographically random code_verifier (43-128 chars).
  String _generateCodeVerifier() {
    final random = Random.secure();
    final bytes = List.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Compute S256 code_challenge from code_verifier.
  String _computeCodeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Generate a random state parameter for CSRF protection.
  String _generateState() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  // ── HTTP helpers ──────────────────────────────────────────

  Future<Map<String, dynamic>> _postJson(
    String url,
    Map<String, dynamic> body,
  ) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final resBody = await res.transform(utf8.decoder).join();
      final json = jsonDecode(resBody) as Map<String, dynamic>;
      if (res.statusCode >= 400) {
        final error = json['error'] as Map<String, dynamic>?;
        throw Exception(error?['message'] ?? 'Request failed');
      }
      return json;
    } finally {
      client.close();
    }
  }

  Future<void> _openBrowser(String url) async {
    try {
      final ProcessResult result;
      if (Platform.isMacOS) {
        result = await Process.run('open', [url]);
      } else if (Platform.isLinux) {
        result = await Process.run('xdg-open', [url]);
      } else if (Platform.isWindows) {
        result = await Process.run('cmd', ['/c', 'start', '', url]);
      } else {
        return;
      }
      if (result.exitCode != 0) {
        stderr.writeln('Could not open browser: ${result.stderr}');
      }
    } catch (e) {
      stderr.writeln('Could not open browser: $e');
    }
  }

  String _callbackHtml({required String serverUrl, String? error}) {
    final isError = error != null;
    final title = isError ? 'CLUB — Authorization Failed' : 'CLUB — Authorized';
    final heading = isError ? 'Authorization Failed' : 'You\'re all set';
    final subhead = isError
        ? error
        : 'CLUB CLI is now authorized. You can close this tab and return to your terminal.';

    final accent = '#FE4F17';
    final iconColor = isError ? '#E5484D' : accent;
    final iconSvg = isError
        ? '''<svg viewBox="0 0 24 24" width="32" height="32" fill="none" stroke="$iconColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>'''
        : '''<svg viewBox="0 0 24 24" width="32" height="32" fill="none" stroke="$iconColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="8 12.5 11 15.5 16 9.5"/></svg>''';

    return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<meta name="color-scheme" content="light dark" />
<title>$title</title>
<style>
:root {
  --bg: #f7f7f8;
  --card: #ffffff;
  --border: #e5e5e7;
  --text: #1a1a1f;
  --muted: #6b7280;
  --accent: $accent;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0e0e10;
    --card: #17171a;
    --border: #2a2a2f;
    --text: #f4f4f5;
    --muted: #a1a1aa;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; height: 100%; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
  background: var(--bg);
  color: var(--text);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 24px;
  -webkit-font-smoothing: antialiased;
}
.card {
  width: 100%;
  max-width: 440px;
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 16px;
  padding: 40px 32px;
  text-align: center;
  box-shadow: 0 1px 3px rgba(0,0,0,0.04), 0 8px 24px rgba(0,0,0,0.04);
}
.brand {
  display: flex;
  align-items: center;
  justify-content: center;
  margin-bottom: 32px;
}
.brand-logo {
  height: 28px;
  width: auto;
  display: block;
}
.icon-wrap {
  width: 64px;
  height: 64px;
  border-radius: 50%;
  background: ${isError ? 'rgba(229,72,77,0.10)' : 'rgba(254,79,23,0.10)'};
  display: inline-flex;
  align-items: center;
  justify-content: center;
  margin-bottom: 20px;
}
h1 {
  font-size: 22px;
  font-weight: 600;
  margin: 0 0 10px;
  letter-spacing: -0.01em;
}
p {
  font-size: 14px;
  line-height: 1.55;
  color: var(--muted);
  margin: 0;
}
.hint {
  margin-top: 28px;
  font-size: 12px;
  color: var(--muted);
  opacity: 0.75;
}
</style>
</head>
<body>
<main class="card" role="status" aria-live="polite">
  <div class="brand">
    <img class="brand-logo" src="$serverUrl/club_full_logo.svg" alt="CLUB" />
  </div>
  <div class="icon-wrap">$iconSvg</div>
  <h1>$heading</h1>
  <p>$subhead</p>
  <p class="hint">You can close this tab.</p>
</main>
</body>
</html>''';
  }
}
