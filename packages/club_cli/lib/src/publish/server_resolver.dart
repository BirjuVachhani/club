/// Resolves which club server a publish should target.
///
/// Resolution rules (highest priority first):
///
///   1. Explicit `--server <url>` CLI flag — must be logged in.
///
///   2. `publish_to:` in pubspec.yaml:
///      - matches a logged-in server → publish there directly.
///      - `none`, missing, or points at pub.dev / pub.dartlang.org →
///        ignored; fall through to the login picker.
///      - points at any other URL we're not logged in to → abort and
///        prompt the user to `club login` that server first.
///
///   3. No override resolved from 1 or 2:
///      - one logged-in server → auto-pick it.
///      - multiple → interactive menu (errors in non-interactive shells).
///      - zero → abort.
///
/// This is the layer that gives the club CLI its "publish without modifying
/// pubspec" superpower compared to dart pub publish.
library;

import '../credentials.dart';
import '../util/prompt.dart';
import '../util/url.dart';
import 'pubspec_reader.dart';

/// URLs that club treats as "not a club server" — rule 2's pub.dev
/// fallback. Normalised to match [normalizeServerUrl] output.
const Set<String> _nonClubHosts = {
  'https://pub.dev',
  'https://pub.dartlang.org',
  'http://pub.dev',
  'http://pub.dartlang.org',
};

/// Where the resolved target server came from.
enum ServerSource {
  /// User passed `--server <url>`.
  cliFlag,

  /// Read from `publish_to:` in pubspec.yaml and matched a known login.
  pubspec,

  /// Single logged-in server, picked automatically.
  singleLogin,

  /// User picked from multiple logged-in servers via interactive menu.
  interactivePick,
}

/// Result of [ServerResolver.resolve].
class ResolvedServer {
  ResolvedServer({
    required this.url,
    required this.token,
    required this.source,
    this.email,
  });

  final String url;
  final String token;
  final String? email;
  final ServerSource source;

  /// True when the user did not explicitly request this server (so we should
  /// prompt for confirmation before publishing, unless `--force`).
  bool get requiresConfirmation =>
      source == ServerSource.singleLogin ||
      source == ServerSource.interactivePick;
}

/// Thrown when no suitable server can be resolved.
class ServerResolutionError implements Exception {
  ServerResolutionError(this.message, [this.hint]);
  final String message;
  final String? hint;
  @override
  String toString() => message;
}

/// Resolver for the publish target server.
class ServerResolver {
  ServerResolver({CredentialReader? credentials})
    : _credentials = credentials ?? const DefaultCredentialReader();

  final CredentialReader _credentials;

  /// Resolve the publish target.
  ///
  /// [serverFlag] is the `--server` CLI argument (null if not provided).
  /// [pubspec] is the package being published.
  Future<ResolvedServer> resolve({
    required String? serverFlag,
    required PackagePubspec pubspec,
  }) async {
    final logins = _credentials.listServers();

    // 1. Explicit --server flag wins. Must be a logged-in server.
    if (serverFlag != null && serverFlag.isNotEmpty) {
      final url = _normalize(serverFlag);
      final entry = logins[url];
      if (entry == null) {
        throw ServerResolutionError(
          'Not logged in to $url.',
          'Run: club login $url',
        );
      }
      return ResolvedServer(
        url: url,
        token: entry['token'] as String,
        email: entry['email'] as String?,
        source: ServerSource.cliFlag,
      );
    }

    // 2. publish_to in pubspec:
    //    - `none` or missing → ignore and fall through to the picker.
    //    - pub.dev / pub.dartlang.org → ignore, same fall-through. Club's
    //      philosophy is that packages should stay publishable on pub.dev
    //      without having to rewrite pubspec.yaml to target club.
    //    - matches a logged-in server → use it directly.
    //    - points at an unknown URL → abort: the user clearly meant a
    //      specific server, and silently re-routing to a different one
    //      (via the picker) would publish the package somewhere they
    //      didn't intend.
    final publishTo = pubspec.publishTo;
    if (publishTo != null && publishTo != publishToNone) {
      final url = _normalize(publishTo);
      if (!_nonClubHosts.contains(url)) {
        final entry = logins[url];
        if (entry != null) {
          return ResolvedServer(
            url: url,
            token: entry['token'] as String,
            email: entry['email'] as String?,
            source: ServerSource.pubspec,
          );
        }
        throw ServerResolutionError(
          'pubspec.yaml has `publish_to: $url` but you are not logged in '
              'to that server.',
          'Run: club login $url — or remove `publish_to` to publish to '
              'one of your already-logged-in servers.',
        );
      }
    }

    // 3. Fall back to logged-in servers.
    if (logins.isEmpty) {
      throw ServerResolutionError(
        'No club server is configured.',
        'Run: club login <server-url>',
      );
    }

    if (logins.length == 1) {
      final entry = logins.entries.first;
      return ResolvedServer(
        url: entry.key,
        token: entry.value['token'] as String,
        email: entry.value['email'] as String?,
        source: ServerSource.singleLogin,
      );
    }

    // 4. Multiple logins → interactive picker (or fail in CI).
    final picked = await pick<MapEntry<String, Map<String, dynamic>>>(
      'Multiple club servers found. Pick one to publish to:',
      [
        for (final entry in logins.entries)
          PickOption(
            label: entry.key,
            value: entry,
            detail: entry.value['email'] as String?,
          ),
      ],
    );
    return ResolvedServer(
      url: picked.key,
      token: picked.value['token'] as String,
      email: picked.value['email'] as String?,
      source: ServerSource.interactivePick,
    );
  }

  String _normalize(String url) => normalizeServerUrl(url);
}

/// Convenience: print a human-friendly summary of where the server came from.
String describeServerSource(ServerSource source) {
  switch (source) {
    case ServerSource.cliFlag:
      return 'from --server flag';
    case ServerSource.pubspec:
      return 'from publish_to in pubspec.yaml';
    case ServerSource.singleLogin:
      return 'auto-selected (only logged-in server)';
    case ServerSource.interactivePick:
      return 'selected interactively';
  }
}
