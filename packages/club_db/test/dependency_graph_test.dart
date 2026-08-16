import 'package:club_core/club_core.dart';
import 'package:club_db/club_db.dart';
import 'package:test/test.dart';

Future<({SqliteMetadataStore store, ClubDatabase db})> _store() async {
  final db = await ClubDatabase.memory();
  addTearDown(db.close);
  final store = SqliteMetadataStore(db);
  await store.runMigrations();
  return (store: store, db: db);
}

/// Create a package with the given visibility.
Future<void> _pkg(
  ClubDatabase db,
  String name, {
  PackageVisibility visibility = PackageVisibility.private,
}) async {
  await db.execute(
    'INSERT INTO packages (name, visibility, created_at, updated_at) '
    'VALUES (?, ?, 0, 0)',
    [name, visibility.wireName],
  );
}

/// Create a version of [pkg] that declares club-hosted dependencies on
/// [deps]. [devDeps] land in `dev_dependencies` instead.
Future<void> _version(
  SqliteMetadataStore store,
  ClubDatabase db,
  String pkg,
  String version, {
  List<String> deps = const [],
  List<String> devDeps = const [],
  List<String> pubDevDeps = const [],
}) async {
  await db.execute(
    'INSERT INTO package_versions '
    '(package_name, version, pubspec_json, archive_size_bytes, '
    ' archive_sha256, published_at) VALUES (?, ?, ?, 0, ?, 0)',
    [pkg, version, '{}', 'sha-$pkg-$version'],
  );
  await store.replaceVersionDependencies(pkg, version, [
    for (final d in deps)
      VersionDependency(
        name: d,
        kind: DependencyKind.direct,
        source: DependencySource.hosted,
        hostedOrigin: 'https://club.example.com',
        isLocal: true,
        constraintText: '^1.0.0',
      ),
    for (final d in devDeps)
      VersionDependency(
        name: d,
        kind: DependencyKind.dev,
        source: DependencySource.hosted,
        hostedOrigin: 'https://club.example.com',
        isLocal: true,
        constraintText: '^1.0.0',
      ),
    for (final d in pubDevDeps)
      VersionDependency(
        name: d,
        kind: DependencyKind.direct,
        source: DependencySource.bare,
        constraintText: '^1.0.0',
      ),
  ]);
}

void main() {
  group('localDependencyClosure', () {
    test('follows a transitive chain and includes the root', () async {
      final (:store, :db) = await _store();
      for (final n in ['app', 'core_ui', 'icons']) {
        await _pkg(db, n);
      }
      await _version(store, db, 'app', '1.0.0', deps: ['core_ui']);
      await _version(store, db, 'core_ui', '1.0.0', deps: ['icons']);
      await _version(store, db, 'icons', '1.0.0');

      expect(
        await store.localDependencyClosure({'app'}),
        {'app', 'core_ui', 'icons'},
      );
    });

    test('unions across every version, not just the latest', () async {
      // The reason this matters: `pub` aborts on a 401 rather than
      // backtracking, so if the solver probes app 1.0.0 while resolving a
      // constraint, a private `legacy` breaks the whole resolution even
      // though nobody wants that version.
      final (:store, :db) = await _store();
      for (final n in ['app', 'core_ui', 'legacy']) {
        await _pkg(db, n);
      }
      await _version(store, db, 'app', '1.0.0', deps: ['legacy']);
      await _version(store, db, 'app', '2.0.0', deps: ['core_ui']);
      await _version(store, db, 'core_ui', '1.0.0');
      await _version(store, db, 'legacy', '1.0.0');

      expect(
        await store.localDependencyClosure({'app'}),
        {'app', 'core_ui', 'legacy'},
      );
    });

    test('terminates on a cycle', () async {
      final (:store, :db) = await _store();
      for (final n in ['a', 'b', 'c']) {
        await _pkg(db, n);
      }
      await _version(store, db, 'a', '1.0.0', deps: ['b']);
      await _version(store, db, 'b', '1.0.0', deps: ['c']);
      await _version(store, db, 'c', '1.0.0', deps: ['a']);

      expect(await store.localDependencyClosure({'a'}), {'a', 'b', 'c'});
    });

    test('terminates on a two-node cycle', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'a');
      await _pkg(db, 'b');
      await _version(store, db, 'a', '1.0.0', deps: ['b']);
      await _version(store, db, 'b', '1.0.0', deps: ['a']);

      expect(await store.localDependencyClosure({'a'}), {'a', 'b'});
    });

    test('visits a diamond once', () async {
      final (:store, :db) = await _store();
      for (final n in ['top', 'left', 'right', 'bottom']) {
        await _pkg(db, n);
      }
      await _version(store, db, 'top', '1.0.0', deps: ['left', 'right']);
      await _version(store, db, 'left', '1.0.0', deps: ['bottom']);
      await _version(store, db, 'right', '1.0.0', deps: ['bottom']);
      await _version(store, db, 'bottom', '1.0.0');

      expect(
        await store.localDependencyClosure({'top'}),
        {'top', 'left', 'right', 'bottom'},
      );
    });

    test('excludes dev dependencies by default and includes them on request',
        () async {
      final (:store, :db) = await _store();
      for (final n in ['app', 'test_helpers', 'fixtures']) {
        await _pkg(db, n);
      }
      await _version(store, db, 'app', '1.0.0', devDeps: ['test_helpers']);
      await _version(store, db, 'test_helpers', '1.0.0', deps: ['fixtures']);
      await _version(store, db, 'fixtures', '1.0.0');

      // A dependency's dev_dependencies are never resolved by a consumer,
      // so forcing them public would expose source for no benefit.
      expect(await store.localDependencyClosure({'app'}), {'app'});

      expect(
        await store.localDependencyClosure({'app'}, includeDev: true),
        {'app', 'test_helpers', 'fixtures'},
      );
    });

    test('ignores non-local dependencies', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app');
      await _version(store, db, 'app', '1.0.0', pubDevDeps: ['http']);

      expect(await store.localDependencyClosure({'app'}), {'app'});
    });

    test('accepts multiple roots', () async {
      final (:store, :db) = await _store();
      for (final n in ['a', 'b', 'shared']) {
        await _pkg(db, n);
      }
      await _version(store, db, 'a', '1.0.0', deps: ['shared']);
      await _version(store, db, 'b', '1.0.0', deps: ['shared']);
      await _version(store, db, 'shared', '1.0.0');

      expect(
        await store.localDependencyClosure({'a', 'b'}),
        {'a', 'b', 'shared'},
      );
    });

    test('a package with no versions closes over just itself', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'lonely');
      expect(await store.localDependencyClosure({'lonely'}), {'lonely'});
    });
  });

  group('localDependentsClosure', () {
    test('walks the graph backwards, transitively', () async {
      final (:store, :db) = await _store();
      for (final n in ['app', 'core_ui', 'icons']) {
        await _pkg(db, n);
      }
      await _version(store, db, 'app', '1.0.0', deps: ['core_ui']);
      await _version(store, db, 'core_ui', '1.0.0', deps: ['icons']);
      await _version(store, db, 'icons', '1.0.0');

      expect(
        await store.localDependentsClosure({'icons'}),
        {'icons', 'core_ui', 'app'},
      );
    });

    test('terminates on a cycle', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'a');
      await _pkg(db, 'b');
      await _version(store, db, 'a', '1.0.0', deps: ['b']);
      await _version(store, db, 'b', '1.0.0', deps: ['a']);

      expect(await store.localDependentsClosure({'a'}), {'a', 'b'});
    });
  });

  group('findPublicDependents', () {
    test('returns nothing when no public package depends on it', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app');
      await _pkg(db, 'icons');
      await _version(store, db, 'app', '1.0.0', deps: ['icons']);
      await _version(store, db, 'icons', '1.0.0');

      // `app` is private, so it was already unreachable anonymously and
      // making `icons` private breaks nothing that was working.
      expect(await store.findPublicDependents('icons'), isEmpty);
    });

    test('reports a public direct dependent with its path', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app', visibility: PackageVisibility.public);
      await _pkg(db, 'icons', visibility: PackageVisibility.public);
      await _version(store, db, 'app', '1.0.0', deps: ['icons']);
      await _version(store, db, 'icons', '1.0.0');

      final dependents = await store.findPublicDependents('icons');
      expect(dependents, hasLength(1));
      expect(dependents.single.package, 'app');
      expect(dependents.single.path, ['app', 'icons']);
      expect(dependents.single.pathDescription, 'app -> icons');
    });

    test('reports an indirect dependent with the chain that reaches it',
        () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app', visibility: PackageVisibility.public);
      await _pkg(db, 'core_ui', visibility: PackageVisibility.public);
      await _pkg(db, 'icons', visibility: PackageVisibility.public);
      await _version(store, db, 'app', '1.0.0', deps: ['core_ui']);
      await _version(store, db, 'core_ui', '1.0.0', deps: ['icons']);
      await _version(store, db, 'icons', '1.0.0');

      final dependents = await store.findPublicDependents('icons');
      expect(dependents.map((d) => d.package), ['app', 'core_ui']);

      final app = dependents.firstWhere((d) => d.package == 'app');
      expect(app.path, ['app', 'core_ui', 'icons']);
    });

    test('skips private dependents but keeps public ones behind them',
        () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app', visibility: PackageVisibility.public);
      await _pkg(db, 'core_ui'); // private middle link
      await _pkg(db, 'icons', visibility: PackageVisibility.public);
      await _version(store, db, 'app', '1.0.0', deps: ['core_ui']);
      await _version(store, db, 'core_ui', '1.0.0', deps: ['icons']);
      await _version(store, db, 'icons', '1.0.0');

      final dependents = await store.findPublicDependents('icons');
      expect(dependents.map((d) => d.package), ['app']);
    });

    test('does not report the package itself', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'icons', visibility: PackageVisibility.public);
      await _version(store, db, 'icons', '1.0.0');

      expect(await store.findPublicDependents('icons'), isEmpty);
    });

    test('terminates on a cycle among public packages', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'a', visibility: PackageVisibility.public);
      await _pkg(db, 'b', visibility: PackageVisibility.public);
      await _version(store, db, 'a', '1.0.0', deps: ['b']);
      await _version(store, db, 'b', '1.0.0', deps: ['a']);

      final dependents = await store.findPublicDependents('a');
      expect(dependents.map((d) => d.package), ['b']);
    });

    test('ignores dev-dependency edges', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app', visibility: PackageVisibility.public);
      await _pkg(db, 'test_helpers', visibility: PackageVisibility.public);
      await _version(store, db, 'app', '1.0.0', devDeps: ['test_helpers']);
      await _version(store, db, 'test_helpers', '1.0.0');

      expect(await store.findPublicDependents('test_helpers'), isEmpty);
    });
  });

  group('recomputePublicResolvable', () {
    test('a private package has no resolvable versions', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app');
      await _version(store, db, 'app', '1.0.0');

      await store.recomputePublicResolvable({'app'});
      expect(await _resolvable(db, 'app', '1.0.0'), 0);
    });

    test('a public package with no club deps is resolvable', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app', visibility: PackageVisibility.public);
      await _version(store, db, 'app', '1.0.0', pubDevDeps: ['http']);

      await store.recomputePublicResolvable({'app'});
      expect(await _resolvable(db, 'app', '1.0.0'), 1);
    });

    test('a public package with a private club dep is not resolvable',
        () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app', visibility: PackageVisibility.public);
      await _pkg(db, 'secret');
      await _version(store, db, 'app', '1.0.0', deps: ['secret']);
      await _version(store, db, 'secret', '1.0.0');

      await store.recomputePublicResolvable({'app'});
      expect(await _resolvable(db, 'app', '1.0.0'), 0);
    });

    test('resolvability is per version, not per package', () async {
      // The whole point of the derived flag: `app 2.0.0` can be publicly
      // resolvable while `app 1.0.0` is not, because only the old version
      // still reaches the private package.
      final (:store, :db) = await _store();
      await _pkg(db, 'app', visibility: PackageVisibility.public);
      await _pkg(db, 'core_ui', visibility: PackageVisibility.public);
      await _pkg(db, 'legacy');
      await _version(store, db, 'app', '1.0.0', deps: ['legacy']);
      await _version(store, db, 'app', '2.0.0', deps: ['core_ui']);
      await _version(store, db, 'core_ui', '1.0.0');
      await _version(store, db, 'legacy', '1.0.0');

      await store.recomputePublicResolvable({'app'});
      expect(await _resolvable(db, 'app', '1.0.0'), 0);
      expect(await _resolvable(db, 'app', '2.0.0'), 1);
    });

    test('dev dependencies do not affect resolvability', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app', visibility: PackageVisibility.public);
      await _pkg(db, 'test_helpers');
      await _version(store, db, 'app', '1.0.0', devDeps: ['test_helpers']);
      await _version(store, db, 'test_helpers', '1.0.0');

      await store.recomputePublicResolvable({'app'});
      expect(await _resolvable(db, 'app', '1.0.0'), 1);
    });

    test('an edge pointing at a package that no longer exists blocks it',
        () async {
      // A dangling edge cannot resolve for anyone, so advertising the
      // version would hand out something that always fails.
      final (:store, :db) = await _store();
      await _pkg(db, 'app', visibility: PackageVisibility.public);
      await _version(store, db, 'app', '1.0.0', deps: ['deleted_pkg']);

      await store.recomputePublicResolvable({'app'});
      expect(await _resolvable(db, 'app', '1.0.0'), 0);
    });

    test('reports how many rows actually changed', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app', visibility: PackageVisibility.public);
      await _version(store, db, 'app', '1.0.0');
      await _version(store, db, 'app', '2.0.0');

      expect(await store.recomputePublicResolvable({'app'}), 2);
      // Second run is a no-op, so nothing changes.
      expect(await store.recomputePublicResolvable({'app'}), 0);
    });
  });

  group('packagesDependingOn', () {
    test('finds direct dependents only', () async {
      final (:store, :db) = await _store();
      for (final n in ['app', 'core_ui', 'icons']) {
        await _pkg(db, n);
      }
      await _version(store, db, 'app', '1.0.0', deps: ['core_ui']);
      await _version(store, db, 'core_ui', '1.0.0', deps: ['icons']);

      expect(await store.packagesDependingOn({'icons'}), {'core_ui'});
      expect(await store.packagesDependingOn({'core_ui'}), {'app'});
    });

    test('is empty for an empty input', () async {
      final (:store, :db) = await _store();
      expect(await store.packagesDependingOn({}), isEmpty);
    });
  });

  group('replaceVersionDependencies', () {
    test('replaces rather than accumulates on republish', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app');
      await _version(store, db, 'app', '1.0.0', deps: ['old_dep']);

      await store.replaceVersionDependencies('app', '1.0.0', [
        const VersionDependency(
          name: 'new_dep',
          kind: DependencyKind.direct,
          source: DependencySource.hosted,
          isLocal: true,
        ),
      ]);

      final deps = await store.listVersionDependencies('app', '1.0.0');
      expect(deps.map((d) => d.name), ['new_dep']);
    });

    test('round-trips every field', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app');
      await _version(store, db, 'app', '1.0.0');

      const original = VersionDependency(
        name: 'core_ui',
        kind: DependencyKind.direct,
        source: DependencySource.hosted,
        hostedOrigin: 'https://club.example.com',
        isLocal: true,
        isAmbiguous: false,
        constraintText: '^1.2.3',
      );
      await store.replaceVersionDependencies('app', '1.0.0', [original]);

      expect(
        (await store.listVersionDependencies('app', '1.0.0')).single,
        original,
      );
    });

    test('keeps the same name in two sections as two rows', () async {
      final (:store, :db) = await _store();
      await _pkg(db, 'app');
      await _version(store, db, 'app', '1.0.0');

      await store.replaceVersionDependencies('app', '1.0.0', const [
        VersionDependency(
          name: 'shared',
          kind: DependencyKind.direct,
          source: DependencySource.hosted,
          isLocal: true,
        ),
        VersionDependency(
          name: 'shared',
          kind: DependencyKind.dev,
          source: DependencySource.hosted,
          isLocal: true,
        ),
      ]);

      expect(await store.listVersionDependencies('app', '1.0.0'), hasLength(2));
    });
  });
}

Future<int> _resolvable(ClubDatabase db, String pkg, String version) async {
  final rows = await db.select(
    'SELECT public_resolvable FROM package_versions '
    'WHERE package_name = ? AND version = ?',
    [pkg, version],
  );
  return rows.single.read<int>('public_resolvable');
}
