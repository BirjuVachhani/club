import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Manages club credential storage.
///
/// Credentials are stored in `~/.config/club/credentials.json` (Unix)
/// or `%APPDATA%\club\credentials.json` (Windows).
class CredentialStore {
  static String get _configDir {
    if (Platform.isWindows) {
      return p.join(Platform.environment['APPDATA']!, 'club');
    }
    return p.join(
      Platform.environment['HOME'] ?? '.',
      '.config',
      'club',
    );
  }

  static String get _credentialsPath => p.join(_configDir, 'credentials.json');

  /// Load the full credentials file.
  static Map<String, dynamic> _load() {
    final file = File(_credentialsPath);
    if (!file.existsSync()) {
      return <String, dynamic>{
        'servers': <String, dynamic>{},
        'defaultServer': null,
      };
    }
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{
        'servers': <String, dynamic>{},
        'defaultServer': null,
      };
    }
  }

  /// Save the full credentials file.
  static void _save(Map<String, dynamic> data) {
    final file = File(_credentialsPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(data),
    );
    // Set restrictive permissions on Unix
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['600', _credentialsPath]);
    }
  }

  /// Store a token for a server.
  static void save(String serverUrl, String token, String email) {
    final data = _load();
    final servers = (data['servers'] as Map<String, dynamic>?) ?? {};
    servers[serverUrl] = {
      'token': token,
      'email': email,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    data['servers'] = servers;
    data['defaultServer'] ??= serverUrl;
    _save(data);
  }

  /// Environment variable name that overrides the stored token. Mirrors
  /// the convention used by other dev tools (`GITHUB_TOKEN`, `STRIPE_API_KEY`
  /// etc). When set, it wins over `~/.config/club/credentials.json`.
  static const String envVar = 'CLUB_TOKEN';

  /// Get the token for a server. Checks `CLUB_TOKEN` env var first, then
  /// falls back to the stored credentials file. The env var lets CI and
  /// ephemeral environments authenticate without touching the config file.
  static String? getToken(String serverUrl) {
    final envToken = Platform.environment[envVar];
    if (envToken != null && envToken.isNotEmpty) {
      return envToken;
    }
    final data = _load();
    final servers = data['servers'] as Map<String, dynamic>? ?? {};
    final entry = servers[serverUrl] as Map<String, dynamic>?;
    return entry?['token'] as String?;
  }

  /// True when the active token came from the [envVar] env variable.
  /// Login/logout commands use this to warn users about a shadowed
  /// stored credential.
  static bool isUsingEnvToken() {
    final envToken = Platform.environment[envVar];
    return envToken != null && envToken.isNotEmpty;
  }

  /// Get the default server URL.
  static String? getDefaultServer() {
    final data = _load();
    return data['defaultServer'] as String?;
  }

  /// Set the default server.
  static void setDefaultServer(String serverUrl) {
    final data = _load();
    data['defaultServer'] = serverUrl;
    _save(data);
  }

  /// Remove credentials for a server.
  static void remove(String serverUrl) {
    final data = _load();
    final servers = data['servers'] as Map<String, dynamic>? ?? {};
    servers.remove(serverUrl);
    if (data['defaultServer'] == serverUrl) {
      data['defaultServer'] = servers.keys.isNotEmpty
          ? servers.keys.first
          : null;
    }
    data['servers'] = servers;
    _save(data);
  }

  /// Remove all credentials.
  static void removeAll() {
    _save(<String, dynamic>{
      'servers': <String, dynamic>{},
      'defaultServer': null,
    });
  }

  /// List all configured servers.
  static Map<String, Map<String, dynamic>> listServers() {
    final data = _load();
    final servers =
        data['servers'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return servers.map(
      (k, v) =>
          MapEntry(k, Map<String, dynamic>.from(v as Map<String, dynamic>)),
    );
  }
}

/// Adapter around [CredentialStore] so command runners can be tested
/// without touching the real credentials file.
abstract class CredentialReader {
  Map<String, Map<String, dynamic>> listServers();
  String? tokenFor(String serverUrl);
}

/// Default implementation backed by [CredentialStore].
class DefaultCredentialReader implements CredentialReader {
  const DefaultCredentialReader();
  @override
  Map<String, Map<String, dynamic>> listServers() =>
      CredentialStore.listServers();
  @override
  String? tokenFor(String serverUrl) => CredentialStore.getToken(serverUrl);
}
