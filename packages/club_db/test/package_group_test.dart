import 'package:club_core/club_core.dart';
import 'package:club_db/club_db.dart';
import 'package:test/test.dart';

void main() {
  late ClubDatabase database;
  late SqliteMetadataStore store;

  setUp(() async {
    database = await ClubDatabase.memory();
    store = SqliteMetadataStore(database);
    await store.runMigrations();
    await store.createUser(
      const UserCompanion(
        userId: 'owner',
        email: 'owner@example.test',
        passwordHash: 'hash',
        displayName: 'Owner',
        role: UserRole.owner,
      ),
    );
    await store.createPackage(
      const PackageCompanion(name: 'payments'),
    );
    await store.createPackage(
      const PackageCompanion(name: 'paddle'),
    );
  });

  tearDown(() => database.close());

  test('stores many-to-many package membership in manual order', () async {
    final group = await store.createPackageGroup(
      const PackageGroupCompanion(
        id: 'payments-group',
        slug: 'payments',
        name: 'Payments',
        ownerUserId: 'owner',
        createdBy: 'owner',
      ),
    );

    await store.addPackageToGroup(group.id, 'payments', addedBy: 'owner');
    await store.addPackageToGroup(group.id, 'paddle', addedBy: 'owner');
    await store.reorderPackageGroup(group.id, ['paddle', 'payments']);

    final memberships = await store.listPackageGroupMemberships(group.id);
    expect(memberships.map((m) => m.packageName).toList(), [
      'paddle',
      'payments',
    ]);
    final reverse = await store.listPackageGroupsForPackage('payments');
    expect(reverse.single.id, group.id);
  });

  test('anonymous group listing hides private-only groups', () async {
    await store.createPackageGroup(
      const PackageGroupCompanion(
        id: 'private-group',
        slug: 'private-group',
        name: 'Private Group',
        ownerUserId: 'owner',
        createdBy: 'owner',
      ),
    );
    await store.addPackageToGroup(
      'private-group',
      'payments',
      addedBy: 'owner',
    );

    final groups = await store.listPackageGroups(
      scope: VisibilityScope.anonymous,
    );
    expect(groups.items, isEmpty);
  });

  test('group name search returns the group and its member packages', () async {
    final group = await store.createPackageGroup(
      const PackageGroupCompanion(
        id: 'searchable',
        slug: 'payment-tools',
        name: 'Payment Tools',
        ownerUserId: 'owner',
        createdBy: 'owner',
      ),
    );
    await store.addPackageToGroup(group.id, 'payments', addedBy: 'owner');
    final index = SqliteSearchIndex(database);
    await index.indexPackageGroup(PackageGroupIndexDocument.fromGroup(group));

    final result = await index.search(
      const SearchQuery(query: 'Payment'),
      scope: VisibilityScope.authenticated('owner'),
    );

    expect(
      result.hits.map((hit) => '${hit.type.name}:${hit.identifier}'),
      containsAll(['package:payments', 'packageGroup:searchable']),
    );
  });

  test('package deletion removes membership without deleting group', () async {
    await store.createPackageGroup(
      const PackageGroupCompanion(
        id: 'survives',
        slug: 'survives',
        name: 'Survives',
        ownerUserId: 'owner',
        createdBy: 'owner',
      ),
    );
    await store.addPackageToGroup('survives', 'paddle', addedBy: 'owner');
    await store.deletePackage('paddle');

    expect(await store.lookupPackageGroup('survives'), isNotNull);
    expect(await store.listPackageGroupMemberships('survives'), isEmpty);
  });
}
