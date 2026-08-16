import 'package:club_core/club_core.dart';
import 'package:club_db/club_db.dart';
import 'package:test/test.dart';

/// End-to-end tests for VisibilityService against a real SQLite store.
///
/// They live in club_db rather than club_core because the service's whole
/// job is coordinating multi-row transactions and graph queries; a mock
/// store would test the mock. The scenarios here are the ones that decide
/// whether the feature is safe: the closure that must go public together,
/// the reverse check that stops a silent break, and the master switch.
Future<({SqliteMetadataStore store, VisibilityService service})> _setup({
  bool envEnabled = true,
  bool settingEnabled = true,
}) async {
  final db = await ClubDatabase.memory();
  addTearDown(db.close);
  final store = SqliteMetadataStore(db);
  await store.runMigrations();
  final settings = SqliteSettingsStore(db);

  // `packages.visibility_changed_by` is a real foreign key, so the actor
  // has to exist. Creating one here rather than relaxing the constraint:
  // an audit column pointing at a user id that was never a user is worse
  // than useless, it is misleading.
  await store.createUser(
    const UserCompanion(
      userId: 'u1',
      email: 'owner@example.com',
      passwordHash: 'x',
      displayName: 'Owner',
      role: UserRole.admin,
    ),
  );

  var counter = 0;
  final service = VisibilityService(
    store: store,
    settings: settings,
    generateId: () => 'id-${counter++}',
    envEnabled: envEnabled,
  );
  if (settingEnabled) await service.setEnabled(true);

  return (store: store, service: service);
}

Future<void> _pkg(
  SqliteMetadataStore store,
  String name, {
  List<String> deps = const [],
  List<String> devDeps = const [],
  List<String> bareAmbiguous = const [],
  String version = '1.0.0',
}) async {
  if (await store.lookupPackage(name) == null) {
    await store.createPackage(PackageCompanion(name: name));
  }
  await store.createVersion(
    PackageVersionCompanion(
      packageName: name,
      version: version,
      pubspecJson: '{}',
      libraries: const [],
      archiveSizeBytes: 1024,
      archiveSha256: 'sha-$name-$version',
    ),
  );
  await store.replaceVersionDependencies(name, version, [
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
      ),
    for (final d in bareAmbiguous)
      VersionDependency(
        name: d,
        kind: DependencyKind.direct,
        source: DependencySource.bare,
        isAmbiguous: true,
        constraintText: '^1.0.0',
      ),
  ]);
}

void main() {
  _reviewRegressions();

  group('master switch', () {
    test('apply is refused when the environment forbids it', () async {
      final (:store, :service) = await _setup(envEnabled: false);
      await _pkg(store, 'app');

      expect(await service.isEnabled(), isFalse);
      await expectLater(
        service.apply(
          package: 'app',
          target: PackageVisibility.public,
          closure: {'app'},
          actorUserId: 'u1',
        ),
        throwsA(isA<ForbiddenException>()),
      );
    });

    test('apply is refused when the setting is off', () async {
      final (:store, :service) = await _setup(settingEnabled: false);
      await _pkg(store, 'app');

      expect(await service.isEnabled(), isFalse);
      await expectLater(
        service.apply(
          package: 'app',
          target: PackageVisibility.public,
          closure: {'app'},
          actorUserId: 'u1',
        ),
        throwsA(isA<ForbiddenException>()),
      );
    });

    test('both halves are required', () async {
      final (store: _, service: envOff) = await _setup(envEnabled: false);
      await envOff.setEnabled(true);
      expect(
        await envOff.isEnabled(),
        isFalse,
        reason: 'the dashboard toggle alone must not open the server up',
      );
    });
  });

  group('preview: going public', () {
    test('selects the whole transitive closure by default', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'icons');
      await _pkg(store, 'core_ui', deps: ['icons']);
      await _pkg(store, 'app', deps: ['core_ui']);

      final preview = await service.preview(
        package: 'app',
        target: PackageVisibility.public,
      );

      expect(preview.selected, ['app', 'core_ui', 'icons']);
      expect(preview.closure.first.isTarget, isTrue);
      expect(preview.unresolvableVersions, isEmpty);
      expect(preview.isBlocked, isFalse);
    });

    test('reports version counts and bytes for each closure member',
        () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'app', version: '1.0.0');
      await _pkg(store, 'app', version: '2.0.0');

      final preview = await service.preview(
        package: 'app',
        target: PackageVisibility.public,
      );

      final node = preview.closure.single;
      expect(node.versionCount, 2);
      expect(node.totalBytes, 2048);
    });

    test('explains why a package is in the closure', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'icons');
      await _pkg(store, 'core_ui', deps: ['icons']);
      await _pkg(store, 'app', deps: ['core_ui']);

      final preview = await service.preview(
        package: 'app',
        target: PackageVisibility.public,
      );

      final icons =
          preview.closure.firstWhere((n) => n.package == 'icons');
      expect(icons.requiredBy, ['core_ui']);
    });

    test('lists dev-only packages separately and never selects them',
        () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'fixtures');
      await _pkg(store, 'test_helpers', deps: ['fixtures']);
      await _pkg(store, 'app', devDeps: ['test_helpers']);

      final preview = await service.preview(
        package: 'app',
        target: PackageVisibility.public,
      );

      expect(preview.selected, ['app']);
      expect(
        preview.devOnly.map((n) => n.package).toSet(),
        {'test_helpers', 'fixtures'},
      );
    });

    test('flags bare dependencies that collide with a local package',
        () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'provider');
      await _pkg(store, 'app', bareAmbiguous: ['provider']);

      final preview = await service.preview(
        package: 'app',
        target: PackageVisibility.public,
      );

      expect(preview.ambiguous, hasLength(1));
      expect(preview.ambiguous.single.dependency, 'provider');
      // Never silently pulled into the closure: an anonymous consumer
      // resolves pub.dev for a bare dep regardless, so exposing the local
      // package would buy nothing.
      expect(preview.selected, ['app']);
    });

    test('deselecting a dependency reports the versions it hides', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'core_ui');
      await _pkg(store, 'app', deps: ['core_ui'], version: '1.0.0');
      await _pkg(store, 'app', version: '2.0.0');

      final preview = await service.preview(
        package: 'app',
        target: PackageVisibility.public,
        selected: {'app'},
      );

      expect(preview.selected, ['app']);
      expect(preview.unresolvableVersions, hasLength(1));
      expect(preview.unresolvableVersions.single.version, '1.0.0');
      expect(preview.unresolvableVersions.single.blockedBy, ['core_ui']);
      expect(preview.isBlocked, isFalse, reason: '2.0.0 still resolves');
    });

    test('blocks when no version of the target could resolve', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'core_ui');
      await _pkg(store, 'app', deps: ['core_ui']);

      final preview = await service.preview(
        package: 'app',
        target: PackageVisibility.public,
        selected: {'app'},
      );

      expect(preview.isBlocked, isTrue);
      expect(preview.blockedReason, contains('No version of app'));
    });

    test('the target cannot be deselected out of its own change', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'app');

      final preview = await service.preview(
        package: 'app',
        target: PackageVisibility.public,
        selected: {},
      );

      expect(preview.selected, ['app']);
    });
  });

  group('apply: going public', () {
    test('flips the whole closure in one action', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'icons');
      await _pkg(store, 'core_ui', deps: ['icons']);
      await _pkg(store, 'app', deps: ['core_ui']);

      await service.apply(
        package: 'app',
        target: PackageVisibility.public,
        closure: {'app', 'core_ui', 'icons'},
        actorUserId: 'u1',
      );

      for (final name in ['app', 'core_ui', 'icons']) {
        expect((await store.lookupPackage(name))!.isPublic, isTrue);
      }
    });

    test('records who changed it and when', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'app');

      await service.apply(
        package: 'app',
        target: PackageVisibility.public,
        closure: {'app'},
        actorUserId: 'u1',
      );

      final pkg = (await store.lookupPackage('app'))!;
      expect(pkg.visibilityChangedBy, 'u1');
      expect(pkg.visibilityChangedAt, isNotNull);
    });

    test('writes an audit record naming the whole closure', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'core_ui');
      await _pkg(store, 'app', deps: ['core_ui']);

      await service.apply(
        package: 'app',
        target: PackageVisibility.public,
        closure: {'app', 'core_ui'},
        actorUserId: 'u1',
      );

      final log = await store.queryAuditLog(limit: 50);
      final made = log
          .where((r) => r.kind == AuditKind.packageMadePublic)
          .toList();
      expect(made.map((r) => r.packageName).toSet(), {'app', 'core_ui'});
      // Every entry carries the full set, so the log answers "what else
      // went public in this action" from any single row.
      for (final entry in made) {
        expect(entry.dataJson, contains('core_ui'));
        expect(entry.dataJson, contains('app'));
      }
    });

    test('marks resolvable versions after the flip', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'core_ui');
      await _pkg(store, 'app', deps: ['core_ui']);

      await service.apply(
        package: 'app',
        target: PackageVisibility.public,
        closure: {'app', 'core_ui'},
        actorUserId: 'u1',
      );

      final versions = await store.listVersions('app', scope: VisibilityScope.trustedInternal);
      expect(versions.single.publicResolvable, isTrue);
    });

    test('leaves a version unresolvable when its dependency stays private',
        () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'core_ui');
      await _pkg(store, 'app', deps: ['core_ui'], version: '1.0.0');
      await _pkg(store, 'app', version: '2.0.0');

      await service.apply(
        package: 'app',
        target: PackageVisibility.public,
        closure: {'app'},
        actorUserId: 'u1',
      );

      final versions = {
        for (final v in await store.listVersions('app', scope: VisibilityScope.trustedInternal))
          v.version: v.publicResolvable,
      };
      expect(versions['1.0.0'], isFalse);
      expect(versions['2.0.0'], isTrue);
    });

    test('refuses a selection where nothing could resolve', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'core_ui');
      await _pkg(store, 'app', deps: ['core_ui']);

      await expectLater(
        service.apply(
          package: 'app',
          target: PackageVisibility.public,
          closure: {'app'},
          actorUserId: 'u1',
        ),
        throwsA(isA<InvalidInputException>()),
      );
      expect((await store.lookupPackage('app'))!.isPublic, isFalse);
    });
  });

  group('apply: going private', () {
    test('refuses when a public package would break', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'icons');
      await _pkg(store, 'app', deps: ['icons']);
      await service.apply(
        package: 'app',
        target: PackageVisibility.public,
        closure: {'app', 'icons'},
        actorUserId: 'u1',
      );

      await expectLater(
        service.apply(
          package: 'icons',
          target: PackageVisibility.private,
          closure: {'icons'},
          actorUserId: 'u1',
        ),
        throwsA(
          isA<ConflictException>().having(
            (e) => e.message,
            'message',
            contains('app -> icons'),
          ),
        ),
      );
      expect((await store.lookupPackage('icons'))!.isPublic, isTrue);
    });

    test('proceeds when the dependent is included in the cascade', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'icons');
      await _pkg(store, 'app', deps: ['icons']);
      await service.apply(
        package: 'app',
        target: PackageVisibility.public,
        closure: {'app', 'icons'},
        actorUserId: 'u1',
      );

      await service.apply(
        package: 'app',
        target: PackageVisibility.private,
        closure: {'app', 'icons'},
        actorUserId: 'u1',
      );

      expect((await store.lookupPackage('app'))!.isPublic, isFalse);
      expect((await store.lookupPackage('icons'))!.isPublic, isFalse);
    });

    test('proceeds with explicit acceptance of the breakage', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'icons');
      await _pkg(store, 'app', deps: ['icons']);
      await service.apply(
        package: 'app',
        target: PackageVisibility.public,
        closure: {'app', 'icons'},
        actorUserId: 'u1',
      );

      await service.apply(
        package: 'icons',
        target: PackageVisibility.private,
        closure: {'icons'},
        actorUserId: 'u1',
        acceptBreakage: true,
      );

      expect((await store.lookupPackage('icons'))!.isPublic, isFalse);
      // `app` is still public but no longer resolvable, which is exactly
      // the state the operator was warned about and chose.
      expect((await store.lookupPackage('app'))!.isPublic, isTrue);
      expect(
        (await store.listVersions('app', scope: VisibilityScope.trustedInternal)).single.publicResolvable,
        isFalse,
      );
    });

    test('previewing a private change lists the public dependents',
        () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'icons');
      await _pkg(store, 'core_ui', deps: ['icons']);
      await _pkg(store, 'app', deps: ['core_ui']);
      await service.apply(
        package: 'app',
        target: PackageVisibility.public,
        closure: {'app', 'core_ui', 'icons'},
        actorUserId: 'u1',
      );

      final preview = await service.preview(
        package: 'icons',
        target: PackageVisibility.private,
      );

      expect(
        preview.publicDependents.map((d) => d.package),
        containsAll(['app', 'core_ui']),
      );
      final app =
          preview.publicDependents.firstWhere((d) => d.package == 'app');
      expect(app.path, ['app', 'core_ui', 'icons']);
    });
  });

  group('breakageFromRemoving', () {
    test('is the same check deletion needs', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'icons');
      await _pkg(store, 'app', deps: ['icons']);
      await service.apply(
        package: 'app',
        target: PackageVisibility.public,
        closure: {'app', 'icons'},
        actorUserId: 'u1',
      );

      final breakage = await service.breakageFromRemoving('icons');
      expect(breakage.map((d) => d.package), ['app']);
    });

    test('is empty when nothing public depends on it', () async {
      final (:store, :service) = await _setup();
      await _pkg(store, 'icons');
      await _pkg(store, 'app', deps: ['icons']);

      expect(await service.breakageFromRemoving('icons'), isEmpty);
    });
  });
}

/// Regressions from the security review.
void _reviewRegressions() {
  group('deleting a dependency does not leave dependents advertised', () {
    test('a removed package blocks its dependents on recompute', () async {
      // Before the fix, deleting `icons` left `app`'s versions with
      // public_resolvable = 1, so anonymous clients kept being offered a
      // version whose dependency no longer existed.
      final (:store, :service) = await _setup();
      await _pkg(store, 'icons');
      await _pkg(store, 'app', deps: ['icons']);
      await service.apply(
        package: 'app',
        target: PackageVisibility.public,
        closure: {'app', 'icons'},
        actorUserId: 'u1',
      );
      expect(
        (await store.listVersions('app',
                scope: VisibilityScope.trustedInternal))
            .single
            .publicResolvable,
        isTrue,
      );

      await store.deletePackage('icons');
      await store.recomputePublicResolvable(
        await store.packagesDependingOn({'icons'}),
      );

      expect(
        (await store.listVersions('app',
                scope: VisibilityScope.trustedInternal))
            .single
            .publicResolvable,
        isFalse,
        reason: 'the dependency row is gone, so the version cannot resolve',
      );
    });
  });

  group('a version with unknown dependencies is never resolvable', () {
    test('the backfill sentinel blocks public resolvability', () async {
      // Stands in for a version whose stored pubspec could not be parsed.
      // Recording no edges would have advertised it as resolvable.
      final (:store, :service) = await _setup();
      await _pkg(store, 'legacy_pkg');
      await store.replaceVersionDependencies('legacy_pkg', '1.0.0', const [
        VersionDependency(
          name: '!unindexed',
          kind: DependencyKind.direct,
          source: DependencySource.hosted,
          isLocal: true,
        ),
      ]);

      await store.updatePackage(
        'legacy_pkg',
        const PackageCompanion(
          name: 'legacy_pkg',
          visibility: PackageVisibility.public,
        ),
      );
      await store.recomputePublicResolvable({'legacy_pkg'});

      expect(
        (await store.listVersions('legacy_pkg',
                scope: VisibilityScope.trustedInternal))
            .single
            .publicResolvable,
        isFalse,
        reason:
            'unknown dependencies must block resolvability, not default to '
            '"no dependencies"',
      );
    });

    test('the sentinel can never collide with a real package name', () {
      expect(PackageNameValidator.isValid('!unindexed'), isFalse);
    });
  });
}
