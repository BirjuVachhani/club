import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/path_safety.dart';

/// Grants anonymous read access to routes that target a package marked
/// public.
///
/// Modelled on [InternalScoringToken]: the **route-shape allowlist is the
/// load-bearing half**, and the visibility lookup only narrows it further.
/// A path this class does not recognise gets no access no matter what the
/// database says.
///
/// Why not `public_routes.dart`: that file is a static set of strings, and
/// visibility is per-package data. The only prefix that could express
/// "package reads" is `/api/packages/`, which also swallows
/// `/api/packages/versions/new` (publish session start), `POST
/// /api/packages/versions/upload`, `/api/packages/PKG/uploaders`
/// (emails), and `DELETE /api/packages/PKG`. That entry would make
/// publishing and deletion anonymous. The doc comment in
/// `public_routes.dart` predicts exactly this failure.
///
/// Why inside `authMiddleware` rather than a second middleware:
/// `authMiddleware` is the documented single source of truth for the
/// deny decision and is also where CSRF is enforced. A second middleware
/// that could independently grant access would mean there are two answers
/// to "is this request allowed", which is one too many.
class PublicPackageAccess {
  PublicPackageAccess({
    required MetadataStore store,
    required Future<bool> Function() isEnabled,
  }) : _store = store,
       _isEnabled = isEnabled;

  final MetadataStore _store;

  /// The master switch, read per request rather than cached, so turning
  /// public packages off takes effect on the next request instead of the
  /// next restart. That is what makes it a kill switch.
  final Future<bool> Function() _isEnabled;

  /// First path segments under `/api/packages/` that are fixed route
  /// names, not package names.
  ///
  /// `PackageNameValidator` now rejects these as package names, so the
  /// collision cannot be created going forward. This stays as the second
  /// half of a belt-and-braces pair: a registry that predates that
  /// validation change could already contain a package called `versions`,
  /// and `GET /api/packages/versions/new` must never be read as a read of
  /// it. Without this the publish-session endpoint would be anonymous for
  /// such a registry.
  static const _reservedFirstSegments = {'versions', 'archives'};

  /// Collection reads that are safe without credentials *because the
  /// handler filters them*, not because of anything about the path.
  ///
  /// These cannot be gated the way a single-package read is: the response
  /// is assembled from rows no path segment names. What makes them safe
  /// is `visibilityScopeFor(request)` reaching the store as
  /// [VisibilityScope.anonymous], so only public packages come back.
  ///
  /// Consequently this set and the scope plumbing are two halves of one
  /// mechanism. Adding a path here without a scoped handler behind it is
  /// a full catalogue leak, which is why the list is exact-match, short,
  /// and pinned by `public_package_routes_test.dart`.
  ///
  /// Still gated on the master switch, so a server that has not opted in
  /// answers exactly as it does today.
  static const _anonymousCollectionPaths = {
    // Search and browse. Both filter via SearchIndex.search(scope:).
    '/api/search',
    '/api/discover',
    // Package name listing. Filters via listPackages(scope:).
    '/api/packages',
    '/api/package-name-completion-data',
  };

  /// True when [path] is a collection read that anonymous callers may
  /// make, relying on the handler's own visibility filter.
  static bool isAnonymousCollection(String path, String method) {
    final m = method.toUpperCase();
    if (m != 'GET' && m != 'HEAD') return false;
    return _anonymousCollectionPaths.contains(path);
  }

  /// The package this request is "about", or null when the path is not an
  /// anonymous-eligible shape.
  ///
  /// Deliberately written with literal segment matching and part-count
  /// checks rather than `startsWith`. A prefix match here is how a future
  /// `/api/packages/<pkg>/uploaders` route silently becomes public.
  ///
  /// ## Percent-encoding
  ///
  /// This reads the **raw** path, while handlers receive the **decoded**
  /// capture (see `DecodedRouter`). A bypass would need a string that is a
  /// public package name when raw but names a different package once
  /// decoded.
  ///
  /// That is impossible only because `PackageNameValidator` restricts
  /// names to `^[a-z][a-z0-9_]*$`: a string that decodes to something
  /// different must contain `%`, `%` is not a legal name character, so the
  /// visibility lookup finds nothing and the request is denied. The
  /// failure direction is conservative, an over-encoded URL for a genuinely
  /// public package gets 401 rather than the package.
  ///
  /// This safety therefore depends on a rule enforced in a different
  /// package. `public_package_routes_test.dart` pins it. If package names
  /// are ever widened to allow `%`, this becomes a live bypass and the
  /// comparison must decode first.
  static String? packageForAnonymousRead(String path, String method) {
    final m = method.toUpperCase();
    if (m != 'GET' && m != 'HEAD') return null;

    // A segment that decodes to a separator makes the earlier segments a
    // lie: this method would report the first segment as "the package
    // this request is about" while a downstream handler that decodes the
    // remainder serves a file belonging to a different one. That is not
    // hypothetical, it is how an anonymous request could read a private
    // package's dartdoc through a public package's URL.
    if (hasEncodedTraversal(path)) return null;

    // Dartdoc: /documentation/<pkg>/<version>/<rest>. Same regex shape as
    // the router's own `matchDartdoc`, so the two agree on which segment
    // is the package.
    if (path.startsWith('/documentation/')) {
      final parts = path.substring('/documentation/'.length).split('/');
      if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
        return parts[0];
      }
      return null;
    }

    // Tarball download. Handled by the caller via [archiveCandidates],
    // because the split between package and version is ambiguous.
    if (path.startsWith('/api/archives/')) return null;

    if (!path.startsWith('/api/packages/')) return null;

    final tail = path.substring('/api/packages/'.length);
    if (tail.isEmpty) return null;
    final parts = tail.split('/');

    final pkg = parts[0];
    if (pkg.isEmpty) return null;
    if (_reservedFirstSegments.contains(pkg)) return null;

    // /api/packages/<pkg>
    if (parts.length == 1) return pkg;

    // /api/packages/<pkg>/<suffix>
    if (parts.length == 2) {
      const allowed = {
        'score',
        'content',
        'options',
        'publisher',
        'likes',
        'permissions',
        'dartdoc-status',
        'list-info',
        // Deliberately absent, and each for a reason:
        //   uploaders:     emails and user ids
        //   activity-log:  agent emails, full ownership history
        //   downloads:     download counts are business intelligence
        //   visibility:    reading it is harmless but it is an admin
        //                  surface; keep the anonymous surface minimal
      };
      return allowed.contains(parts[1]) ? pkg : null;
    }

    // /api/packages/<pkg>/versions/<version>
    if (parts.length == 3) {
      if (parts[1] != 'versions' || parts[2].isEmpty) return null;
      return pkg;
    }

    // /api/packages/<pkg>/versions/<version>/<suffix>
    if (parts.length == 4) {
      if (parts[1] != 'versions' || parts[2].isEmpty) return null;
      const allowed = {
        'score',
        'content',
        'options',
        'scoring-report',
        'archive.tar.gz',
      };
      return allowed.contains(parts[3]) ? pkg : null;
    }

    // /api/packages/<pkg>/versions/<v>/screenshots/<i>
    // /api/packages/<pkg>/versions/<v>/readme-assets/<file>
    if (parts.length == 5) {
      if (parts[1] != 'versions' || parts[2].isEmpty) return null;
      if (parts[4].isEmpty) return null;
      const allowed = {'screenshots', 'readme-assets'};
      return allowed.contains(parts[3]) ? pkg : null;
    }

    return null;
  }

  /// Every way `<package>-<version>.tar.gz` could split.
  ///
  /// `foo-bar-1.0.0.tar.gz` is (`foo-bar`, `1.0.0`) or (`foo`,
  /// `bar-1.0.0`) and the filename alone cannot say which. If this class
  /// picked one split and `shelf_router`'s regex picked the other, the
  /// result would be either a false 401 or, far worse, a bypass: the gate
  /// approving a public `foo` while the router served a private `foo-bar`.
  ///
  /// So every candidate must be public. Returns an empty set for a path
  /// that is not an archive request at all.
  static Set<String> archiveCandidates(String path, String method) {
    final m = method.toUpperCase();
    if (m != 'GET' && m != 'HEAD') return const {};

    String? filename;
    if (path.startsWith('/api/archives/') && path.endsWith('.tar.gz')) {
      filename = path.substring('/api/archives/'.length);
    } else if (path.startsWith('/packages/') && path.endsWith('.tar.gz')) {
      // Legacy: /packages/<pkg>/versions/<version>.tar.gz. This one is
      // unambiguous, and it is the single pub-spec route the auth
      // middleware never sees (no `/api/` prefix). It 303s to the gated
      // URL, so it is covered in practice, but returning the name here
      // keeps the two paths consistent.
      final parts = path.substring('/packages/'.length).split('/');
      if (parts.length == 3 && parts[1] == 'versions' && parts[0].isNotEmpty) {
        return {parts[0]};
      }
      return const {};
    }
    if (filename == null) return const {};

    final stem = filename.substring(0, filename.length - '.tar.gz'.length);
    final candidates = <String>{};
    for (var i = 0; i < stem.length; i++) {
      if (stem[i] != '-') continue;
      final pkg = stem.substring(0, i);
      final version = stem.substring(i + 1);
      if (pkg.isEmpty || version.isEmpty) continue;
      candidates.add(pkg);
    }
    return candidates;
  }

  /// Whether this request may proceed without credentials.
  ///
  /// Fails closed at every step: master switch off, unrecognised path
  /// shape, unknown package, or any candidate split not public all mean
  /// no.
  Future<bool> allows(Request request) async {
    final path = '/${request.url.path}';
    final method = request.method;

    // Collections carry their own filter, so there is no package to look
    // up. The master switch still applies: with it off, nothing on this
    // server is public and browsing anonymously should not be possible
    // at all, not merely return an empty list.
    if (isAnonymousCollection(path, method)) {
      return _isEnabled();
    }

    final archive = archiveCandidates(path, method);
    if (archive.isNotEmpty) {
      if (!await _isEnabled()) return false;
      for (final candidate in archive) {
        if (!await _isPublic(candidate)) return false;
      }
      return true;
    }

    final pkg = packageForAnonymousRead(path, method);
    if (pkg == null) return false;
    if (!await _isEnabled()) return false;
    return _isPublic(pkg);
  }

  Future<bool> _isPublic(String name) async {
    final pkg = await _store.lookupPackage(name);
    return pkg != null && pkg.isPublic;
  }
}
