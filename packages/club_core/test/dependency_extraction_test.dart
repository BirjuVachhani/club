import 'package:club_core/club_core.dart';
import 'package:test/test.dart';

const _self = 'https://club.example.com';

List<VersionDependency> _extract(
  Map<String, dynamic> pubspec, {
  Set<String> localNames = const {},
  String? selfOrigin = _self,
}) {
  return extractDependencies(
    pubspec,
    selfOrigin: selfOrigin,
    isLocallyHosted: localNames.contains,
  );
}

VersionDependency _only(List<VersionDependency> deps, String name) =>
    deps.singleWhere((d) => d.name == name);

void main() {
  group('source classification', () {
    test('an explicit hosted: matching this server is local', () {
      final deps = _extract({
        'dependencies': {
          'core_ui': {'version': '^1.2.0', 'hosted': _self},
        },
      });

      final dep = _only(deps, 'core_ui');
      expect(dep.source, DependencySource.hosted);
      expect(dep.isLocal, isTrue);
      expect(dep.hostedOrigin, _self);
      expect(dep.constraintText, '^1.2.0');
      expect(dep.participatesInClosure, isTrue);
    });

    test('the long hosted: form is read the same as the short form', () {
      final deps = _extract({
        'dependencies': {
          'core_ui': {
            'version': '^1.0.0',
            'hosted': {'name': 'core_ui', 'url': _self},
          },
        },
      });

      expect(_only(deps, 'core_ui').isLocal, isTrue);
    });

    test('an explicit hosted: on another registry is not local', () {
      final deps = _extract({
        'dependencies': {
          'other': {'version': '^1.0.0', 'hosted': 'https://pub.dev'},
        },
      });

      final dep = _only(deps, 'other');
      expect(dep.source, DependencySource.hosted);
      expect(dep.isLocal, isFalse);
      expect(dep.participatesInClosure, isFalse);
    });

    test('origin comparison ignores case, trailing slash, and default port',
        () {
      for (final url in [
        'https://club.example.com/',
        'HTTPS://CLUB.EXAMPLE.COM',
        'https://club.example.com:443',
      ]) {
        final deps = _extract({
          'dependencies': {
            'core_ui': {'version': '^1.0.0', 'hosted': url},
          },
        });
        expect(
          _only(deps, 'core_ui').isLocal,
          isTrue,
          reason: '$url should normalise to $_self',
        );
      }
    });

    test('a non-default port makes it a different origin', () {
      final deps = _extract({
        'dependencies': {
          'core_ui': {'version': '^1.0.0', 'hosted': 'https://club.example.com:8443'},
        },
      });
      expect(_only(deps, 'core_ui').isLocal, isFalse);
    });

    test('sdk, git, and path dependencies never join the closure', () {
      final deps = _extract({
        'dependencies': {
          'flutter': {'sdk': 'flutter'},
          'from_git': {'git': 'https://github.com/x/y.git'},
          'from_path': {'path': '../sibling'},
        },
      });

      expect(_only(deps, 'flutter').source, DependencySource.sdk);
      expect(_only(deps, 'from_git').source, DependencySource.git);
      expect(_only(deps, 'from_path').source, DependencySource.path);
      for (final dep in deps) {
        expect(dep.isLocal, isFalse);
        expect(dep.participatesInClosure, isFalse);
      }
    });

    test('a bare dependency is never local, even when the name exists here',
        () {
      // This is the crux of the bare-vs-hosted ambiguity. `dart pub`
      // resolves a bare dep against the *consumer's* PUB_HOSTED_URL, so an
      // anonymous consumer reaches pub.dev no matter what we do locally.
      // Marking it local would drag a package into the public closure for
      // no benefit at all.
      final deps = _extract(
        {
          'dependencies': {'core_ui': '^1.0.0'},
        },
        localNames: {'core_ui'},
      );

      final dep = _only(deps, 'core_ui');
      expect(dep.source, DependencySource.bare);
      expect(dep.isLocal, isFalse);
      expect(dep.isAmbiguous, isTrue);
      expect(dep.participatesInClosure, isFalse);
    });

    test('a bare dependency with no local namesake is not ambiguous', () {
      final deps = _extract({
        'dependencies': {'http': '^1.0.0'},
      });
      expect(_only(deps, 'http').isAmbiguous, isFalse);
    });

    test('the long form without hosted: behaves like a bare dependency', () {
      final deps = _extract(
        {
          'dependencies': {
            'core_ui': {'version': '^1.0.0'},
          },
        },
        localNames: {'core_ui'},
      );

      final dep = _only(deps, 'core_ui');
      expect(dep.source, DependencySource.bare);
      expect(dep.isAmbiguous, isTrue);
      expect(dep.constraintText, '^1.0.0');
    });

    test('hosted: with no usable url falls back to bare', () {
      final deps = _extract(
        {
          'dependencies': {
            'core_ui': {
              'version': '^1.0.0',
              'hosted': {'name': 'core_ui'},
            },
          },
        },
        localNames: {'core_ui'},
      );

      // pub treats a missing url as the default host, so this must not be
      // mistaken for a local dependency.
      final dep = _only(deps, 'core_ui');
      expect(dep.source, DependencySource.bare);
      expect(dep.isLocal, isFalse);
    });
  });

  group('sections', () {
    test('records all three sections with distinct kinds', () {
      final deps = _extract({
        'dependencies': {
          'a': {'version': '^1.0.0', 'hosted': _self},
        },
        'dev_dependencies': {
          'b': {'version': '^1.0.0', 'hosted': _self},
        },
        'dependency_overrides': {
          'c': {'version': '^1.0.0', 'hosted': _self},
        },
      });

      expect(_only(deps, 'a').kind, DependencyKind.direct);
      expect(_only(deps, 'b').kind, DependencyKind.dev);
      expect(_only(deps, 'c').kind, DependencyKind.override);
    });

    test('only direct dependencies participate in the closure', () {
      // A dependency's dev_dependencies and dependency_overrides are
      // ignored by `pub` for every consumer, so a private club-hosted one
      // in either section breaks nobody downstream.
      final deps = _extract({
        'dev_dependencies': {
          'test_helpers': {'version': '^1.0.0', 'hosted': _self},
        },
        'dependency_overrides': {
          'patched': {'version': '^1.0.0', 'hosted': _self},
        },
      });

      for (final dep in deps) {
        expect(dep.isLocal, isTrue, reason: 'still recorded as club-hosted');
        expect(
          dep.participatesInClosure,
          isFalse,
          reason: '${dep.kind} must not force a package public',
        );
      }
    });

    test('the same name in two sections yields two distinct edges', () {
      final deps = _extract({
        'dependencies': {
          'a': {'version': '^1.0.0', 'hosted': _self},
        },
        'dev_dependencies': {
          'a': {'version': '^2.0.0', 'hosted': _self},
        },
      });

      expect(deps.where((d) => d.name == 'a'), hasLength(2));
      // The composite primary key is (package, version, dep_name, kind),
      // so these must differ by kind or the insert collides.
      expect(
        deps.map((d) => d.kind).toSet(),
        {DependencyKind.direct, DependencyKind.dev},
      );
    });
  });

  group('robustness over historical rows', () {
    // Backfill replays pubspecs that predate current validation. One bad
    // document must not abort the batch.
    test('tolerates missing and non-map sections', () {
      expect(_extract({}), isEmpty);
      expect(_extract({'dependencies': null}), isEmpty);
      expect(_extract({'dependencies': 'nonsense'}), isEmpty);
      expect(_extract({'dependencies': <String, dynamic>{}}), isEmpty);
    });

    test('skips non-string and empty keys', () {
      final deps = _extract({
        'dependencies': {
          '': '^1.0.0',
          1: '^1.0.0',
          'ok': '^1.0.0',
        },
      });
      expect(deps.map((d) => d.name), ['ok']);
    });

    test('tolerates a dependency with a null or odd value', () {
      final deps = _extract({
        'dependencies': {'a': null, 'b': 42},
      });
      expect(deps, hasLength(2));
      expect(_only(deps, 'a').constraintText, isNull);
      expect(_only(deps, 'b').source, DependencySource.bare);
    });

    test('an unparseable hosted url is recorded but not local', () {
      final deps = _extract({
        'dependencies': {
          'weird': {'hosted': 'not a url'},
        },
      });
      final dep = _only(deps, 'weird');
      expect(dep.source, DependencySource.hosted);
      expect(dep.hostedOrigin, isNull);
      expect(dep.isLocal, isFalse);
    });

    test('a null selfOrigin marks nothing local', () {
      // Otherwise `null == null` would classify every unparseable hosted
      // URL as local and pull the whole registry into every closure.
      final deps = _extract(
        {
          'dependencies': {
            'a': {'hosted': 'not a url'},
            'b': {'hosted': _self},
          },
        },
        selfOrigin: null,
      );
      expect(deps.every((d) => !d.isLocal), isTrue);
    });
  });

  group('normaliseDependencyOrigin', () {
    test('normalises scheme, host, trailing slash, and default port', () {
      expect(normaliseDependencyOrigin('HTTPS://Club.Example.COM/'),
          'https://club.example.com');
      expect(normaliseDependencyOrigin('https://club.example.com:443'),
          'https://club.example.com');
      expect(normaliseDependencyOrigin('http://localhost:8080/path'),
          'http://localhost:8080');
    });

    test('rejects non-http schemes and relative URLs', () {
      expect(normaliseDependencyOrigin('ftp://example.com'), isNull);
      expect(normaliseDependencyOrigin('/just/a/path'), isNull);
      expect(normaliseDependencyOrigin(''), isNull);
    });
  });
}
