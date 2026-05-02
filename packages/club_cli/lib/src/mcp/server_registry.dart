/// Multi-server state for `club mcp`.
///
/// `club mcp` runs in one of two modes:
///
///   - **Pinned** — `--server <url>` was passed (optionally with `--token`).
///     Exactly one server is exposed; the active server can't change.
///   - **Discovered** — no `--server` flag. All servers in the user's
///     credentials file are exposed; one is the active default. Tools can
///     switch via `switch_server`.
///
/// In either mode, [clientFor] returns a cached [ClubClient] per server URL
/// so we don't open a new HTTP connection per tool call. [closeAll] is
/// invoked on shutdown to release sockets.
library;

import 'package:club_api/club_api.dart';

import '../credentials.dart';
import '../util/url.dart';

/// One server's identity and stored credential.
class RegisteredServer {
  RegisteredServer({
    required this.url,
    required this.token,
    this.email,
  });

  /// Canonical server URL (the form used in the credentials file).
  final String url;

  /// Bearer token used to authenticate against [url].
  final String token;

  /// Email associated with this credential, when known. Pinned-mode entries
  /// (where the user passed `--token`) have no email.
  final String? email;
}

class ServerRegistryError implements Exception {
  ServerRegistryError(this.message, {this.hint});

  final String message;
  final String? hint;

  @override
  String toString() => message;
}

/// Whether `club mcp` was started with an explicit `--server` flag.
enum RegistryMode { pinned, discovered }

class ServerRegistry {
  ServerRegistry._({
    required this.mode,
    required Map<String, RegisteredServer> servers,
    required String activeUrl,
  }) : _servers = servers,
       _activeUrl = activeUrl;

  /// Pinned mode — exactly one server, optionally with a flag-supplied token.
  factory ServerRegistry.pinned({
    required String serverUrl,
    String? token,
  }) {
    final resolvedToken = token ?? CredentialStore.getToken(serverUrl);
    if (resolvedToken == null || resolvedToken.isEmpty) {
      throw ServerRegistryError(
        'Not logged in to ${displayServer(serverUrl)}.',
        hint: 'Run `club login ${displayServer(serverUrl)}` or pass '
            '--token <pat>.',
      );
    }
    final stored = CredentialStore.listServers()[serverUrl];
    final server = RegisteredServer(
      url: serverUrl,
      token: resolvedToken,
      email: stored?['email'] as String?,
    );
    return ServerRegistry._(
      mode: RegistryMode.pinned,
      servers: {serverUrl: server},
      activeUrl: serverUrl,
    );
  }

  /// Discovered mode — every logged-in server from the credentials file.
  factory ServerRegistry.discovered() {
    final stored = CredentialStore.listServers();
    if (stored.isEmpty) {
      throw ServerRegistryError(
        'No club servers are logged in.',
        hint:
            'Run `club login <host>` first, or start `club mcp` with '
            '--server and --token to use a specific server without storing '
            'credentials.',
      );
    }
    final servers = <String, RegisteredServer>{};
    for (final entry in stored.entries) {
      final token = entry.value['token'] as String?;
      if (token == null || token.isEmpty) continue;
      servers[entry.key] = RegisteredServer(
        url: entry.key,
        token: token,
        email: entry.value['email'] as String?,
      );
    }
    if (servers.isEmpty) {
      throw ServerRegistryError(
        'No usable credentials found.',
        hint: 'Re-run `club login <host>` to refresh your token.',
      );
    }
    final defaultUrl = CredentialStore.getDefaultServer();
    final activeUrl = (defaultUrl != null && servers.containsKey(defaultUrl))
        ? defaultUrl
        : servers.keys.first;
    return ServerRegistry._(
      mode: RegistryMode.discovered,
      servers: servers,
      activeUrl: activeUrl,
    );
  }

  final RegistryMode mode;
  final Map<String, RegisteredServer> _servers;
  final Map<String, ClubClient> _clientCache = {};
  String _activeUrl;

  /// All registered servers, ordered with the active one first.
  List<RegisteredServer> get servers {
    final entries = _servers.values.toList();
    entries.sort((a, b) {
      if (a.url == _activeUrl) return -1;
      if (b.url == _activeUrl) return 1;
      return a.url.compareTo(b.url);
    });
    return entries;
  }

  /// The currently-active server. In pinned mode this never changes.
  RegisteredServer get active => _servers[_activeUrl]!;

  bool get isPinned => mode == RegistryMode.pinned;

  /// Resolve [serverUrl] (or fall back to the active server) to a registered
  /// entry. Throws [ServerRegistryError] when the URL isn't registered, or
  /// when the caller passes a non-active URL while in pinned mode.
  RegisteredServer resolve(String? serverUrl) {
    if (serverUrl == null || serverUrl.isEmpty) return active;
    final canonical = parseServerInput(serverUrl);
    if (isPinned && canonical != _activeUrl) {
      throw ServerRegistryError(
        'club mcp was started in pinned mode for ${displayServer(active.url)}; '
        'the requested server ${displayServer(canonical)} is not exposed.',
        hint:
            'Restart `club mcp` without --server to use multiple servers, '
            'or run a separate MCP server instance for '
            '${displayServer(canonical)}.',
      );
    }
    final entry = _servers[canonical];
    if (entry == null) {
      throw ServerRegistryError(
        'Unknown server: ${displayServer(canonical)}',
        hint:
            'Use the `list_servers` tool to see registered servers, or run '
            '`club login ${displayServer(canonical)}` first.',
      );
    }
    return entry;
  }

  /// Get (or build and cache) a [ClubClient] for [serverUrl]. The client is
  /// reused across calls and closed by [closeAll].
  ClubClient clientFor(String? serverUrl) {
    final server = resolve(serverUrl);
    return _clientCache.putIfAbsent(
      server.url,
      () => ClubClient(serverUrl: Uri.parse(server.url), token: server.token),
    );
  }

  /// Switch the active server. No-op in pinned mode (caller will hit the
  /// pinned-mode guard from [resolve] anyway).
  void setActive(String serverUrl) {
    if (isPinned) {
      throw ServerRegistryError(
        'Cannot switch active server in pinned mode.',
        hint:
            'Restart `club mcp` without --server to enable server switching.',
      );
    }
    final canonical = parseServerInput(serverUrl);
    if (!_servers.containsKey(canonical)) {
      throw ServerRegistryError(
        'Unknown server: ${displayServer(canonical)}',
        hint: 'Use `list_servers` to see registered servers.',
      );
    }
    _activeUrl = canonical;
  }

  void closeAll() {
    for (final client in _clientCache.values) {
      client.close();
    }
    _clientCache.clear();
  }
}
