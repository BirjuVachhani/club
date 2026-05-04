import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:pub_semver/pub_semver.dart';

import '../version.dart';

final _log = Logger('UpdateChecker');

/// The Club GitHub repo and matching GHCR image. Hard-coded because the
/// server is the project's *own* binary — no operator deployment ever
/// wants to point at a different upstream.
const _githubOwner = 'BirjuVachhani';
const _githubRepo = 'club';
const _ghcrImage = 'birjuvachhani/club';

/// Snapshot of "is there a newer release available?" The state is
/// returned to the admin UI (which gates the badge + the dialog) and
/// to the in-process cache. Every field except [running] is nullable
/// so we can return a partial result even when GitHub or GHCR is
/// unreachable.
class UpdateStatus {
  const UpdateStatus({
    required this.running,
    this.latest,
    this.updateAvailable = false,
    this.releaseUrl,
    this.releaseTag,
    this.releaseNotes,
    this.publishedAt,
    required this.checkedAt,
  });

  /// The version this server is running. Always set, mirrors
  /// [kServerVersion].
  final String running;

  /// The latest stable version published on GitHub *and* available as a
  /// Docker image on GHCR. `null` when the upstream check failed, when
  /// the local build is a pre-release (we don't compare against
  /// stable releases for dev/RC builds), or when the manifest hasn't
  /// landed yet.
  final String? latest;

  /// True iff [latest] > [running] under semver. False otherwise — both
  /// "we're up to date" and "we couldn't tell" collapse to false so the
  /// UI never nags an admin on a transient outage.
  final bool updateAvailable;

  /// GitHub release html_url, e.g.
  /// `https://github.com/BirjuVachhani/club/releases/tag/v0.2.0`. The
  /// admin dialog renders a "View on GitHub" link from this.
  final String? releaseUrl;

  /// The raw GitHub tag (e.g. `v0.2.0`). The Docker tag is the same
  /// without the leading `v`.
  final String? releaseTag;

  /// The release body (Markdown). Rendered inside the admin dialog.
  /// May be null if the maintainer published an empty release.
  final String? releaseNotes;

  /// ISO-8601 timestamp from GitHub.
  final String? publishedAt;

  /// When this snapshot was produced. Lets the UI show "checked X ago"
  /// without hitting the API again, and tells operators whether the
  /// scheduled task is firing.
  final DateTime checkedAt;

  Map<String, Object?> toJson() => {
    'running': running,
    'latest': latest,
    'updateAvailable': updateAvailable,
    'releaseUrl': releaseUrl,
    'releaseTag': releaseTag,
    'releaseNotes': releaseNotes,
    'publishedAt': publishedAt,
    'checkedAt': checkedAt.toIso8601String(),
  };
}

/// Server-side check for "is there a new release of Club available?".
///
/// Implementations must be safe to call from the request path: they
/// should never throw, never block on slow networks beyond their own
/// timeout, and should serve from cache between scheduled refreshes
/// rather than fanning out to GitHub on every call.
abstract class UpdateChecker {
  /// Last computed snapshot, or `null` if no successful check has run
  /// yet (e.g. the server just booted and the first refresh is still
  /// in flight).
  UpdateStatus? get latest;

  /// Force a fresh check against GitHub + GHCR and update [latest].
  /// Errors are swallowed and logged at fine — call sites never need
  /// try/catch.
  Future<void> refresh();
}

/// Production implementation: hits the GitHub Releases API for the
/// latest stable, then probes GHCR for a manifest at the matching tag.
/// Both calls are time-boxed and never throw.
///
/// The GHCR check is the load-bearing one. CI publishes the GitHub
/// release first and the multi-arch Docker image several minutes
/// later, so an admin who's checking right after a release would see
/// "Update available" but `docker pull` would fail. We don't surface
/// the upgrade until the manifest is actually pullable.
class GithubUpdateChecker implements UpdateChecker {
  GithubUpdateChecker({
    HttpClient? httpClient,
    this.timeout = const Duration(seconds: 5),
    String runningVersion = kServerVersion,
  }) : _client = httpClient ?? HttpClient(),
       _runningVersion = runningVersion {
    // Identify ourselves to the GitHub API. Anonymous requests without
    // a UA are rate-limited harder and may be blocked outright.
    _client.userAgent = 'club-server/$runningVersion (+https://github.com/$_githubOwner/$_githubRepo)';
  }

  final HttpClient _client;
  final Duration timeout;
  final String _runningVersion;

  UpdateStatus? _latest;

  @override
  UpdateStatus? get latest => _latest;

  @override
  Future<void> refresh() async {
    final now = DateTime.now().toUtc();

    // Skip the check entirely for non-stable local builds. Comparing a
    // dev/RC against the latest stable would either falsely claim
    // "update available" (when the dev is actually ahead of stable) or
    // be confusing in the other direction. Operators on a custom build
    // know what they're doing and don't need a notifier.
    final running = _tryParseVersion(_runningVersion);
    if (running == null || running.isPreRelease) {
      _latest = UpdateStatus(running: _runningVersion, checkedAt: now);
      _log.fine(
        'Skipping update check: running version "$_runningVersion" is a '
        'pre-release or unparseable.',
      );
      return;
    }

    final release = await _fetchLatestRelease();
    if (release == null) {
      // Keep whatever the previous successful check produced, but bump
      // checkedAt so the UI knows the cron is alive.
      _latest = UpdateStatus(
        running: _runningVersion,
        latest: _latest?.latest,
        updateAvailable: _latest?.updateAvailable ?? false,
        releaseUrl: _latest?.releaseUrl,
        releaseTag: _latest?.releaseTag,
        releaseNotes: _latest?.releaseNotes,
        publishedAt: _latest?.publishedAt,
        checkedAt: now,
      );
      return;
    }

    // Strip the leading `v` from the tag — Docker tags are bare semver
    // (`0.2.0`) but GitHub tags conventionally carry the `v` prefix
    // (`v0.2.0`). Both the comparison and the GHCR lookup need the
    // bare form.
    final latestTag = release.tag;
    final bareLatest = latestTag.startsWith('v')
        ? latestTag.substring(1)
        : latestTag;
    final latestVersion = _tryParseVersion(bareLatest);

    // Don't surface an "update" unless (a) the parsed latest > running
    // *and* (b) the Docker image is actually pullable. Until both are
    // true, we still publish the snapshot (useful for "checked X ago"
    // in the UI) but with `updateAvailable: false`.
    var updateAvailable = false;
    if (latestVersion != null && latestVersion > running) {
      final imagePresent = await _ghcrManifestExists(bareLatest);
      updateAvailable = imagePresent;
      if (!imagePresent) {
        _log.fine(
          'GitHub release $latestTag exists but ghcr.io/$_ghcrImage:'
          '$bareLatest is not yet pullable — withholding update '
          'notification until the image lands.',
        );
      }
    }

    _latest = UpdateStatus(
      running: _runningVersion,
      latest: bareLatest,
      updateAvailable: updateAvailable,
      releaseUrl: release.htmlUrl,
      releaseTag: latestTag,
      releaseNotes: release.body,
      publishedAt: release.publishedAt,
      checkedAt: now,
    );
  }

  // ── GitHub ───────────────────────────────────────────────────

  Future<_LatestRelease?> _fetchLatestRelease() async {
    final uri = Uri.parse(
      'https://api.github.com/repos/$_githubOwner/$_githubRepo/releases/latest',
    );
    try {
      final req = await _client.getUrl(uri).timeout(timeout);
      // GitHub's recommended Accept header for the v3 REST API.
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(timeout);
      if (res.statusCode != HttpStatus.ok) {
        _log.fine(
          'GitHub releases/latest returned ${res.statusCode}',
        );
        await res.drain<void>().timeout(timeout).catchError((_) {});
        return null;
      }
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;

      final tag = decoded['tag_name'];
      if (tag is! String || tag.isEmpty) return null;

      // `releases/latest` excludes pre-releases and drafts on GitHub's
      // side, but defend against the upstream behaviour changing.
      if (decoded['prerelease'] == true || decoded['draft'] == true) {
        return null;
      }

      return _LatestRelease(
        tag: tag,
        htmlUrl: decoded['html_url'] as String?,
        body: decoded['body'] as String?,
        publishedAt: decoded['published_at'] as String?,
      );
    } on TimeoutException {
      _log.fine('GitHub releases/latest timed out');
      return null;
    } catch (e) {
      _log.fine('GitHub releases/latest failed: $e');
      return null;
    }
  }

  // ── GHCR ─────────────────────────────────────────────────────

  /// Check whether `ghcr.io/<image>:<version>` has a manifest. Public
  /// images on GHCR still require a (free, anonymous) bearer token —
  /// the registry returns 401 with a `WWW-Authenticate` challenge that
  /// tells us where to fetch one.
  Future<bool> _ghcrManifestExists(String version) async {
    final manifestUri = Uri.parse(
      'https://ghcr.io/v2/$_ghcrImage/manifests/$version',
    );

    final firstAttempt = await _ghcrManifestHead(manifestUri, null);
    if (firstAttempt == null) return false;
    if (firstAttempt.statusCode == HttpStatus.ok) return true;

    if (firstAttempt.statusCode == HttpStatus.unauthorized) {
      final challenge = firstAttempt.wwwAuthenticate;
      if (challenge == null) return false;
      final token = await _fetchGhcrToken(challenge);
      if (token == null) return false;
      final retry = await _ghcrManifestHead(manifestUri, token);
      if (retry == null) return false;
      return retry.statusCode == HttpStatus.ok;
    }

    return false;
  }

  /// HEAD the manifest URL. Returns the status code and the
  /// `WWW-Authenticate` header (if present), or null on network
  /// failure. Uses HEAD instead of GET to skip downloading the
  /// manifest body — we only care about existence.
  Future<_GhcrProbeResult?> _ghcrManifestHead(
    Uri uri,
    String? bearerToken,
  ) async {
    try {
      final req = await _client.openUrl('HEAD', uri).timeout(timeout);
      // OCI registries match on Accept; without it some implementations
      // return 404 for an image that exists in the v2 manifest format.
      req.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.oci.image.manifest.v1+json,'
        'application/vnd.docker.distribution.manifest.v2+json,'
        'application/vnd.docker.distribution.manifest.list.v2+json,'
        'application/vnd.oci.image.index.v1+json',
      );
      if (bearerToken != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearerToken');
      }
      final res = await req.close().timeout(timeout);
      // Drain anything the server sent back — HEAD responses can still
      // carry a body in some edge cases.
      await res.drain<void>().timeout(timeout).catchError((_) {});
      return _GhcrProbeResult(
        statusCode: res.statusCode,
        wwwAuthenticate: res.headers.value(HttpHeaders.wwwAuthenticateHeader),
      );
    } on TimeoutException {
      _log.fine('GHCR manifest HEAD timed out for $uri');
      return null;
    } catch (e) {
      _log.fine('GHCR manifest HEAD failed for $uri: $e');
      return null;
    }
  }

  /// Parse `Bearer realm="...",service="...",scope="..."` and exchange
  /// it for an anonymous token. Returns null on any failure — the
  /// caller treats that as "image not pullable".
  Future<String?> _fetchGhcrToken(String challenge) async {
    final params = _parseAuthChallenge(challenge);
    final realm = params['realm'];
    if (realm == null || realm.isEmpty) return null;

    final tokenUri = Uri.parse(realm).replace(
      queryParameters: {
        if (params['service'] != null) 'service': params['service']!,
        if (params['scope'] != null) 'scope': params['scope']!,
      },
    );

    try {
      final req = await _client.getUrl(tokenUri).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(timeout);
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>().timeout(timeout).catchError((_) {});
        _log.fine('GHCR token endpoint returned ${res.statusCode}');
        return null;
      }
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      // GHCR returns the token under either `token` or `access_token`.
      final token = decoded['token'] ?? decoded['access_token'];
      return token is String && token.isNotEmpty ? token : null;
    } on TimeoutException {
      _log.fine('GHCR token request timed out');
      return null;
    } catch (e) {
      _log.fine('GHCR token request failed: $e');
      return null;
    }
  }

  /// Parse a `WWW-Authenticate: Bearer realm="...",service="..."`
  /// header into a key/value map. Tolerant of extra whitespace and of
  /// values that contain commas inside the quotes.
  static Map<String, String> _parseAuthChallenge(String header) {
    final out = <String, String>{};
    var rest = header.trim();
    if (rest.toLowerCase().startsWith('bearer')) {
      rest = rest.substring(6).trimLeft();
    }
    // Pattern: key="value with possible \"escapes\""[, key=...]
    final regex = RegExp(r'([A-Za-z][A-Za-z0-9_-]*)\s*=\s*"((?:\\.|[^"])*)"');
    for (final match in regex.allMatches(rest)) {
      out[match.group(1)!.toLowerCase()] = match
          .group(2)!
          .replaceAll(r'\"', '"');
    }
    return out;
  }

  // ── helpers ─────────────────────────────────────────────────

  static Version? _tryParseVersion(String raw) {
    try {
      return Version.parse(raw);
    } on FormatException {
      return null;
    }
  }
}

class _LatestRelease {
  _LatestRelease({
    required this.tag,
    required this.htmlUrl,
    required this.body,
    required this.publishedAt,
  });

  final String tag;
  final String? htmlUrl;
  final String? body;
  final String? publishedAt;
}

class _GhcrProbeResult {
  _GhcrProbeResult({required this.statusCode, required this.wwwAuthenticate});
  final int statusCode;
  final String? wwwAuthenticate;
}

/// In-memory checker for tests. Returns whatever you seed.
class FakeUpdateChecker implements UpdateChecker {
  FakeUpdateChecker({UpdateStatus? initial}) : _latest = initial;

  UpdateStatus? _latest;

  /// Test-only: replace the snapshot returned by [latest].
  void seed(UpdateStatus? status) {
    _latest = status;
  }

  @override
  UpdateStatus? get latest => _latest;

  @override
  Future<void> refresh() async {
    // No-op by default. Tests that want to observe a refresh override
    // [seed] or subclass.
  }
}
