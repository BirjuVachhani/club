/// Resolves which logged-in club server provides a given package.
///
/// Priority:
///   1. A caller-supplied [pinnedUrl] (e.g. a `hosted:` pin inside a
///      pubspec descriptor) — use that URL exclusively; no search, no
///      picker. Must be a server the user is logged in to.
///   2. `--server <url>` flag — use that URL. Must be a logged-in server;
///      the package must exist there.
///   3. Fan out across every logged-in server; filter to those that return
///      a hit. Zero → fail. One → auto-pick. Many → interactive picker.
///
/// The picker surfaces each server's web URL so the user can click through
/// and compare before choosing.
///
/// This resolver is shared between `club add` and `club global activate` —
/// any command that needs to pick one of the user's logged-in servers on
/// the basis of which one hosts a named package.
library;

import 'package:club_api/club_api.dart';
import 'package:pub_semver/pub_semver.dart' as semver;

import '../credentials.dart';
import '../util/log.dart';
import '../util/prompt.dart';
import '../util/url.dart';

/// Thrown when no server can satisfy a request.
class ResolveError implements Exception {
  ResolveError(this.message, [this.hint]);
  final String message;
  final String? hint;
  @override
  String toString() => message;
}

/// A resolved hosting server for one package lookup.
class ServerHit {
  ServerHit({
    required this.serverUrl,
    required this.token,
    required this.packageData,
    required this.latestStableVersion,
  });

  /// The canonical server URL (normalised, no trailing slash).
  final String serverUrl;

  /// The credential the caller should use when talking to [serverUrl].
  /// Sourced from `CLUB_TOKEN` or the credentials file.
  final String token;

  /// Full version listing as returned by the server. Callers that need
  /// metadata beyond the latest-stable version (retracted flags,
  /// pre-release listings, publisher info) can read it here.
  final PackageData packageData;

  /// The best stable, non-retracted version on [serverUrl]. Callers that
  /// only need the server URL can ignore this.
  final semver.Version latestStableVersion;
}

/// Fan-out + picker over the user's logged-in club servers.
class HostingServerResolver {
  HostingServerResolver({
    required this.serverFlag,
    ClientFactory? clientFactory,
    CredentialReader? credentials,
  }) : _clientFactory = clientFactory ?? _defaultClientFactory,
       _credentials = credentials ?? const DefaultCredentialReader();

  /// Value of the `--server` flag, if any.
  final String? serverFlag;

  final ClientFactory _clientFactory;
  final CredentialReader _credentials;

  /// Resolve the hosting server for [packageName].
  ///
  /// [pinnedUrl] — when non-null, bypass the picker and target that URL
  /// exclusively (used by `club add` for descriptor-level `hosted:` pins).
  Future<ServerHit> resolve({
    required String packageName,
    String? pinnedUrl,
  }) async {
    // ── 1. Caller-supplied pin trumps everything. ─────────────────────────
    if (pinnedUrl != null) {
      final token = _credentials.tokenFor(pinnedUrl);
      if (token == null) {
        throw ResolveError(
          'Package "$packageName" is pinned to $pinnedUrl but you are not '
              'logged in to that server.',
          'Run: club login $pinnedUrl',
        );
      }
      return _queryOne(packageName, pinnedUrl, token);
    }

    // ── 2. Explicit --server flag. ────────────────────────────────────────
    if (serverFlag != null && serverFlag!.isNotEmpty) {
      final url = normalizeServerUrl(serverFlag!);
      final token = _credentials.tokenFor(url);
      if (token == null) {
        throw ResolveError(
          'Not logged in to $url.',
          'Run: club login $url',
        );
      }
      return _queryOne(packageName, url, token);
    }

    // ── 3. Fan out across every logged-in server. ─────────────────────────
    final logins = _credentials.listServers();
    if (logins.isEmpty) {
      throw ResolveError(
        'No club server is configured.',
        'Run: club login <server-url>',
      );
    }

    final hits = <ServerHit>[];
    final authFailures = <String>[];
    await Future.wait(
      logins.entries.map((entry) async {
        final url = entry.key;
        final token = entry.value['token'] as String;
        final client = _clientFactory(url, token);
        try {
          final data = await client.listVersions(packageName);
          final latest = _resolveLatest(data, url);
          if (latest == null) {
            return; // Only pre-release / unparseable versions.
          }
          hits.add(
            ServerHit(
              serverUrl: url,
              token: token,
              packageData: data,
              latestStableVersion: latest,
            ),
          );
        } on ClubNotFoundException {
          // Server doesn't have this package — fine, try the rest.
        } on ClubAuthException {
          authFailures.add(url);
        } on ClubApiException catch (e) {
          warning('Skipping $url: ${e.message}');
        } catch (e) {
          warning('Skipping $url: $e');
        } finally {
          client.close();
        }
      }),
    );

    if (hits.isEmpty) {
      final msg = authFailures.isEmpty
          ? 'Package "$packageName" was not found on any logged-in club '
                'server.'
          : 'Package "$packageName" was not found. '
                'Authentication failed on: ${authFailures.join(', ')}.';
      throw ResolveError(
        msg,
        'Check the package name, or log in to a server that hosts it.',
      );
    }

    if (hits.length == 1) {
      final hit = hits.first;
      info(
        '   Found ${bold(packageName)} on ${cyan(hit.serverUrl)} '
        '${gray('(v${hit.latestStableVersion})')}',
      );
      return hit;
    }

    return _promptPick(packageName, hits);
  }

  Future<ServerHit> _queryOne(
    String packageName,
    String url,
    String token,
  ) async {
    final client = _clientFactory(url, token);
    try {
      final data = await client.listVersions(packageName);
      final latest = _resolveLatest(data, url);
      if (latest == null) {
        throw ResolveError(
          '$packageName on $url has no stable versions — only pre-releases.',
          'Pin a specific version, e.g. $packageName:${data.latest.version}',
        );
      }
      return ServerHit(
        serverUrl: url,
        token: token,
        packageData: data,
        latestStableVersion: latest,
      );
    } on ClubNotFoundException {
      throw ResolveError(
        'Package "$packageName" was not found on $url.',
      );
    } on ClubAuthException catch (e) {
      throw ResolveError(
        'Authentication failed for $url: ${e.message}',
        'Run: club login $url',
      );
    } finally {
      client.close();
    }
  }

  Future<ServerHit> _promptPick(
    String packageName,
    List<ServerHit> hits,
  ) async {
    info('');
    info('   Multiple servers provide ${bold(packageName)}:');
    final picked = await pick<ServerHit>(
      '   Select which to use:',
      [
        for (final h in hits)
          PickOption(
            label: '${h.serverUrl}  ${cyan('v${h.latestStableVersion}')}',
            value: h,
            detail: '${h.serverUrl}/packages/$packageName',
          ),
      ],
    );
    return picked;
  }

  /// Return the best stable version published to this server, or null if
  /// only pre-release / unparseable versions exist.
  ///
  /// Warns (but does not fail) when the server's own `latest` pointer is a
  /// pre-release — that indicates the server considers the pre-release the
  /// freshest release, and silently substituting a lower stable would be
  /// surprising.
  semver.Version? _resolveLatest(PackageData data, String serverUrl) {
    final serverLatest = _parseOrNull(data.latest.version);
    if (serverLatest != null && serverLatest.isPreRelease) {
      warning(
        '$serverUrl lists ${data.name} ${data.latest.version} (pre-release) '
        'as latest. Pin a stable version explicitly to use this server.',
      );
    }
    semver.Version? best;
    for (final v in data.versions) {
      if (v.retracted == true) continue;
      final parsed = _parseOrNull(v.version);
      if (parsed == null) continue;
      if (parsed.isPreRelease) continue;
      if (best == null || parsed > best) best = parsed;
    }
    return best;
  }

  semver.Version? _parseOrNull(String v) {
    try {
      return semver.Version.parse(v);
    } on FormatException {
      return null;
    }
  }
}

/// Factory that produces a [ClubClient] for a given `(url, token)`.
/// Overridable in tests so no real HTTP is issued.
typedef ClientFactory = ClubClient Function(String url, String token);

ClubClient _defaultClientFactory(String url, String token) =>
    ClubClient(serverUrl: Uri.parse(url), token: token);
