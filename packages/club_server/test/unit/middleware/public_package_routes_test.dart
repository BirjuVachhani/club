import 'package:club_core/club_core.dart';
import 'package:club_server/src/middleware/public_package_access.dart';
import 'package:test/test.dart';

/// Snapshot of the anonymous read surface, in the style of
/// `public_routes_test.dart`.
///
/// `PublicPackageAccess.packageForAnonymousRead` is an allowlist, so the
/// risk is not that it rejects too much, that shows up immediately as a
/// broken feature, but that a future route accidentally matches one of
/// its shapes and becomes readable without credentials. Every route that
/// must NOT be anonymous is asserted here by name, so adding one of them
/// to the allowlist breaks a test rather than shipping quietly.
String? _pkg(String path, [String method = 'GET']) =>
    PublicPackageAccess.packageForAnonymousRead(path, method);

void main() {
  group('routes that may be read anonymously', () {
    const eligible = <String>[
      // pub spec v2 read surface
      '/api/packages/my_pkg',
      '/api/packages/my_pkg/versions/1.0.0',
      '/api/packages/my_pkg/versions/1.0.0/archive.tar.gz',
      // metadata the package page renders
      '/api/packages/my_pkg/score',
      '/api/packages/my_pkg/versions/1.0.0/score',
      '/api/packages/my_pkg/versions/1.0.0/scoring-report',
      '/api/packages/my_pkg/content',
      '/api/packages/my_pkg/versions/1.0.0/content',
      '/api/packages/my_pkg/options',
      '/api/packages/my_pkg/versions/1.0.0/options',
      '/api/packages/my_pkg/publisher',
      '/api/packages/my_pkg/likes',
      '/api/packages/my_pkg/permissions',
      '/api/packages/my_pkg/dartdoc-status',
      '/api/packages/my_pkg/list-info',
      // assets the rendered README and carousel point at
      '/api/packages/my_pkg/versions/1.0.0/screenshots/0.png',
      '/api/packages/my_pkg/versions/1.0.0/readme-assets/0.png',
      // generated docs
      '/documentation/my_pkg/latest/',
      '/documentation/my_pkg/latest/index.html',
      '/documentation/my_pkg/1.0.0/api/index.html',
    ];

    for (final path in eligible) {
      test('$path resolves to its package', () {
        expect(_pkg(path), 'my_pkg', reason: '$path should be eligible');
      });
    }

    test('HEAD is treated like GET', () {
      expect(_pkg('/api/packages/my_pkg', 'HEAD'), 'my_pkg');
    });
  });

  group('routes that must never be anonymous', () {
    const denied = <String, String>{
      // PII
      '/api/packages/my_pkg/uploaders': 'uploader emails and user ids',
      '/api/packages/my_pkg/activity-log': 'agent emails, ownership history',
      // business intelligence
      '/api/packages/my_pkg/downloads': 'download counts',
      // admin surface
      '/api/packages/my_pkg/visibility': 'visibility administration',
      // publish flow, the catastrophic one
      '/api/packages/versions/new': 'publish session start',
      '/api/packages/versions/upload': 'tarball upload',
      '/api/packages/versions/newUploadFinish': 'publish finalize',
      '/api/packages/versions/newUploadFinish/abc123': 'publish finalize',
      // other route families
      '/api/admin/users': 'admin',
      '/api/admin/packages': 'admin',
      '/api/account/likes': 'account',
      '/api/auth/me': 'auth',
      '/api/publishers/acme/members': 'publisher member PII',
    };

    denied.forEach((path, why) {
      test('$path is denied ($why)', () {
        expect(_pkg(path), isNull, reason: '$path must not be anonymous: $why');
      });
    });

    test('mutations are denied even on eligible shapes', () {
      for (final method in ['POST', 'PUT', 'PATCH', 'DELETE']) {
        expect(
          _pkg('/api/packages/my_pkg', method),
          isNull,
          reason: '$method must never be anonymous',
        );
        expect(_pkg('/api/packages/my_pkg/options', method), isNull);
      }
    });

    test('DELETE /api/packages/<pkg> is denied', () {
      expect(_pkg('/api/packages/my_pkg', 'DELETE'), isNull);
    });
  });

  group('anonymous collections', () {
    // These are not package-scoped, so `packageForAnonymousRead` returns
    // null for them by design. They are allowed by a separate rule and
    // are safe only because the handler behind each one filters by
    // VisibilityScope. The pairing is the whole safety argument, so the
    // list is pinned exactly.
    const collections = [
      '/api/search',
      '/api/discover',
      '/api/packages',
      '/api/package-name-completion-data',
    ];

    for (final path in collections) {
      test('$path is an anonymous collection', () {
        expect(PublicPackageAccess.isAnonymousCollection(path, 'GET'), isTrue);
        expect(
          _pkg(path),
          isNull,
          reason: 'collections are not package-scoped reads',
        );
      });
    }

    test('no other path is treated as an anonymous collection', () {
      for (final path in [
        '/api/admin/packages',
        '/api/account/packages',
        '/api/publishers',
        '/api/packages/my_pkg',
        '/api/search/advanced',
        '/api/packages/',
      ]) {
        expect(
          PublicPackageAccess.isAnonymousCollection(path, 'GET'),
          isFalse,
          reason: '$path must not be an anonymous collection',
        );
      }
    });

    test('collections are read-only', () {
      for (final method in ['POST', 'PUT', 'DELETE']) {
        expect(
          PublicPackageAccess.isAnonymousCollection('/api/search', method),
          isFalse,
        );
      }
    });
  });

  group('reserved first segments', () {
    // A package literally named `versions` was publishable before this
    // feature. On such a registry, treating the first segment as a package
    // name would classify the publish endpoints as reads of it.
    test('`versions` is never treated as a package name', () {
      expect(_pkg('/api/packages/versions'), isNull);
      expect(_pkg('/api/packages/versions/new'), isNull);
      expect(_pkg('/api/packages/versions/upload'), isNull);
    });

    test('`archives` is never treated as a package name', () {
      expect(_pkg('/api/packages/archives'), isNull);
    });

    test('names merely containing a reserved word are fine', () {
      expect(_pkg('/api/packages/versions_util'), 'versions_util');
      expect(_pkg('/api/packages/my_archives'), 'my_archives');
    });
  });

  group('unknown shapes fail closed', () {
    const unknown = <String>[
      '/api/packages/my_pkg/some-future-route',
      '/api/packages/my_pkg/versions/1.0.0/some-future-route',
      '/api/packages/my_pkg/versions',
      '/api/packages/my_pkg/versions/',
      '/api/packages/',
      '/api/packages',
      '/documentation/',
      '/documentation/my_pkg',
      '/',
      '',
    ];

    for (final path in unknown) {
      test('"$path" is denied', () {
        expect(
          _pkg(path),
          isNull,
          reason: 'unrecognised shapes must fail closed, not guess',
        );
      });
    }

    test('a deeper nesting than any known route is denied', () {
      expect(
        _pkg('/api/packages/my_pkg/versions/1.0.0/screenshots/0/extra'),
        isNull,
      );
    });
  });

  _traversalRegressions();

  group('percent-encoding cannot desynchronise the gate from the router', () {
    // The gate matches the raw path; handlers receive the decoded capture
    // (DecodedRouter). A bypass needs a string that reads as one package
    // raw and a different one decoded. That is blocked only by
    // PackageNameValidator forbidding `%` in names, which lives in another
    // package, so it is pinned here.
    test('a name that decodes differently must contain a character that is '
        'illegal in a package name', () {
      const valid = r'^[a-z][a-z0-9_]*$';
      for (final raw in [
        'provider%2Ffoo', // decodes to provider/foo
        'pro%76ider', // decodes to provider
        'foo%2Dbar', // decodes to foo-bar
        '%2e%2e',
      ]) {
        expect(
          Uri.decodeComponent(raw) != raw,
          isTrue,
          reason: '$raw should decode to something different',
        );
        expect(
          RegExp(valid).hasMatch(raw),
          isFalse,
          reason:
              '$raw must not be a legal package name, otherwise the gate '
              'could approve it while the router serves the decoded name',
        );
      }
    });

    test('PackageNameValidator rejects every name containing a percent sign',
        () {
      // The load-bearing rule. If this ever passes, the gate must decode
      // before comparing.
      for (final name in ['pro%76ider', 'a%2Fb', 'pkg%25']) {
        expect(
          PackageNameValidator.isValid(name),
          isFalse,
          reason: '$name must be rejected as a package name',
        );
      }
    });

    test('an encoded separator is rejected outright', () {
      // Originally this asserted the gate returned the raw segment
      // `provider%2Fuploaders`, which failed closed only because no such
      // package could exist. The security review showed that reasoning
      // does not hold for routes with a free-form remainder, so the gate
      // now refuses encoded separators before it ever names a package.
      expect(_pkg('/api/packages/provider%2Fuploaders'), isNull);
      expect(
        Uri.parse('http://x/api/packages/a%2Fb').path,
        '/api/packages/a%2Fb',
        reason:
            'Uri.path preserves %2F rather than decoding it, which is why '
            'the gate has to check for it explicitly',
      );
    });
  });

  group('archive candidates', () {
    // The split between package and version is genuinely ambiguous, so
    // every candidate must be public before the request is allowed. If
    // this class picked one split and the router picked another, the gate
    // could approve a public `foo` while the router served a private
    // `foo-bar`.
    test('an unambiguous name yields one candidate', () {
      expect(
        PublicPackageAccess.archiveCandidates(
          '/api/archives/mypkg-1.0.0.tar.gz',
          'GET',
        ),
        {'mypkg'},
      );
    });

    test('a hyphenated name yields every possible split', () {
      final candidates = PublicPackageAccess.archiveCandidates(
        '/api/archives/foo-bar-1.0.0.tar.gz',
        'GET',
      );
      expect(candidates, containsAll(['foo', 'foo-bar']));
    });

    test('a prerelease version with hyphens still yields the real package', () {
      final candidates = PublicPackageAccess.archiveCandidates(
        '/api/archives/mypkg-1.0.0-beta.1.tar.gz',
        'GET',
      );
      expect(candidates, contains('mypkg'));
    });

    test('the legacy tarball route is unambiguous', () {
      expect(
        PublicPackageAccess.archiveCandidates(
          '/packages/mypkg/versions/1.0.0.tar.gz',
          'GET',
        ),
        {'mypkg'},
      );
    });

    test('non-archive paths yield nothing', () {
      for (final path in [
        '/api/packages/mypkg',
        '/api/archives/',
        '/api/archives/nohyphen.tar.gz',
        '/api/archives/mypkg-1.0.0.zip',
        '/packages/mypkg/other/1.0.0.tar.gz',
      ]) {
        expect(
          PublicPackageAccess.archiveCandidates(path, 'GET'),
          isEmpty,
          reason: '$path is not an archive request',
        );
      }
    });

    test('mutations yield nothing', () {
      expect(
        PublicPackageAccess.archiveCandidates(
          '/api/archives/mypkg-1.0.0.tar.gz',
          'DELETE',
        ),
        isEmpty,
      );
    });

    test('a leading or trailing hyphen produces no empty candidate', () {
      final candidates = PublicPackageAccess.archiveCandidates(
        '/api/archives/-1.0.0.tar.gz',
        'GET',
      );
      expect(candidates, isNot(contains('')));
    });
  });
}

/// Regression tests for CVE-shaped bug found in security review: an
/// anonymous request could read a private package's generated dartdoc by
/// pointing a public package's documentation URL at it with an encoded
/// separator.
///
/// `Uri.parse` collapses `../` and `%2e%2e/` before any handler runs, so
/// those never reached the gate. `..%2f` survives normalization as a
/// single opaque segment, so the gate read `provider` as the package
/// while `shelf_static` decoded the segment and served `go_router`.
void _traversalRegressions() {
  group('encoded-separator traversal (security regression)', () {
    const publicPkg = 'provider';

    test('the exploit path is no longer an anonymous-eligible read', () {
      const exploit =
          '/documentation/$publicPkg/latest/..%2f..%2fgo_router/latest/index.html';
      expect(
        PublicPackageAccess.packageForAnonymousRead(exploit, 'GET'),
        isNull,
        reason:
            'this returned "$publicPkg" before the fix, which authorised a '
            'read of go_router',
      );
    });

    test('uppercase encoding is caught too', () {
      expect(
        PublicPackageAccess.packageForAnonymousRead(
          '/documentation/$publicPkg/latest/..%2F..%2Fgo_router/latest/index.html',
          'GET',
        ),
        isNull,
      );
    });

    test('encoded backslash is caught', () {
      expect(
        PublicPackageAccess.packageForAnonymousRead(
          '/documentation/$publicPkg/latest/..%5c..%5cgo_router/index.html',
          'GET',
        ),
        isNull,
      );
    });

    test('an encoded separator anywhere denies the request', () {
      for (final path in [
        '/api/packages/$publicPkg/versions/1.0.0/readme-assets/..%2f..%2fx.png',
        '/api/packages/$publicPkg/versions/1.0.0/screenshots/..%2fx.png',
        '/api/packages/$publicPkg%2f..%2fother',
      ]) {
        expect(
          PublicPackageAccess.packageForAnonymousRead(path, 'GET'),
          isNull,
          reason: '$path smuggles a separator',
        );
      }
    });

    test('malformed percent-encoding fails closed', () {
      expect(
        PublicPackageAccess.packageForAnonymousRead(
          '/documentation/$publicPkg/latest/%zz/index.html',
          'GET',
        ),
        isNull,
      );
    });

    test('ordinary encoded characters are still allowed', () {
      // %2B in a version is legitimate (build metadata) and must keep
      // working; it does not decode to a separator.
      expect(
        PublicPackageAccess.packageForAnonymousRead(
          '/api/packages/$publicPkg/versions/1.0.0%2B1',
          'GET',
        ),
        publicPkg,
      );
      expect(
        PublicPackageAccess.packageForAnonymousRead(
          '/documentation/$publicPkg/latest/api/Foo-class.html',
          'GET',
        ),
        publicPkg,
      );
    });
  });
}
