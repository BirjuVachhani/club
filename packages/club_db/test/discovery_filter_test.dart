import 'package:club_core/club_core.dart';
import 'package:club_db/club_db.dart';
import 'package:test/test.dart';

/// What may appear in a discovery result, and what may not.
///
/// Three independent exclusions meet here and they are easy to conflate:
///
/// - `visibility` is access control. An anonymous caller must never see a
///   private package by any route.
/// - `is_unlisted` is an author preference: reachable by URL, never by
///   enumeration. It applies to signed-in users too.
/// - `is_discontinued` is a pub.dev listing hint, same shape as unlisted.
///
/// The regression that motivated most of this: keyword search and browse
/// disagreed about unlisted, so whether a package was hidden depended on
/// whether the visitor typed something into the box.
Future<({SqliteMetadataStore store, SqliteSearchIndex index})> _setup() async {
  final db = await ClubDatabase.memory();
  addTearDown(db.close);
  final store = SqliteMetadataStore(db);
  await store.runMigrations();
  final index = SqliteSearchIndex(db);
  await index.open();
  return (store: store, index: index);
}

Future<void> _pkg(
  SqliteMetadataStore store,
  SqliteSearchIndex index,
  String name, {
  PackageVisibility visibility = PackageVisibility.private,
  bool unlisted = false,
  bool discontinued = false,
}) async {
  await store.createPackage(PackageCompanion(name: name));
  if (unlisted || discontinued) {
    await store.updatePackage(
      name,
      PackageCompanion(
        name: name,
        isUnlisted: unlisted,
        isDiscontinued: discontinued,
      ),
    );
  }
  if (visibility.isPublic) {
    await store.updatePackage(
      name,
      PackageCompanion(name: name, visibility: visibility),
    );
  }
  await index.indexPackage(
    IndexDocument(
      package: name,
      latestVersion: '1.0.0',
      description: 'a $name package for searching',
      updatedAt: DateTime.now().toUtc(),
      publishedAt: DateTime.now().toUtc(),
    ),
  );
}

Future<List<String>> _search(
  SqliteSearchIndex index,
  String? query,
  VisibilityScope scope,
) async {
  final r = await index.search(SearchQuery(query: query), scope: scope);
  return r.hits.map((h) => h.package).toList()..sort();
}

void main() {
  group('anonymous search returns only public packages', () {
    test('keyword search', () async {
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'open_pkg', visibility: PackageVisibility.public);
      await _pkg(store, index, 'closed_pkg');

      expect(
        await _search(index, 'package', VisibilityScope.anonymous),
        ['open_pkg'],
      );
    });

    test('browse (empty query)', () async {
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'open_pkg', visibility: PackageVisibility.public);
      await _pkg(store, index, 'closed_pkg');

      expect(
        await _search(index, null, VisibilityScope.anonymous),
        ['open_pkg'],
      );
    });

    test('searching a private package by its exact name finds nothing',
        () async {
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'closed_pkg');

      expect(
        await _search(index, 'closed_pkg', VisibilityScope.anonymous),
        isEmpty,
      );
    });

    test('the total count does not leak private matches', () async {
      // Filtering the page but not the count would still confirm that a
      // guessed private name exists.
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'open_pkg', visibility: PackageVisibility.public);
      await _pkg(store, index, 'closed_pkg');

      final r = await index.search(
        const SearchQuery(query: 'package'),
        scope: VisibilityScope.anonymous,
      );
      expect(r.totalHits, 1);
    });

    test('an authenticated scope still sees everything', () async {
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'open_pkg', visibility: PackageVisibility.public);
      await _pkg(store, index, 'closed_pkg');

      expect(
        await _search(index, 'package', VisibilityScope.trustedInternal),
        ['closed_pkg', 'open_pkg'],
      );
    });
  });

  group('unlisted packages are findable by URL only', () {
    test('excluded from keyword search', () async {
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'listed_pkg');
      await _pkg(store, index, 'hidden_pkg', unlisted: true);

      expect(
        await _search(index, 'package', VisibilityScope.trustedInternal),
        ['listed_pkg'],
      );
    });

    test('excluded even when searched by exact name', () async {
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'hidden_pkg', unlisted: true);

      expect(
        await _search(index, 'hidden_pkg', VisibilityScope.trustedInternal),
        isEmpty,
      );
    });

    test('excluded from browse', () async {
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'listed_pkg');
      await _pkg(store, index, 'hidden_pkg', unlisted: true);

      expect(
        await _search(index, null, VisibilityScope.trustedInternal),
        ['listed_pkg'],
      );
    });

    test('excluded for signed-in users too, not just anonymous ones', () async {
      // Unlisted is an author preference about listing, not access
      // control. It applies uniformly.
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'hidden_pkg', unlisted: true);

      for (final scope in [
        VisibilityScope.anonymous,
        VisibilityScope.trustedInternal,
        VisibilityScope.authenticated('u1'),
      ]) {
        expect(
          await _search(index, 'package', scope),
          isEmpty,
          reason: 'unlisted must be hidden from discovery under $scope',
        );
      }
    });

    test('excluded from autocomplete and browse listings', () async {
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'listed_pkg');
      await _pkg(store, index, 'hidden_pkg', unlisted: true);

      final discovery = await store.listPackages(
        scope: VisibilityScope.trustedInternal,
        includeUnlisted: false,
      );
      expect(discovery.items.map((p) => p.name), ['listed_pkg']);
      expect(discovery.totalCount, 1);
    });

    test('still visible to admin listings that ask for everything', () async {
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'listed_pkg');
      await _pkg(store, index, 'hidden_pkg', unlisted: true);

      final all = await store.listPackages(
        scope: VisibilityScope.trustedInternal,
      );
      expect(
        all.items.map((p) => p.name).toList()..sort(),
        ['hidden_pkg', 'listed_pkg'],
      );
    });

    test('still reachable by direct lookup, which is the whole point',
        () async {
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'hidden_pkg', unlisted: true);

      final pkg = await store.lookupPackage('hidden_pkg');
      expect(pkg, isNotNull);
      expect(pkg!.isUnlisted, isTrue);
    });

    test('a public unlisted package is still hidden from discovery', () async {
      // The two flags compose: public decides who may read it, unlisted
      // decides whether it is advertised. Public plus unlisted resolves
      // for `dart pub get` but is absent from search.
      final (:store, :index) = await _setup();
      await _pkg(
        store,
        index,
        'quiet_pkg',
        visibility: PackageVisibility.public,
        unlisted: true,
      );

      expect(await _search(index, 'package', VisibilityScope.anonymous), isEmpty);
      expect((await store.lookupPackage('quiet_pkg'))!.isPublic, isTrue);
    });
  });

  group('discontinued packages', () {
    test('are excluded from search and browse, as before', () async {
      final (:store, :index) = await _setup();
      await _pkg(store, index, 'live_pkg');
      await _pkg(store, index, 'dead_pkg', discontinued: true);

      expect(
        await _search(index, 'package', VisibilityScope.trustedInternal),
        ['live_pkg'],
      );
      expect(
        await _search(index, null, VisibilityScope.trustedInternal),
        ['live_pkg'],
      );
    });
  });
}
