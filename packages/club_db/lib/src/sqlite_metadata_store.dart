import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:club_core/club_core.dart';

import 'database.dart';

/// SQLite implementation of [MetadataStore] using raw SQL via drift.
class SqliteMetadataStore implements MetadataStore {
  SqliteMetadataStore(this._db);

  final ClubDatabase _db;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> open() async {
    // Database is already opened by ClubDatabase.open().
  }

  @override
  Future<void> close() => _db.close();

  @override
  Future<void> runMigrations() => _db.runMigrations();

  // ── Packages ───────────────────────────────────────────────────────────────

  @override
  Future<Package?> lookupPackage(String name) async {
    final rows = await _db.select(
      'SELECT * FROM packages WHERE name = ?',
      [name],
    );
    if (rows.isEmpty) return null;
    return _rowToPackage(rows.first);
  }

  @override
  Future<Package> createPackage(PackageCompanion companion) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    // Visibility is deliberately not accepted here. A package is born
    // private, always: `PublishService.finalize` creates new packages with
    // a bare companion, and letting that path choose a visibility would
    // mean a publish could put source on the internet with no closure
    // analysis, no confirmation, and no audit record. Going public is
    // `VisibilityService`'s job and nothing else's.
    await _db.execute(
      '''INSERT INTO packages
         (name, publisher_id, latest_version, latest_prerelease,
          likes_count, is_discontinued, replaced_by, is_unlisted,
          visibility, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        companion.name,
        companion.publisherId,
        companion.latestVersion,
        companion.latestPrerelease,
        companion.likesCount ?? 0,
        _boolToInt(companion.isDiscontinued ?? false),
        companion.replacedBy,
        _boolToInt(companion.isUnlisted ?? false),
        PackageVisibility.private.wireName,
        now,
        now,
      ],
    );
    return (await lookupPackage(companion.name))!;
  }

  @override
  Future<Package> updatePackage(String name, PackageCompanion companion) async {
    final existing = await lookupPackage(name);
    if (existing == null) throw NotFoundException.package(name);

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    // Visibility null-coalesces like every other field, so a companion
    // that does not mention it leaves the package where it was. That is
    // what makes republish safe: `finalize` updates latest_version with a
    // companion that says nothing about visibility, and a public package
    // stays public rather than being silently reset.
    await _db.execute(
      '''UPDATE packages SET
           publisher_id = ?, latest_version = ?, latest_prerelease = ?,
           likes_count = ?, is_discontinued = ?, replaced_by = ?,
           is_unlisted = ?, visibility = ?, visibility_changed_at = ?,
           visibility_changed_by = ?, updated_at = ?
         WHERE name = ?''',
      [
        companion.publisherId ?? existing.publisherId,
        companion.latestVersion ?? existing.latestVersion,
        companion.latestPrerelease ?? existing.latestPrerelease,
        companion.likesCount ?? existing.likesCount,
        _boolToInt(companion.isDiscontinued ?? existing.isDiscontinued),
        companion.replacedBy ?? existing.replacedBy,
        _boolToInt(companion.isUnlisted ?? existing.isUnlisted),
        (companion.visibility ?? existing.visibility).wireName,
        _dateTimeToNullableInt(
          companion.visibilityChangedAt ?? existing.visibilityChangedAt,
        ),
        companion.visibilityChangedBy ?? existing.visibilityChangedBy,
        now,
        name,
      ],
    );
    return (await lookupPackage(name))!;
  }

  @override
  Future<void> deletePackage(String name) async {
    await _db.execute('DELETE FROM packages WHERE name = ?', [name]);
  }

  @override
  Future<Page<Package>> listPackages({
    required VisibilityScope scope,
    int limit = 50,
    String? pageToken,
    String? query,
    bool includeUnlisted = true,
  }) async {
    final offset = int.tryParse(pageToken ?? '') ?? 0;
    final where = <String>[];
    final args = <Object?>[];
    if (!includeUnlisted) {
      where.add('is_unlisted = 0');
    }
    // The visibility predicate goes in first so it is also picked up by
    // the COUNT(*) below, which reuses this arg list minus the trailing
    // limit/offset pair. A filter applied to only one of the two would
    // leak the private package count through `totalCount` even while the
    // page itself looked clean.
    if (scope.publicOnly) {
      where.add('visibility = ?');
      args.add(PackageVisibility.public.wireName);
    }
    if (query != null && query.trim().isNotEmpty) {
      where.add('name LIKE ?');
      args.add('%${query.trim()}%');
    }
    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    args.addAll([limit + 1, offset]);
    final rows = await _db.select(
      'SELECT * FROM packages $whereClause ORDER BY updated_at DESC LIMIT ? OFFSET ?',
      args,
    );
    final hasMore = rows.length > limit;
    final items = rows.take(limit).map(_rowToPackage).toList();

    final totalRows = await _db.select(
      'SELECT COUNT(*) AS n FROM packages $whereClause',
      args.sublist(0, args.length - 2),
    );
    final total = totalRows.first.read<int>('n');

    return Page(
      items: items,
      nextPageToken: hasMore ? '${offset + limit}' : null,
      totalCount: total,
    );
  }

  @override
  Future<bool> hasAnyPublicPackage() async {
    final rows = await _db.select(
      'SELECT 1 FROM packages WHERE visibility = ? LIMIT 1',
      [PackageVisibility.public.wireName],
    );
    return rows.isNotEmpty;
  }

  @override
  Future<Page<Package>> listPackagesForUser(
    String userId, {
    int limit = 50,
    String? pageToken,
    String? query,
  }) async {
    // Any package where the user is a direct uploader OR a member of the
    // owning publisher. Union-deduped on package name.
    final offset = int.tryParse(pageToken ?? '') ?? 0;
    final args = <Object?>[userId, userId];
    final filter = (query != null && query.trim().isNotEmpty)
        ? 'AND p.name LIKE ?'
        : '';
    if (filter.isNotEmpty) args.add('%${query!.trim()}%');

    final baseSql = '''SELECT DISTINCT p.*
           FROM packages p
           LEFT JOIN package_uploaders u ON u.package_name = p.name
           LEFT JOIN publisher_members m ON m.publisher_id = p.publisher_id
           WHERE (u.user_id = ? OR m.user_id = ?) $filter''';

    args.add(limit + 1);
    args.add(offset);
    final rows = await _db.select(
      '$baseSql ORDER BY p.updated_at DESC LIMIT ? OFFSET ?',
      args,
    );
    final hasMore = rows.length > limit;
    final items = rows.take(limit).map(_rowToPackage).toList();

    // Total count (without limit/offset).
    final countArgs = args.sublist(0, args.length - 2);
    final totalRows = await _db.select(
      'SELECT COUNT(*) AS n FROM ($baseSql) t',
      countArgs,
    );
    final total = totalRows.first.read<int>('n');

    return Page(
      items: items,
      nextPageToken: hasMore ? '${offset + limit}' : null,
      totalCount: total,
    );
  }

  @override
  Future<Page<Package>> listPackagesForPublisher(
    String publisherId, {
    required VisibilityScope scope,
    int limit = 50,
    String? pageToken,
    bool includeUnlisted = true,
  }) async {
    final offset = int.tryParse(pageToken ?? '') ?? 0;
    final unlistedFilter = includeUnlisted ? '' : 'AND is_unlisted = 0';
    final visibilityFilter = scope.publicOnly ? 'AND visibility = ?' : '';
    final visibilityArgs = scope.publicOnly
        ? [PackageVisibility.public.wireName]
        : const <Object?>[];

    final rows = await _db.select(
      '''SELECT * FROM packages
         WHERE publisher_id = ? $unlistedFilter $visibilityFilter
         ORDER BY updated_at DESC LIMIT ? OFFSET ?''',
      [publisherId, ...visibilityArgs, limit + 1, offset],
    );
    final hasMore = rows.length > limit;
    final items = rows.take(limit).map(_rowToPackage).toList();

    final totalRows = await _db.select(
      'SELECT COUNT(*) AS n FROM packages '
      'WHERE publisher_id = ? $unlistedFilter $visibilityFilter',
      [publisherId, ...visibilityArgs],
    );
    final total = totalRows.first.read<int>('n');

    return Page(
      items: items,
      nextPageToken: hasMore ? '${offset + limit}' : null,
      totalCount: total,
    );
  }

  // ── Package Versions ───────────────────────────────────────────────────────

  @override
  Future<PackageVersion?> lookupVersion(String package, String version) async {
    final rows = await _db.select(
      'SELECT * FROM package_versions WHERE package_name = ? AND version = ?',
      [package, version],
    );
    if (rows.isEmpty) return null;
    return _rowToVersion(rows.first);
  }

  @override
  Future<PackageVersion> createVersion(
    PackageVersionCompanion companion,
  ) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''INSERT INTO package_versions
         (package_name, version, pubspec_json, readme_content,
          changelog_content, example_content, example_path,
          libraries, bin_executables, screenshots,
          archive_size_bytes, archive_sha256,
          uploader_id, publisher_id, is_retracted, retracted_at,
          is_prerelease, dart_sdk_min, dart_sdk_max,
          flutter_sdk_min, flutter_sdk_max, tags, published_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        companion.packageName,
        companion.version,
        companion.pubspecJson,
        companion.readmeContent,
        companion.changelogContent,
        companion.exampleContent,
        companion.examplePath,
        jsonEncode(companion.libraries),
        jsonEncode(companion.binExecutables),
        jsonEncode(companion.screenshots.map((s) => s.toJson()).toList()),
        companion.archiveSizeBytes,
        companion.archiveSha256,
        companion.uploaderId,
        companion.publisherId,
        0, // is_retracted
        null, // retracted_at
        _boolToInt(companion.isPrerelease),
        companion.dartSdkMin,
        companion.dartSdkMax,
        companion.flutterSdkMin,
        companion.flutterSdkMax,
        jsonEncode(companion.tags),
        now,
      ],
    );
    return (await lookupVersion(companion.packageName, companion.version))!;
  }

  @override
  Future<PackageVersion> updateVersion(
    String package,
    String version,
    PackageVersionCompanion companion,
  ) async {
    final existing = await lookupVersion(package, version);
    if (existing == null) throw NotFoundException.version(package, version);

    await _db.execute(
      '''UPDATE package_versions SET
           pubspec_json = ?, readme_content = ?, changelog_content = ?,
           example_content = ?, example_path = ?,
           libraries = ?, bin_executables = ?, screenshots = ?,
           archive_size_bytes = ?, archive_sha256 = ?,
           uploader_id = ?, publisher_id = ?,
           is_retracted = ?, retracted_at = ?,
           is_prerelease = ?, dart_sdk_min = ?, dart_sdk_max = ?,
           flutter_sdk_min = ?, flutter_sdk_max = ?,
           tags = ?
         WHERE package_name = ? AND version = ?''',
      [
        companion.pubspecJson,
        companion.readmeContent ?? existing.readmeContent,
        companion.changelogContent ?? existing.changelogContent,
        companion.exampleContent ?? existing.exampleContent,
        companion.examplePath ?? existing.examplePath,
        jsonEncode(companion.libraries),
        jsonEncode(companion.binExecutables),
        jsonEncode(
          (companion.screenshots.isNotEmpty
                  ? companion.screenshots
                  : existing.screenshots)
              .map((s) => s.toJson())
              .toList(),
        ),
        companion.archiveSizeBytes,
        companion.archiveSha256,
        companion.uploaderId ?? existing.uploaderId,
        companion.publisherId ?? existing.publisherId,
        _boolToInt(companion.isRetracted ?? existing.isRetracted),
        (companion.retractedAt ?? existing.retractedAt)?.millisecondsSinceEpoch,
        _boolToInt(companion.isPrerelease),
        companion.dartSdkMin ?? existing.dartSdkMin,
        companion.dartSdkMax ?? existing.dartSdkMax,
        companion.flutterSdkMin ?? existing.flutterSdkMin,
        companion.flutterSdkMax ?? existing.flutterSdkMax,
        jsonEncode(
          companion.tags.isNotEmpty ? companion.tags : existing.tags,
        ),
        package,
        version,
      ],
    );
    return (await lookupVersion(package, version))!;
  }

  @override
  Future<void> deleteVersion(String package, String version) async {
    await _db.transaction(() async {
      await _db.execute(
        'DELETE FROM package_versions WHERE package_name = ? AND version = ?',
        [package, version],
      );

      // Recompute the package's latest pointers from the surviving rows.
      // Without this, `packages.latest_version` still points at the row
      // we just removed, and any caller resolving content/score by
      // "latest" hits a 404. Mirrors the recompute in
      // PublishService.finalize, but writes via raw SQL so NULL is
      // preserved when no versions remain (updatePackage's
      // null-coalesce fallback would otherwise keep the stale pointer).
      final remaining = (await listVersions(
        package,
        scope: VisibilityScope.trustedInternal,
      ))
          .where((v) => !v.isRetracted)
          .map((v) => v.version)
          .toList();

      final latestStable = VersionValidator.latestStable(remaining);
      final latestAny = VersionValidator.latestAny(remaining);
      final newLatest = latestStable ?? latestAny;
      final newPrerelease = latestAny != latestStable ? latestAny : null;

      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      await _db.execute(
        '''UPDATE packages
             SET latest_version = ?, latest_prerelease = ?, updated_at = ?
           WHERE name = ?''',
        [newLatest, newPrerelease, now, package],
      );
    });
  }

  // ── Version Dependencies ──────────────────────────────────────────────────

  @override
  Future<void> replaceVersionDependencies(
    String package,
    String version,
    List<VersionDependency> dependencies,
  ) async {
    // No transaction here on purpose. `MetadataStore.transaction` hands
    // back this same store rather than a scoped connection, so opening one
    // would nest the caller's transaction. Callers (publish, backfill)
    // already run inside one.
    await _db.execute(
      'DELETE FROM package_version_dependencies '
      'WHERE package_name = ? AND version = ?',
      [package, version],
    );

    for (final dep in dependencies) {
      await _db.execute(
        '''INSERT OR REPLACE INTO package_version_dependencies
             (package_name, version, dep_name, kind, source, hosted_origin,
              is_local, is_ambiguous, constraint_text)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          package,
          version,
          dep.name,
          dep.kind.wireName,
          dep.source.wireName,
          dep.hostedOrigin,
          _boolToInt(dep.isLocal),
          _boolToInt(dep.isAmbiguous),
          dep.constraintText,
        ],
      );
    }
  }

  @override
  Future<List<VersionDependency>> listVersionDependencies(
    String package,
    String version,
  ) async {
    final rows = await _db.select(
      'SELECT * FROM package_version_dependencies '
      'WHERE package_name = ? AND version = ? ORDER BY kind, dep_name',
      [package, version],
    );
    return rows.map(_rowToVersionDependency).toList();
  }

  @override
  Future<Set<String>> localDependencyClosure(
    Set<String> roots, {
    bool includeDev = false,
  }) async {
    // Breadth-first over package *names*. Keying the visited set on the
    // name rather than on (name, version) is what makes this terminate:
    // `pub` permits cycles between packages, and the name set is finite
    // while the version pairs are not usefully bounded.
    //
    // The frontier is expanded from every version of each package, not
    // just the latest. A consumer's constraint may select any version, and
    // `pub` aborts on a 401 rather than backtracking, so a closure built
    // from the newest version alone would still break resolution as soon
    // as the solver probed an older one.
    final kinds = includeDev
        ? [DependencyKind.direct.wireName, DependencyKind.dev.wireName]
        : [DependencyKind.direct.wireName];

    final visited = <String>{...roots};
    final frontier = <String>[...roots];

    while (frontier.isNotEmpty) {
      final batch = frontier.toList();
      frontier.clear();

      final placeholders = List.filled(batch.length, '?').join(',');
      final kindPlaceholders = List.filled(kinds.length, '?').join(',');
      final rows = await _db.select(
        'SELECT DISTINCT dep_name FROM package_version_dependencies '
        'WHERE package_name IN ($placeholders) '
        '  AND kind IN ($kindPlaceholders) '
        '  AND is_local = 1',
        [...batch, ...kinds],
      );

      for (final row in rows) {
        final dep = row.read<String>('dep_name');
        if (visited.add(dep)) frontier.add(dep);
      }
    }

    return visited;
  }

  @override
  Future<Set<String>> localDependentsClosure(Set<String> roots) async {
    final visited = <String>{...roots};
    final frontier = <String>[...roots];

    while (frontier.isNotEmpty) {
      final batch = frontier.toList();
      frontier.clear();

      final placeholders = List.filled(batch.length, '?').join(',');
      final rows = await _db.select(
        'SELECT DISTINCT package_name FROM package_version_dependencies '
        'WHERE dep_name IN ($placeholders) '
        '  AND kind = ? '
        '  AND is_local = 1',
        [...batch, DependencyKind.direct.wireName],
      );

      for (final row in rows) {
        final pkg = row.read<String>('package_name');
        if (visited.add(pkg)) frontier.add(pkg);
      }
    }

    return visited;
  }

  @override
  Future<List<DependentPath>> findPublicDependents(String package) =>
      findPublicDependentsOfAny({package});

  @override
  Future<List<DependentPath>> findPublicDependentsOfAny(
    Set<String> packages,
  ) async {
    if (packages.isEmpty) return const [];

    // Reverse breadth-first search, recording one predecessor per package
    // so a concrete example chain can be reconstructed. One path per
    // dependent is enough to explain the breakage; enumerating all of them
    // is exponential in a dense graph and no more persuasive.
    //
    // Seeded with every root at once rather than run once per root: a
    // dependent reachable from two roots is reported once, and the walk
    // stays a single pass over the reverse edges.
    final cameFrom = <String, String>{};
    final visited = <String>{...packages};
    final frontier = <String>[...packages];

    while (frontier.isNotEmpty) {
      final batch = frontier.toList();
      frontier.clear();

      final placeholders = List.filled(batch.length, '?').join(',');
      final rows = await _db.select(
        'SELECT DISTINCT d.package_name, d.dep_name '
        'FROM package_version_dependencies d '
        'WHERE d.dep_name IN ($placeholders) '
        '  AND d.kind = ? '
        '  AND d.is_local = 1',
        [...batch, DependencyKind.direct.wireName],
      );

      for (final row in rows) {
        final dependent = row.read<String>('package_name');
        if (visited.add(dependent)) {
          cameFrom[dependent] = row.read<String>('dep_name');
          frontier.add(dependent);
        }
      }
    }

    visited.removeAll(packages);
    if (visited.isEmpty) return const [];

    // Of everything that depends on it, only the public ones are a
    // problem: a private dependent was already unreachable anonymously.
    final placeholders = List.filled(visited.length, '?').join(',');
    final publicRows = await _db.select(
      'SELECT name FROM packages '
      'WHERE name IN ($placeholders) AND visibility = ?',
      [...visited, PackageVisibility.public.wireName],
    );

    final result = <DependentPath>[];
    for (final row in publicRows) {
      final dependent = row.read<String>('name');
      final path = <String>[dependent];
      var cursor = dependent;
      // Bounded by `visited`, and every step moves to a package inserted
      // strictly earlier in the BFS, so this cannot loop.
      while (cameFrom[cursor] != null && path.length <= visited.length + 1) {
        cursor = cameFrom[cursor]!;
        path.add(cursor);
      }
      result.add(DependentPath(package: dependent, path: path));
    }

    result.sort((a, b) => a.package.compareTo(b.package));
    return result;
  }

  @override
  Future<Set<String>> packagesDependingOn(Set<String> names) async {
    if (names.isEmpty) return {};
    final placeholders = List.filled(names.length, '?').join(',');
    final rows = await _db.select(
      'SELECT DISTINCT package_name FROM package_version_dependencies '
      'WHERE dep_name IN ($placeholders) AND kind = ? AND is_local = 1',
      [...names, DependencyKind.direct.wireName],
    );
    return rows.map((r) => r.read<String>('package_name')).toSet();
  }

  @override
  Future<int> recomputePublicResolvable(Set<String> packages) async {
    if (packages.isEmpty) return 0;
    final placeholders = List.filled(packages.length, '?').join(',');

    // A version is resolvable when its own package is public AND it has no
    // direct club-hosted dependency on a package that is not public.
    //
    // The NOT EXISTS deliberately treats a dependency with no matching
    // `packages` row as unresolvable: an edge pointing at a package that
    // no longer exists cannot resolve for anyone, and defaulting it to
    // "fine" would advertise a version that always 404s.
    final result = await _db.select(
      '''
      SELECT pv.package_name, pv.version, pv.public_resolvable AS was,
             CASE
               WHEN p.visibility != ? THEN 0
               WHEN EXISTS (
                 SELECT 1
                 FROM package_version_dependencies d
                 LEFT JOIN packages dp ON dp.name = d.dep_name
                 WHERE d.package_name = pv.package_name
                   AND d.version = pv.version
                   AND d.kind = ?
                   AND d.is_local = 1
                   AND (dp.name IS NULL OR dp.visibility != ?)
               ) THEN 0
               ELSE 1
             END AS now
      FROM package_versions pv
      JOIN packages p ON p.name = pv.package_name
      WHERE pv.package_name IN ($placeholders)
      ''',
      [
        PackageVisibility.public.wireName,
        DependencyKind.direct.wireName,
        PackageVisibility.public.wireName,
        ...packages,
      ],
    );

    var changed = 0;
    for (final row in result) {
      final was = row.read<int>('was');
      final now = row.read<int>('now');
      if (was == now) continue;
      await _db.execute(
        'UPDATE package_versions SET public_resolvable = ? '
        'WHERE package_name = ? AND version = ?',
        [now, row.read<String>('package_name'), row.read<String>('version')],
      );
      changed++;
    }
    return changed;
  }

  @override
  Future<List<PackageVersion>> listVersions(
    String package, {
    required VisibilityScope scope,
  }) async {
    // Anonymous callers see only versions that can actually resolve
    // without credentials. This list is the input to a `pub` version
    // solve, and pub aborts on a 401 rather than backtracking, so
    // advertising a version whose club-hosted dependency is private would
    // poison the whole resolution rather than merely fail that one
    // candidate.
    final filter = scope.publicOnly ? 'AND public_resolvable = 1' : '';
    final rows = await _db.select(
      'SELECT * FROM package_versions WHERE package_name = ? $filter '
      'ORDER BY published_at DESC',
      [package],
    );
    return rows.map(_rowToVersion).toList();
  }

  // ── Users ──────────────────────────────────────────────────────────────────

  @override
  Future<User?> lookupUserById(String userId) async {
    final rows = await _db.select(
      'SELECT * FROM users WHERE user_id = ?',
      [userId],
    );
    if (rows.isEmpty) return null;
    return _rowToUser(rows.first);
  }

  @override
  Future<User?> lookupUserByEmail(String email) async {
    final rows = await _db.select(
      'SELECT * FROM users WHERE email = ?',
      [email],
    );
    if (rows.isEmpty) return null;
    return _rowToUser(rows.first);
  }

  @override
  Future<User> createUser(UserCompanion companion) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''INSERT INTO users
         (user_id, email, password_hash, display_name, role, is_active,
          must_change_password, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        companion.userId,
        companion.email,
        companion.passwordHash,
        companion.displayName,
        companion.role.name,
        _boolToInt(companion.isActive),
        _boolToInt(companion.mustChangePassword),
        now,
        now,
      ],
    );
    return (await lookupUserById(companion.userId))!;
  }

  @override
  Future<User> updateUser(String userId, UserCompanion companion) async {
    final existing = await lookupUserById(userId);
    if (existing == null) throw NotFoundException.user(userId);

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    // Treat empty passwordHash as "don't change" so the admin update path
    // can leave the password untouched while changing role/is_active/etc.
    final nextHash = companion.passwordHash.isEmpty
        ? (await lookupPasswordHash(userId) ?? '')
        : companion.passwordHash;
    await _db.execute(
      '''UPDATE users SET
           email = ?, password_hash = ?, display_name = ?,
           role = ?, is_active = ?, must_change_password = ?,
           updated_at = ?
         WHERE user_id = ?''',
      [
        companion.email,
        nextHash,
        companion.displayName,
        companion.role.name,
        _boolToInt(companion.isActive),
        _boolToInt(companion.mustChangePassword),
        now,
        userId,
      ],
    );
    return (await lookupUserById(userId))!;
  }

  @override
  Future<void> deleteUser(String userId) async {
    await _db.execute('DELETE FROM users WHERE user_id = ?', [userId]);
  }

  // ── User invites ────────────────────────────────────────────

  @override
  Future<UserInvite> createInvite(UserInviteCompanion companion) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''INSERT INTO user_invites
         (invite_id, user_id, token_hash, expires_at, created_by, created_at)
         VALUES (?, ?, ?, ?, ?, ?)''',
      [
        companion.inviteId,
        companion.userId,
        companion.tokenHash,
        companion.expiresAt.millisecondsSinceEpoch,
        companion.createdBy,
        now,
      ],
    );
    return (await lookupInviteByHash(companion.tokenHash))!;
  }

  @override
  Future<UserInvite?> lookupInviteByHash(String tokenHash) async {
    final rows = await _db.select(
      '''SELECT invite_id, user_id, token_hash, expires_at,
                used_at, created_by, created_at
         FROM user_invites WHERE token_hash = ?''',
      [tokenHash],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return UserInvite(
      inviteId: row.read<String>('invite_id'),
      userId: row.read<String>('user_id'),
      tokenHash: row.read<String>('token_hash'),
      expiresAt: _intToDateTime(row.read<int>('expires_at')),
      usedAt: _nullableIntToDateTime(row.readNullable<int>('used_at')),
      createdBy: row.readNullable<String>('created_by'),
      createdAt: _intToDateTime(row.read<int>('created_at')),
    );
  }

  @override
  Future<void> markInviteUsed(String inviteId) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      'UPDATE user_invites SET used_at = ? WHERE invite_id = ?',
      [now, inviteId],
    );
  }

  @override
  Future<Page<User>> listUsers({
    int limit = 50,
    String? pageToken,
    String? emailFilter,
  }) async {
    final offset = int.tryParse(pageToken ?? '') ?? 0;

    String sql;
    List<Object?> args;
    if (emailFilter != null) {
      sql =
          'SELECT * FROM users WHERE email LIKE ? ORDER BY created_at DESC LIMIT ? OFFSET ?';
      args = ['%$emailFilter%', limit + 1, offset];
    } else {
      sql = 'SELECT * FROM users ORDER BY created_at DESC LIMIT ? OFFSET ?';
      args = [limit + 1, offset];
    }

    final rows = await _db.select(sql, args);
    final hasMore = rows.length > limit;
    final items = rows.take(limit).map(_rowToUser).toList();
    return Page(
      items: items,
      nextPageToken: hasMore ? '${offset + limit}' : null,
    );
  }

  @override
  Future<String?> lookupPasswordHash(String userId) async {
    final rows = await _db.select(
      'SELECT password_hash FROM users WHERE user_id = ?',
      [userId],
    );
    if (rows.isEmpty) return null;
    return rows.first.read<String>('password_hash');
  }

  @override
  Future<String?> getAvatar(String userId) async {
    final rows = await _db.select(
      'SELECT avatar FROM users WHERE user_id = ? AND has_avatar = 1',
      [userId],
    );
    if (rows.isEmpty) return null;
    return rows.first.readNullable<String>('avatar');
  }

  @override
  Future<void> setAvatar(String userId, String base64Png) async {
    await _db.execute(
      'UPDATE users SET avatar = ?, has_avatar = 1, updated_at = ? WHERE user_id = ?',
      [base64Png, DateTime.now().toUtc().millisecondsSinceEpoch, userId],
    );
  }

  @override
  Future<void> deleteAvatar(String userId) async {
    await _db.execute(
      'UPDATE users SET avatar = NULL, has_avatar = 0, updated_at = ? WHERE user_id = ?',
      [DateTime.now().toUtc().millisecondsSinceEpoch, userId],
    );
  }

  // ── Auth Tokens ────────────────────────────────────────────────────────────

  @override
  Future<ApiToken?> lookupTokenByHash(String tokenHash) async {
    final rows = await _db.select(
      'SELECT * FROM api_tokens WHERE token_hash = ?',
      [tokenHash],
    );
    if (rows.isEmpty) return null;
    return _rowToToken(rows.first);
  }

  @override
  Future<ApiToken> createToken(ApiTokenCompanion companion) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''INSERT INTO api_tokens
         (token_id, user_id, kind, name, token_hash, prefix, scopes,
          expires_at, absolute_expires_at, user_agent, client_ip,
          client_city, client_region, client_country, client_country_code,
          last_used_at, revoked_at, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        companion.tokenId,
        companion.userId,
        companion.kind.name,
        companion.name,
        companion.tokenHash,
        companion.prefix,
        jsonEncode(companion.scopes),
        companion.expiresAt?.millisecondsSinceEpoch,
        companion.absoluteExpiresAt?.millisecondsSinceEpoch,
        companion.userAgent,
        companion.clientIp,
        companion.clientCity,
        companion.clientRegion,
        companion.clientCountry,
        companion.clientCountryCode,
        null, // last_used_at
        null, // revoked_at
        now,
      ],
    );
    return (await lookupTokenByHash(companion.tokenHash))!;
  }

  @override
  Future<void> revokeToken(String tokenId) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      'UPDATE api_tokens SET revoked_at = ? WHERE token_id = ?',
      [now, tokenId],
    );
  }

  @override
  Future<void> revokeAllTokensForUser(
    String userId, {
    ApiTokenKind? kind,
  }) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    if (kind != null) {
      await _db.execute(
        '''UPDATE api_tokens
             SET revoked_at = ?
             WHERE user_id = ? AND revoked_at IS NULL AND kind = ?''',
        [now, userId, kind.name],
      );
    } else {
      await _db.execute(
        '''UPDATE api_tokens
             SET revoked_at = ?
             WHERE user_id = ? AND revoked_at IS NULL''',
        [now, userId],
      );
    }
  }

  @override
  Future<void> updateTokenLastUsed(String tokenId, DateTime at) async {
    await _db.execute(
      'UPDATE api_tokens SET last_used_at = ? WHERE token_id = ?',
      [at.millisecondsSinceEpoch, tokenId],
    );
  }

  @override
  Future<void> slideSessionExpiry(String tokenId, DateTime newExpiresAt) async {
    // Never extend past the hard cap. The CASE clamps to whichever is
    // smaller so a misconfigured caller can't prolong a session.
    await _db.execute(
      '''UPDATE api_tokens SET
           expires_at = CASE
             WHEN absolute_expires_at IS NOT NULL
                  AND ? > absolute_expires_at
             THEN absolute_expires_at
             ELSE ?
           END,
           last_used_at = ?
         WHERE token_id = ? AND kind = 'session' ''',
      [
        newExpiresAt.millisecondsSinceEpoch,
        newExpiresAt.millisecondsSinceEpoch,
        DateTime.now().toUtc().millisecondsSinceEpoch,
        tokenId,
      ],
    );
  }

  @override
  Future<List<ApiToken>> listTokensForUser(
    String userId, {
    ApiTokenKind? kind,
  }) async {
    if (kind != null) {
      final rows = await _db.select(
        '''SELECT * FROM api_tokens
             WHERE user_id = ? AND kind = ?
             ORDER BY created_at DESC''',
        [userId, kind.name],
      );
      return rows.map(_rowToToken).toList();
    }
    final rows = await _db.select(
      'SELECT * FROM api_tokens WHERE user_id = ? ORDER BY created_at DESC',
      [userId],
    );
    return rows.map(_rowToToken).toList();
  }

  // ── Publishers ─────────────────────────────────────────────────────────────

  @override
  Future<Publisher?> lookupPublisher(String publisherId) async {
    final rows = await _db.select(
      'SELECT * FROM publishers WHERE id = ?',
      [publisherId],
    );
    if (rows.isEmpty) return null;
    return _rowToPublisher(rows.first);
  }

  @override
  Future<Publisher> createPublisher(PublisherCompanion companion) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''INSERT INTO publishers
         (id, display_name, description, website_url, contact_email,
          verified, created_by, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        companion.id,
        companion.displayName,
        companion.description,
        companion.websiteUrl,
        companion.contactEmail,
        _boolToInt(companion.verified),
        companion.createdBy,
        now,
        now,
      ],
    );
    return (await lookupPublisher(companion.id))!;
  }

  @override
  Future<Publisher> updatePublisher(
    String publisherId,
    PublisherCompanion companion,
  ) async {
    final existing = await lookupPublisher(publisherId);
    if (existing == null) throw NotFoundException.publisher(publisherId);

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''UPDATE publishers SET
           display_name = ?, description = ?, website_url = ?,
           contact_email = ?, updated_at = ?
         WHERE id = ?''',
      [
        companion.displayName,
        companion.description ?? existing.description,
        companion.websiteUrl ?? existing.websiteUrl,
        companion.contactEmail ?? existing.contactEmail,
        now,
        publisherId,
      ],
    );
    return (await lookupPublisher(publisherId))!;
  }

  @override
  Future<void> deletePublisher(String publisherId) async {
    await _db.execute('DELETE FROM publishers WHERE id = ?', [publisherId]);
  }

  @override
  Future<List<Publisher>> listPublishers() async {
    final rows = await _db.select(
      'SELECT * FROM publishers ORDER BY display_name',
    );
    return rows.map(_rowToPublisher).toList();
  }

  @override
  Future<List<Publisher>> listPublishersForUser(String userId) async {
    final rows = await _db.select(
      '''SELECT p.* FROM publishers p
         INNER JOIN publisher_members m ON m.publisher_id = p.id
         WHERE m.user_id = ?
         ORDER BY p.display_name''',
      [userId],
    );
    return rows.map(_rowToPublisher).toList();
  }

  @override
  Future<int> countVerifiedPublishersForUser(String userId) async {
    final rows = await _db.select(
      '''SELECT COUNT(*) AS n FROM publishers p
         INNER JOIN publisher_members m ON m.publisher_id = p.id
         WHERE m.user_id = ? AND p.verified = 1''',
      [userId],
    );
    return rows.first.read<int>('n');
  }

  // ── Publisher Verifications ────────────────────────────────────────────────

  @override
  Future<PublisherVerification> upsertVerification(
    PublisherVerificationCompanion companion,
  ) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    // `(user_id, domain)` is unique — replace any prior pending token for
    // the same user+domain pair so the UI can simply re-start the flow.
    await _db.execute(
      '''INSERT INTO publisher_verifications
         (id, user_id, domain, token_hash, created_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT (user_id, domain) DO UPDATE SET
           id = excluded.id,
           token_hash = excluded.token_hash,
           created_at = excluded.created_at,
           expires_at = excluded.expires_at''',
      [
        companion.id,
        companion.userId,
        companion.domain,
        companion.tokenHash,
        now,
        companion.expiresAt.millisecondsSinceEpoch,
      ],
    );
    return (await lookupVerification(companion.userId, companion.domain))!;
  }

  @override
  Future<PublisherVerification?> lookupVerification(
    String userId,
    String domain,
  ) async {
    final rows = await _db.select(
      'SELECT * FROM publisher_verifications WHERE user_id = ? AND domain = ?',
      [userId, domain],
    );
    if (rows.isEmpty) return null;
    return _rowToVerification(rows.first);
  }

  @override
  Future<void> deleteVerification(String id) async {
    await _db.execute('DELETE FROM publisher_verifications WHERE id = ?', [id]);
  }

  @override
  Future<int> deleteExpiredVerifications() async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    // `execute` returns void, so count what we'll delete in a pre-select
    // — cheap since the index on `expires_at` makes this a range scan.
    final countRows = await _db.select(
      'SELECT COUNT(*) AS n FROM publisher_verifications WHERE expires_at < ?',
      [now],
    );
    final n = countRows.first.read<int>('n');
    if (n > 0) {
      await _db.execute(
        'DELETE FROM publisher_verifications WHERE expires_at < ?',
        [now],
      );
    }
    return n;
  }

  // ── Publisher Members ──────────────────────────────────────────────────────

  @override
  Future<List<PublisherMember>> listPublisherMembers(String publisherId) async {
    final rows = await _db.select(
      'SELECT * FROM publisher_members WHERE publisher_id = ?',
      [publisherId],
    );
    return rows.map(_rowToPublisherMember).toList();
  }

  @override
  Future<void> addPublisherMember(PublisherMemberCompanion companion) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''INSERT OR REPLACE INTO publisher_members
         (publisher_id, user_id, role, created_at)
         VALUES (?, ?, ?, ?)''',
      [companion.publisherId, companion.userId, companion.role, now],
    );
  }

  @override
  Future<void> removePublisherMember(String publisherId, String userId) async {
    await _db.execute(
      'DELETE FROM publisher_members WHERE publisher_id = ? AND user_id = ?',
      [publisherId, userId],
    );
  }

  @override
  Future<bool> isPublisherAdmin(String publisherId, String userId) async {
    final rows = await _db.select(
      'SELECT 1 FROM publisher_members WHERE publisher_id = ? AND user_id = ? AND role = ?',
      [publisherId, userId, PublisherRole.admin],
    );
    return rows.isNotEmpty;
  }

  @override
  Future<bool> isPublisherMember(String publisherId, String userId) async {
    final rows = await _db.select(
      'SELECT 1 FROM publisher_members WHERE publisher_id = ? AND user_id = ?',
      [publisherId, userId],
    );
    return rows.isNotEmpty;
  }

  // ── Uploaders ──────────────────────────────────────────────────────────────

  @override
  Future<List<String>> listUploaders(String packageName) async {
    final rows = await _db.select(
      'SELECT user_id FROM package_uploaders WHERE package_name = ?',
      [packageName],
    );
    return rows.map((r) => r.read<String>('user_id')).toList();
  }

  @override
  Future<void> addUploader(String packageName, String userId) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      'INSERT OR IGNORE INTO package_uploaders (package_name, user_id, created_at) VALUES (?, ?, ?)',
      [packageName, userId, now],
    );
  }

  @override
  Future<void> removeUploader(String packageName, String userId) async {
    await _db.execute(
      'DELETE FROM package_uploaders WHERE package_name = ? AND user_id = ?',
      [packageName, userId],
    );
  }

  @override
  Future<bool> isUploader(String packageName, String userId) async {
    final rows = await _db.select(
      'SELECT 1 FROM package_uploaders WHERE package_name = ? AND user_id = ?',
      [packageName, userId],
    );
    return rows.isNotEmpty;
  }

  // ── Likes ──────────────────────────────────────────────────────────────────

  @override
  Future<bool> hasLike(String userId, String packageName) async {
    final rows = await _db.select(
      'SELECT 1 FROM package_likes WHERE user_id = ? AND package_name = ?',
      [userId, packageName],
    );
    return rows.isNotEmpty;
  }

  @override
  Future<void> likePackage(String userId, String packageName) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      'INSERT OR IGNORE INTO package_likes (user_id, package_name, created_at) VALUES (?, ?, ?)',
      [userId, packageName, now],
    );
    await _db.execute(
      'UPDATE packages SET likes_count = (SELECT COUNT(*) FROM package_likes WHERE package_name = ?) WHERE name = ?',
      [packageName, packageName],
    );
  }

  @override
  Future<void> unlikePackage(String userId, String packageName) async {
    await _db.execute(
      'DELETE FROM package_likes WHERE user_id = ? AND package_name = ?',
      [userId, packageName],
    );
    await _db.execute(
      'UPDATE packages SET likes_count = (SELECT COUNT(*) FROM package_likes WHERE package_name = ?) WHERE name = ?',
      [packageName, packageName],
    );
  }

  @override
  Future<int> likeCount(String packageName) async {
    final rows = await _db.select(
      'SELECT COUNT(*) as cnt FROM package_likes WHERE package_name = ?',
      [packageName],
    );
    return rows.first.read<int>('cnt');
  }

  @override
  Future<List<String>> likedPackages(String userId) async {
    final rows = await _db.select(
      'SELECT package_name FROM package_likes WHERE user_id = ?',
      [userId],
    );
    return rows.map((r) => r.read<String>('package_name')).toList();
  }

  // ── Upload Sessions ────────────────────────────────────────────────────────

  @override
  Future<UploadSession?> lookupUploadSession(String id) async {
    final rows = await _db.select(
      'SELECT * FROM upload_sessions WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return _rowToUploadSession(rows.first);
  }

  @override
  Future<void> createUploadSession(UploadSessionCompanion companion) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''INSERT INTO upload_sessions
         (id, user_id, temp_path, state, created_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?)''',
      [
        companion.id,
        companion.userId,
        companion.tempPath,
        UploadState.pending.name,
        now,
        companion.expiresAt.millisecondsSinceEpoch,
      ],
    );
  }

  @override
  Future<void> updateUploadSessionState(String id, UploadState state) async {
    await _db.execute(
      'UPDATE upload_sessions SET state = ? WHERE id = ?',
      [state.name, id],
    );
  }

  @override
  Future<void> deleteExpiredUploadSessions() async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      'DELETE FROM upload_sessions WHERE expires_at < ?',
      [now],
    );
  }

  @override
  Future<int> countPendingUploads(String userId) async {
    final rows = await _db.select(
      'SELECT COUNT(*) as cnt FROM upload_sessions WHERE user_id = ? AND state = ?',
      [userId, UploadState.pending.name],
    );
    return rows.first.read<int>('cnt');
  }

  // ── Audit Log ──────────────────────────────────────────────────────────────

  @override
  Future<void> appendAuditLog(AuditLogCompanion companion) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''INSERT INTO audit_log
         (id, created_at, kind, agent_id, package_name, version,
          publisher_id, summary, data_json)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        companion.id,
        now,
        companion.kind,
        companion.agentId,
        companion.packageName,
        companion.version,
        companion.publisherId,
        companion.summary,
        companion.dataJson,
      ],
    );
  }

  @override
  Future<List<AuditLogRecord>> queryAuditLog({
    String? packageName,
    String? agentId,
    String? publisherId,
    int limit = 50,
    DateTime? before,
  }) async {
    final conditions = <String>[];
    final args = <Object?>[];

    if (packageName != null) {
      conditions.add('package_name = ?');
      args.add(packageName);
    }
    if (agentId != null) {
      conditions.add('agent_id = ?');
      args.add(agentId);
    }
    if (publisherId != null) {
      conditions.add('publisher_id = ?');
      args.add(publisherId);
    }
    if (before != null) {
      conditions.add('created_at < ?');
      args.add(before.millisecondsSinceEpoch);
    }

    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final sql =
        'SELECT * FROM audit_log $where ORDER BY created_at DESC LIMIT ?';
    args.add(limit);

    final rows = await _db.select(sql, args);
    return rows.map(_rowToAuditLog).toList();
  }

  // ── Package Scores ─────────────────────────────────────────────────────────

  @override
  Future<PackageScore?> lookupScore(String packageName, String version) async {
    final rows = await _db.select(
      'SELECT * FROM package_scores WHERE package_name = ? AND version = ?',
      [packageName, version],
    );
    if (rows.isEmpty) return null;
    return _rowToScore(rows.first);
  }

  @override
  Future<void> saveScore(PackageScoreCompanion companion) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    // Empty list → null in the column. Mirrors how reportJson behaves
    // for transient status updates (pending/running/failed): the prior
    // success row's cache is cleared, then rewritten when scoring next
    // succeeds. Honest for republishes — the new version may legitimately
    // have different tags than the old one.
    final panaTagsJson = companion.panaTags.isEmpty
        ? null
        : jsonEncode(companion.panaTags);
    await _db.execute(
      '''INSERT INTO package_scores
         (package_name, version, status, granted_points, max_points,
          report_json, pana_tags, pana_version, dart_version,
          flutter_version, error_message, scored_at, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(package_name, version) DO UPDATE SET
           status          = excluded.status,
           granted_points  = excluded.granted_points,
           max_points      = excluded.max_points,
           report_json     = excluded.report_json,
           pana_tags       = excluded.pana_tags,
           pana_version    = excluded.pana_version,
           dart_version    = excluded.dart_version,
           flutter_version = excluded.flutter_version,
           error_message   = excluded.error_message,
           scored_at       = excluded.scored_at,
           updated_at      = excluded.updated_at''',
      [
        companion.packageName,
        companion.version,
        companion.status.name,
        companion.grantedPoints,
        companion.maxPoints,
        companion.reportJson,
        panaTagsJson,
        companion.panaVersion,
        companion.dartVersion,
        companion.flutterVersion,
        companion.errorMessage,
        companion.scoredAt?.millisecondsSinceEpoch,
        now,
        now,
      ],
    );
  }

  @override
  Future<List<PackageScore>> listPendingScores() async {
    final rows = await _db.select(
      "SELECT * FROM package_scores WHERE status IN ('pending', 'running')",
    );
    return rows.map(_rowToScore).toList();
  }

  @override
  Future<({int total, int scored})> countScoringCoverage() async {
    final totalRows = await _db.select(
      'SELECT COUNT(*) as cnt FROM packages WHERE latest_version IS NOT NULL',
    );
    final total = totalRows.first.read<int>('cnt');

    final scoredRows = await _db.select(
      '''SELECT COUNT(DISTINCT p.name) as cnt FROM packages p
         INNER JOIN package_scores s
           ON s.package_name = p.name
           AND s.version = COALESCE(p.latest_version, p.latest_prerelease)
           AND s.status = 'completed' ''',
    );
    final scored = scoredRows.first.read<int>('cnt');

    return (total: total, scored: scored);
  }

  @override
  Future<List<({String packageName, String version})>>
  listUnscoredVersions() async {
    final rows = await _db.select(
      '''SELECT p.name AS package_name,
                COALESCE(p.latest_version, p.latest_prerelease) AS version
         FROM packages p
         WHERE COALESCE(p.latest_version, p.latest_prerelease) IS NOT NULL
           AND NOT EXISTS (
             SELECT 1 FROM package_scores s
             WHERE s.package_name = p.name
               AND s.version = COALESCE(p.latest_version, p.latest_prerelease)
               AND s.status IN ('completed', 'pending', 'running')
           )''',
    );
    return rows
        .map(
          (r) => (
            packageName: r.read<String>('package_name'),
            version: r.read<String>('version'),
          ),
        )
        .toList();
  }

  @override
  Future<List<({String packageName, String version})>> listVersionsForRescan({
    required bool latestOnly,
  }) async {
    final rows = latestOnly
        ? await _db.select(
            '''SELECT p.name AS package_name,
                      COALESCE(p.latest_version, p.latest_prerelease) AS version
               FROM packages p
               WHERE COALESCE(p.latest_version, p.latest_prerelease) IS NOT NULL''',
          )
        : await _db.select(
            'SELECT package_name, version FROM package_versions',
          );
    return rows
        .map(
          (r) => (
            packageName: r.read<String>('package_name'),
            version: r.read<String>('version'),
          ),
        )
        .toList();
  }

  @override
  Future<void> resetStaleRunningScores() async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      "UPDATE package_scores SET status = 'pending', updated_at = ? WHERE status = 'running'",
      [now],
    );
  }

  // ── Dartdoc ─────────────────────────────────────────────────────────────────

  @override
  Future<DartdocRecord?> lookupDartdoc(String packageName) async {
    final rows = await _db.select(
      'SELECT * FROM dartdoc_status WHERE package_name = ?',
      [packageName],
    );
    if (rows.isEmpty) return null;
    return _rowToDartdoc(rows.first);
  }

  @override
  Future<void> saveDartdoc(DartdocRecordCompanion companion) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''INSERT INTO dartdoc_status
         (package_name, version, status, error_message, generated_at,
          created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(package_name) DO UPDATE SET
           version       = excluded.version,
           status        = excluded.status,
           error_message = excluded.error_message,
           generated_at  = excluded.generated_at,
           updated_at    = excluded.updated_at''',
      [
        companion.packageName,
        companion.version,
        companion.status.name,
        companion.errorMessage,
        companion.generatedAt?.millisecondsSinceEpoch,
        now,
        now,
      ],
    );
  }

  @override
  Future<List<DartdocRecord>> listPendingDartdocs() async {
    final rows = await _db.select(
      "SELECT * FROM dartdoc_status WHERE status IN ('pending', 'running')",
    );
    return rows.map(_rowToDartdoc).toList();
  }

  @override
  Future<void> resetStaleRunningDartdocs() async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      "UPDATE dartdoc_status SET status = 'pending', updated_at = ? WHERE status = 'running'",
      [now],
    );
  }

  // ── Download Counts ─────────────────────────────────────────────────────────

  @override
  Future<void> recordDownload(
    String package,
    String version,
    String dateUtc,
  ) async {
    await _db.execute(
      '''INSERT INTO package_download_counts (package_name, version, date_utc, count)
         VALUES (?, ?, ?, 1)
         ON CONFLICT(package_name, version, date_utc)
         DO UPDATE SET count = count + 1''',
      [package, version, dateUtc],
    );
  }

  @override
  Future<int> totalDownloads(String package, {int days = 30}) async {
    final cutoff = _daysAgoUtc(days);
    final rows = await _db.select(
      '''SELECT COALESCE(SUM(count), 0) AS total
         FROM package_download_counts
         WHERE package_name = ?
           AND date_utc >= ?''',
      [package, cutoff],
    );
    return rows.first.read<int>('total');
  }

  @override
  Future<List<DownloadWeek>> weeklyDownloads(
    String package, {
    int weeks = 53,
  }) async {
    final cutoff = _daysAgoUtc(weeks * 7);
    final rows = await _db.select(
      '''SELECT version, date_utc, count
         FROM package_download_counts
         WHERE package_name = ?
           AND date_utc >= ?
         ORDER BY date_utc ASC''',
      [package, cutoff],
    );

    // Generate the expected list of Monday dates for the last N weeks.
    final now = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    final currentMonday = today.subtract(Duration(days: today.weekday - 1));
    final mondayDates = <String>[];
    for (var i = weeks - 1; i >= 0; i--) {
      mondayDates.add(
        _formatDate(currentMonday.subtract(Duration(days: i * 7))),
      );
    }

    // Group query results by week start (Monday).
    final weekMap = <String, Map<String, int>>{};
    for (final row in rows) {
      final dateUtc = row.read<String>('date_utc');
      final version = row.read<String>('version');
      final count = row.read<int>('count');
      final monday = _mondayOf(dateUtc);
      weekMap.putIfAbsent(monday, () => {});
      weekMap[monday]![version] = (weekMap[monday]![version] ?? 0) + count;
    }

    // Build the result list, filling missing weeks with zeros.
    return mondayDates.map((monday) {
      final byVersion = weekMap[monday] ?? {};
      final total = byVersion.values.fold(0, (a, b) => a + b);
      final d = DateTime.parse(monday);
      final label = '${_monthAbbr(d.month)} ${d.day}';
      return DownloadWeek(
        weekStart: monday,
        weekLabel: label,
        total: total,
        byVersion: byVersion,
      );
    }).toList();
  }

  static String _daysAgoUtc(int days) {
    final d = DateTime.now().toUtc().subtract(Duration(days: days));
    return _formatDate(d);
  }

  static String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _mondayOf(String dateUtc) {
    final d = DateTime.parse(dateUtc);
    final monday = d.subtract(Duration(days: d.weekday - 1));
    return _formatDate(monday);
  }

  static String _monthAbbr(int month) => const [
    '',
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][month];

  // ── Aggregate Counts ────────────────────────────────────────────────────────

  @override
  Future<({int packages, int versions, int users})> counts() async {
    final rows = await _db.select(
      '''SELECT
           (SELECT COUNT(*) FROM packages) AS packages,
           (SELECT COUNT(*) FROM package_versions) AS versions,
           (SELECT COUNT(*) FROM users) AS users''',
    );
    final row = rows.first;
    return (
      packages: row.read<int>('packages'),
      versions: row.read<int>('versions'),
      users: row.read<int>('users'),
    );
  }

  /// Storage stats straight from SQLite's own page accounting.
  ///
  /// [DatabaseStats.totalBytes] is the logical page total (`page_count *
  /// page_size`), which is not quite the on-disk footprint: it excludes the
  /// `-wal` and `-shm` sidecars, which the admin stats endpoint measures
  /// separately from the filesystem.
  @override
  Future<DatabaseStats> databaseStats({int topTables = 8}) async {
    final pageCount = await _pragmaInt('page_count');
    final pageSize = await _pragmaInt('page_size');
    final freeCount = await _pragmaInt('freelist_count');

    return DatabaseStats(
      totalBytes: pageCount * pageSize,
      reclaimableBytes: freeCount * pageSize,
      tables: await _largestRelations(topTables),
    );
  }

  /// Read a single-value `PRAGMA`. Returns 0 if SQLite reports nothing, which
  /// keeps the size arithmetic total rather than throwing on an odd build.
  Future<int> _pragmaInt(String pragma) async {
    final rows = await _db.select('PRAGMA $pragma');
    if (rows.isEmpty) return 0;
    return rows.first.read<int>(pragma);
  }

  /// The [limit] largest relations by size, tables and indexes alike.
  ///
  /// Sizes come from the `dbstat` virtual table. It is compiled into the
  /// `sqlite3` package's default build, but a host swapping in its own
  /// libsqlite3 without `SQLITE_ENABLE_DBSTAT_VTAB` would fail here, so a
  /// missing vtab degrades to an empty breakdown instead of taking the whole
  /// stats panel down with it.
  Future<List<DbTableStat>> _largestRelations(int limit) async {
    final List<QueryRow> sizes;
    try {
      sizes = await _db.select(
        '''SELECT name, SUM(pgsize) AS bytes
           FROM dbstat
           GROUP BY name
           ORDER BY bytes DESC
           LIMIT ?''',
        [limit],
      );
    } on Exception {
      return const [];
    }

    // One pass over the catalog beats a per-relation lookup. dbstat reports
    // indexes and FTS shadow tables alongside ordinary tables, and only the
    // indexes have nothing countable in them.
    final indexes = {
      for (final row in await _db.select(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      ))
        row.read<String>('name'),
    };

    final stats = <DbTableStat>[];
    for (final row in sizes) {
      final name = row.read<String>('name');
      final isIndex = indexes.contains(name);
      stats.add(
        DbTableStat(
          name: name,
          bytes: row.read<int>('bytes'),
          isIndex: isIndex,
          // Everything else gets counted, including relations the catalog
          // does not list (`sqlite_schema` is itself one), with [_rowCount]
          // absorbing anything that turns out not to be countable.
          rows: isIndex ? null : await _rowCount(name),
        ),
      );
    }
    return stats;
  }

  /// `COUNT(*)` for [table], or null if it is not countable.
  ///
  /// The identifier cannot be bound as a parameter, so it is quoted instead.
  /// [table] always originates from SQLite's own catalog rather than from a
  /// request, and the doubled-quote escape holds even for a name containing a
  /// quote.
  Future<int?> _rowCount(String table) async {
    final quoted = '"${table.replaceAll('"', '""')}"';
    try {
      final rows = await _db.select('SELECT COUNT(*) AS n FROM $quoted');
      return rows.first.read<int>('n');
    } on Exception {
      return null;
    }
  }

  // ── Transactions ───────────────────────────────────────────────────────────

  @override
  Future<T> transaction<T>(Future<T> Function(MetadataStore tx) action) {
    return _db.transaction(() => action(this));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Row mapping helpers
  // ═══════════════════════════════════════════════════════════════════════════

  static Package _rowToPackage(QueryRow row) {
    return Package(
      name: row.read<String>('name'),
      publisherId: row.readNullable<String>('publisher_id'),
      latestVersion: row.readNullable<String>('latest_version'),
      latestPrerelease: row.readNullable<String>('latest_prerelease'),
      likesCount: row.read<int>('likes_count'),
      isDiscontinued: _intToBool(row.read<int>('is_discontinued')),
      replacedBy: row.readNullable<String>('replaced_by'),
      isUnlisted: _intToBool(row.read<int>('is_unlisted')),
      // `parse` fails closed to private on an unrecognised value. A
      // database upgraded via ALTER TABLE has no CHECK constraint, so this
      // is the enforcement point on that path.
      visibility: PackageVisibility.parse(
        row.readNullable<String>('visibility'),
      ),
      visibilityChangedAt: _nullableIntToDateTime(
        row.readNullable<int>('visibility_changed_at'),
      ),
      visibilityChangedBy: row.readNullable<String>('visibility_changed_by'),
      createdAt: _intToDateTime(row.read<int>('created_at')),
      updatedAt: _intToDateTime(row.read<int>('updated_at')),
    );
  }

  static VersionDependency _rowToVersionDependency(QueryRow row) {
    return VersionDependency(
      name: row.read<String>('dep_name'),
      // A row whose kind or source is unrecognised should not silently
      // become a `direct` / `hosted` edge — that is the combination that
      // participates in the closure. Fall back to the inert values so a
      // corrupt row cannot force a package public.
      kind:
          DependencyKind.tryParse(row.read<String>('kind')) ??
          DependencyKind.override,
      source:
          DependencySource.tryParse(row.read<String>('source')) ??
          DependencySource.bare,
      hostedOrigin: row.readNullable<String>('hosted_origin'),
      isLocal: _intToBool(row.read<int>('is_local')),
      isAmbiguous: _intToBool(row.read<int>('is_ambiguous')),
      constraintText: row.readNullable<String>('constraint_text'),
    );
  }

  static PackageVersion _rowToVersion(QueryRow row) {
    return PackageVersion(
      publicResolvable: _intToBool(row.read<int>('public_resolvable')),
      packageName: row.read<String>('package_name'),
      version: row.read<String>('version'),
      pubspecJson: row.read<String>('pubspec_json'),
      readmeContent: row.readNullable<String>('readme_content'),
      changelogContent: row.readNullable<String>('changelog_content'),
      exampleContent: row.readNullable<String>('example_content'),
      examplePath: row.readNullable<String>('example_path'),
      libraries: _jsonToStringList(row.read<String>('libraries')),
      binExecutables: _jsonToStringList(row.read<String>('bin_executables')),
      screenshots: _jsonToScreenshots(
        row.readNullable<String>('screenshots') ?? '[]',
      ),
      archiveSizeBytes: row.read<int>('archive_size_bytes'),
      archiveSha256: row.read<String>('archive_sha256'),
      uploaderId: row.readNullable<String>('uploader_id'),
      publisherId: row.readNullable<String>('publisher_id'),
      isRetracted: _intToBool(row.read<int>('is_retracted')),
      retractedAt: _nullableIntToDateTime(
        row.readNullable<int>('retracted_at'),
      ),
      isPrerelease: _intToBool(row.read<int>('is_prerelease')),
      dartSdkMin: row.readNullable<String>('dart_sdk_min'),
      dartSdkMax: row.readNullable<String>('dart_sdk_max'),
      flutterSdkMin: row.readNullable<String>('flutter_sdk_min'),
      flutterSdkMax: row.readNullable<String>('flutter_sdk_max'),
      tags: _jsonToStringList(row.read<String>('tags')),
      publishedAt: _intToDateTime(row.read<int>('published_at')),
    );
  }

  static User _rowToUser(QueryRow row) {
    return User(
      userId: row.read<String>('user_id'),
      email: row.read<String>('email'),
      displayName: row.read<String>('display_name'),
      role: UserRole.tryFromString(row.read<String>('role')) ?? UserRole.viewer,
      isActive: _intToBool(row.read<int>('is_active')),
      mustChangePassword: _intToBool(row.read<int>('must_change_password')),
      hasAvatar: _intToBool(row.readNullable<int>('has_avatar') ?? 0),
      createdAt: _intToDateTime(row.read<int>('created_at')),
      updatedAt: _intToDateTime(row.read<int>('updated_at')),
    );
  }

  static ApiToken _rowToToken(QueryRow row) {
    return ApiToken(
      tokenId: row.read<String>('token_id'),
      userId: row.read<String>('user_id'),
      kind: ApiTokenKind.fromString(row.read<String>('kind')),
      name: row.read<String>('name'),
      prefix: row.read<String>('prefix'),
      scopes: _jsonToStringList(row.read<String>('scopes')),
      createdAt: _intToDateTime(row.read<int>('created_at')),
      expiresAt: _nullableIntToDateTime(row.readNullable<int>('expires_at')),
      absoluteExpiresAt: _nullableIntToDateTime(
        row.readNullable<int>('absolute_expires_at'),
      ),
      userAgent: row.readNullable<String>('user_agent'),
      clientIp: row.readNullable<String>('client_ip'),
      clientCity: row.readNullable<String>('client_city'),
      clientRegion: row.readNullable<String>('client_region'),
      clientCountry: row.readNullable<String>('client_country'),
      clientCountryCode: row.readNullable<String>('client_country_code'),
      lastUsedAt: _nullableIntToDateTime(row.readNullable<int>('last_used_at')),
      revokedAt: _nullableIntToDateTime(row.readNullable<int>('revoked_at')),
    );
  }

  static Publisher _rowToPublisher(QueryRow row) {
    return Publisher(
      id: row.read<String>('id'),
      displayName: row.read<String>('display_name'),
      description: row.readNullable<String>('description'),
      websiteUrl: row.readNullable<String>('website_url'),
      contactEmail: row.readNullable<String>('contact_email'),
      verified: row.read<int>('verified') == 1,
      createdBy: row.read<String>('created_by'),
      createdAt: _intToDateTime(row.read<int>('created_at')),
      updatedAt: _intToDateTime(row.read<int>('updated_at')),
    );
  }

  static PublisherMember _rowToPublisherMember(QueryRow row) {
    return PublisherMember(
      publisherId: row.read<String>('publisher_id'),
      userId: row.read<String>('user_id'),
      role: row.read<String>('role'),
      createdAt: _intToDateTime(row.read<int>('created_at')),
    );
  }

  static PublisherVerification _rowToVerification(QueryRow row) {
    return PublisherVerification(
      id: row.read<String>('id'),
      userId: row.read<String>('user_id'),
      domain: row.read<String>('domain'),
      tokenHash: row.read<String>('token_hash'),
      createdAt: _intToDateTime(row.read<int>('created_at')),
      expiresAt: _intToDateTime(row.read<int>('expires_at')),
    );
  }

  static UploadSession _rowToUploadSession(QueryRow row) {
    return UploadSession(
      id: row.read<String>('id'),
      userId: row.read<String>('user_id'),
      tempPath: row.read<String>('temp_path'),
      state: UploadState.fromString(row.read<String>('state')),
      createdAt: _intToDateTime(row.read<int>('created_at')),
      expiresAt: _intToDateTime(row.read<int>('expires_at')),
    );
  }

  static PackageScore _rowToScore(QueryRow row) {
    final panaTagsJson = row.readNullable<String>('pana_tags');
    return PackageScore(
      packageName: row.read<String>('package_name'),
      version: row.read<String>('version'),
      status: ScoreStatus.fromString(row.read<String>('status')),
      grantedPoints: row.readNullable<int>('granted_points'),
      maxPoints: row.readNullable<int>('max_points'),
      reportJson: row.readNullable<String>('report_json'),
      panaTags: panaTagsJson == null ? const [] : _jsonToStringList(panaTagsJson),
      panaVersion: row.readNullable<String>('pana_version'),
      dartVersion: row.readNullable<String>('dart_version'),
      flutterVersion: row.readNullable<String>('flutter_version'),
      errorMessage: row.readNullable<String>('error_message'),
      scoredAt: _nullableIntToDateTime(row.readNullable<int>('scored_at')),
      createdAt: _intToDateTime(row.read<int>('created_at')),
      updatedAt: _intToDateTime(row.read<int>('updated_at')),
    );
  }

  static DartdocRecord _rowToDartdoc(QueryRow row) {
    return DartdocRecord(
      packageName: row.read<String>('package_name'),
      version: row.read<String>('version'),
      status: DartdocStatus.fromString(row.read<String>('status')),
      errorMessage: row.readNullable<String>('error_message'),
      generatedAt: _nullableIntToDateTime(
        row.readNullable<int>('generated_at'),
      ),
      createdAt: _intToDateTime(row.read<int>('created_at')),
      updatedAt: _intToDateTime(row.read<int>('updated_at')),
    );
  }

  static AuditLogRecord _rowToAuditLog(QueryRow row) {
    return AuditLogRecord(
      id: row.read<String>('id'),
      createdAt: _intToDateTime(row.read<int>('created_at')),
      kind: row.read<String>('kind'),
      agentId: row.readNullable<String>('agent_id'),
      packageName: row.readNullable<String>('package_name'),
      version: row.readNullable<String>('version'),
      publisherId: row.readNullable<String>('publisher_id'),
      summary: row.read<String>('summary'),
      dataJson: row.read<String>('data_json'),
    );
  }

  // ── Conversion utilities ───────────────────────────────────────────────────

  static int _boolToInt(bool v) => v ? 1 : 0;
  static bool _intToBool(int v) => v != 0;

  static DateTime _intToDateTime(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  static DateTime? _nullableIntToDateTime(int? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  static int? _dateTimeToNullableInt(DateTime? dt) =>
      dt?.toUtc().millisecondsSinceEpoch;

  static List<String> _jsonToStringList(String json) {
    final decoded = jsonDecode(json);
    return (decoded as List).cast<String>();
  }

  static List<PackageScreenshot> _jsonToScreenshots(String json) {
    final decoded = jsonDecode(json) as List;
    return decoded
        .map((e) => PackageScreenshot.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}
