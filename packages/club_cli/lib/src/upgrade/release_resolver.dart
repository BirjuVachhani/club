/// Resolves which club release to install, and whether it is installable.
///
/// Modelled on club_server's `update/update_checker.dart`, with one
/// deliberate difference: that checker swallows every failure because a
/// background badge should never break the server, whereas this one
/// surfaces failures because a user who typed `club upgrade` deserves to
/// know why nothing happened.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../version.dart';
import 'release_target.dart';

const _defaultRepo = 'BirjuVachhani/club';

/// Repository to resolve releases from.
///
/// `CLUB_REPO` matches the env var both installer scripts already honour,
/// so a fork only has to be named in one place.
String get releaseRepo {
  final override = Platform.environment['CLUB_REPO'];
  return (override != null && override.isNotEmpty) ? override : _defaultRepo;
}

/// A release, and the assets it currently has published.
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.assetNames,
    this.htmlUrl,
  });

  /// The git tag, which may carry a leading `v`.
  final String tag;

  /// The tag with any leading `v` stripped. This is what appears inside
  /// asset names and what `club --version` prints.
  final String version;

  /// Names of the assets currently attached to the release.
  final Set<String> assetNames;

  final String? htmlUrl;

  /// Whether this release is actually installable on [target].
  ///
  /// A GitHub release can exist before its binaries do: release creation
  /// is a manual step and `build-cli.yml` only reacts to it, so there is a
  /// window of several minutes where the tag is visible but nothing has
  /// been uploaded. Announcing an upgrade during that window sends users
  /// into an installer that dies on a 404.
  ///
  /// Both the platform archive and the checksums file are required.
  /// `install.sh` refuses to install without `SHA256SUMS.txt`, and the
  /// upload job attaches all five archives plus the checksums together, so
  /// a partially uploaded release can genuinely have archives and no sums.
  bool hasAssetsFor(String target) =>
      assetNames.contains(archiveName(version, target)) &&
      assetNames.contains(sha256SumsName);
}

/// Why a resolve failed, when it did.
enum ResolveFailure {
  /// GitHub was unreachable, timed out, or returned an error status.
  unreachable,

  /// The repository has no release matching the request. For the stable
  /// channel this includes "only pre-releases exist".
  noRelease,
}

/// The result of a resolve: exactly one of [release] or [failure] is set.
class ResolveResult {
  const ResolveResult.found(this.release)
      : failure = null,
        message = null;
  const ResolveResult.failed(this.failure, this.message) : release = null;

  final ReleaseInfo? release;
  final ResolveFailure? failure;
  final String? message;

  bool get ok => release != null;
}

/// Looks up releases.
abstract class ReleaseResolver {
  /// Resolves the release to install.
  ///
  /// When [includePreReleases] is false this uses `releases/latest`, which
  /// GitHub filters to stable releases. When true it takes the newest tag
  /// of any kind, which is the same request the installer scripts make
  /// under `--pre`.
  Future<ResolveResult> resolveLatest({required bool includePreReleases});

  /// Looks up one specific tag, for `--version`.
  Future<ResolveResult> resolveTag(String tag);

  void close();
}

/// Resolves releases from the GitHub REST API.
class GithubReleaseResolver implements ReleaseResolver {
  GithubReleaseResolver({
    HttpClient? client,
    String? repo,
    this.timeout = const Duration(seconds: 10),
  })  : _client = client ?? HttpClient(),
        _repo = repo ?? releaseRepo {
    _client.userAgent =
        'club-cli/$clubCliVersion (+https://github.com/$_defaultRepo)';
  }

  final HttpClient _client;
  final String _repo;
  final Duration timeout;

  @override
  Future<ResolveResult> resolveLatest({
    required bool includePreReleases,
  }) async {
    if (includePreReleases) {
      // Byte for byte the request install.sh makes under --pre, so the two
      // never disagree about which tag is newest.
      final result = await _get('releases?per_page=1');
      if (result is! _Ok) return (result as _Err).toResult();
      final decoded = result.body;
      if (decoded is! List || decoded.isEmpty) {
        return ResolveResult.failed(
          ResolveFailure.noRelease,
          'No releases found for $_repo.',
        );
      }
      final release = parseRelease(decoded.first);
      if (release == null) {
        return ResolveResult.failed(
          ResolveFailure.noRelease,
          'The newest release of $_repo is missing a usable tag.',
        );
      }
      return ResolveResult.found(release);
    }

    final result = await _get('releases/latest');
    if (result is _Err) {
      // GitHub 404s releases/latest when a repo has only ever published
      // pre-releases or drafts. That is a real state for a fork, and the
      // fix is a flag rather than anything the user can debug.
      if (result.statusCode == HttpStatus.notFound) {
        return ResolveResult.failed(
          ResolveFailure.noRelease,
          'No stable release found for $_repo. Pass --pre to include '
          'pre-releases.',
        );
      }
      return result.toResult();
    }
    final release = parseRelease((result as _Ok).body, stableOnly: true);
    if (release == null) {
      return ResolveResult.failed(
        ResolveFailure.noRelease,
        'No stable release found for $_repo. Pass --pre to include '
        'pre-releases.',
      );
    }
    return ResolveResult.found(release);
  }

  @override
  Future<ResolveResult> resolveTag(String tag) async {
    final normalised = tag.startsWith('v') ? tag : 'v$tag';
    var result = await _get('releases/tags/$normalised');
    if (result is _Err && result.statusCode == HttpStatus.notFound) {
      // Tags are published as `v1.2.3`, but accept a bare `1.2.3` too
      // rather than making the user guess which form this repo uses.
      result = await _get('releases/tags/${tag.startsWith('v') ? tag.substring(1) : tag}');
    }
    if (result is _Err) {
      if (result.statusCode == HttpStatus.notFound) {
        return ResolveResult.failed(
          ResolveFailure.noRelease,
          'No release tagged $tag in $_repo.',
        );
      }
      return result.toResult();
    }
    final release = parseRelease((result as _Ok).body);
    if (release == null) {
      return ResolveResult.failed(
        ResolveFailure.noRelease,
        'Release $tag in $_repo is missing a usable tag.',
      );
    }
    return ResolveResult.found(release);
  }

  Future<_Response> _get(String path) async {
    final uri = Uri.parse('https://api.github.com/repos/$_repo/$path');
    try {
      final req = await _client.getUrl(uri).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(timeout);
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>().timeout(timeout).catchError((_) {});
        return _Err(res.statusCode, 'GitHub returned ${res.statusCode}.');
      }
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      return _Ok(jsonDecode(body));
    } on TimeoutException {
      return const _Err(null, 'Timed out talking to GitHub.');
    } on SocketException catch (e) {
      return _Err(null, 'Could not reach GitHub: ${e.message}');
    } on FormatException {
      return const _Err(null, 'GitHub returned a response we could not parse.');
    }
  }

  @override
  void close() => _client.close(force: true);
}

/// Turns one release JSON object into a [ReleaseInfo].
///
/// Exposed for tests: this is where every defensive check about the shape
/// of GitHub's response lives, and it is worth exercising without a socket.
ReleaseInfo? parseRelease(Object? decoded, {bool stableOnly = false}) {
  if (decoded is! Map<String, dynamic>) return null;

  final tag = decoded['tag_name'];
  if (tag is! String || tag.isEmpty) return null;

  // `releases/latest` already excludes these on GitHub's side, but defend
  // against the upstream behaviour changing, the way the server does.
  if (stableOnly && (decoded['prerelease'] == true || decoded['draft'] == true)) {
    return null;
  }

  final assets = <String>{};
  final rawAssets = decoded['assets'];
  if (rawAssets is List) {
    for (final asset in rawAssets) {
      if (asset is Map<String, dynamic>) {
        final name = asset['name'];
        if (name is String && name.isNotEmpty) assets.add(name);
      }
    }
  }

  return ReleaseInfo(
    tag: tag,
    version: tag.startsWith('v') ? tag.substring(1) : tag,
    assetNames: assets,
    htmlUrl: decoded['html_url'] as String?,
  );
}

/// A resolver backed by fixed data, for tests.
class FakeReleaseResolver implements ReleaseResolver {
  FakeReleaseResolver({this.latest, this.byTag = const {}, this.failure});

  final ReleaseInfo? latest;
  final Map<String, ReleaseInfo> byTag;
  final ResolveResult? failure;

  @override
  Future<ResolveResult> resolveLatest({required bool includePreReleases}) async {
    if (failure != null) return failure!;
    if (latest == null) {
      return const ResolveResult.failed(
        ResolveFailure.noRelease,
        'No releases.',
      );
    }
    return ResolveResult.found(latest!);
  }

  @override
  Future<ResolveResult> resolveTag(String tag) async {
    if (failure != null) return failure!;
    final bare = tag.startsWith('v') ? tag.substring(1) : tag;
    final found = byTag[tag] ?? byTag[bare] ?? byTag['v$bare'];
    if (found == null) {
      return ResolveResult.failed(
        ResolveFailure.noRelease,
        'No release tagged $tag.',
      );
    }
    return ResolveResult.found(found);
  }

  @override
  void close() {}
}

sealed class _Response {
  const _Response();
}

class _Ok extends _Response {
  const _Ok(this.body);
  final Object? body;
}

class _Err extends _Response {
  const _Err(this.statusCode, this.message);
  final int? statusCode;
  final String message;

  ResolveResult toResult() =>
      ResolveResult.failed(ResolveFailure.unreachable, message);
}
