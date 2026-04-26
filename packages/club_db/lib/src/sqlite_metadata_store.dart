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
    await _db.execute(
      '''INSERT INTO packages
         (name, publisher_id, latest_version, latest_prerelease,
          likes_count, is_discontinued, replaced_by, is_unlisted,
          created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        companion.name,
        companion.publisherId,
        companion.latestVersion,
        companion.latestPrerelease,
        companion.likesCount ?? 0,
        _boolToInt(companion.isDiscontinued ?? false),
        companion.replacedBy,
        _boolToInt(companion.isUnlisted ?? false),
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
    await _db.execute(
      '''UPDATE packages SET
           publisher_id = ?, latest_version = ?, latest_prerelease = ?,
           likes_count = ?, is_discontinued = ?, replaced_by = ?,
           is_unlisted = ?, updated_at = ?
         WHERE name = ?''',
      [
        companion.publisherId ?? existing.publisherId,
        companion.latestVersion ?? existing.latestVersion,
        companion.latestPrerelease ?? existing.latestPrerelease,
        companion.likesCount ?? existing.likesCount,
        _boolToInt(companion.isDiscontinued ?? existing.isDiscontinued),
        companion.replacedBy ?? existing.replacedBy,
        _boolToInt(companion.isUnlisted ?? existing.isUnlisted),
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
    int limit = 50,
    String? pageToken,
    String? query,
  }) async {
    final offset = int.tryParse(pageToken ?? '') ?? 0;
    final where = <String>[];
    final args = <Object?>[];
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
    int limit = 50,
    String? pageToken,
    bool includeUnlisted = true,
  }) async {
    final offset = int.tryParse(pageToken ?? '') ?? 0;
    final unlistedFilter = includeUnlisted ? '' : 'AND is_unlisted = 0';
    final rows = await _db.select(
      '''SELECT * FROM packages
         WHERE publisher_id = ? $unlistedFilter
         ORDER BY updated_at DESC LIMIT ? OFFSET ?''',
      [publisherId, limit + 1, offset],
    );
    final hasMore = rows.length > limit;
    final items = rows.take(limit).map(_rowToPackage).toList();

    final totalRows = await _db.select(
      'SELECT COUNT(*) AS n FROM packages WHERE publisher_id = ? $unlistedFilter',
      [publisherId],
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
      final remaining = (await listVersions(package))
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

  @override
  Future<List<PackageVersion>> listVersions(String package) async {
    final rows = await _db.select(
      'SELECT * FROM package_versions WHERE package_name = ? ORDER BY published_at DESC',
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
    await _db.execute(
      '''INSERT INTO package_scores
         (package_name, version, status, granted_points, max_points,
          report_json, pana_version, dart_version, flutter_version,
          error_message, scored_at, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(package_name, version) DO UPDATE SET
           status          = excluded.status,
           granted_points  = excluded.granted_points,
           max_points      = excluded.max_points,
           report_json     = excluded.report_json,
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
      createdAt: _intToDateTime(row.read<int>('created_at')),
      updatedAt: _intToDateTime(row.read<int>('updated_at')),
    );
  }

  static PackageVersion _rowToVersion(QueryRow row) {
    return PackageVersion(
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
    return PackageScore(
      packageName: row.read<String>('package_name'),
      version: row.read<String>('version'),
      status: ScoreStatus.fromString(row.read<String>('status')),
      grantedPoints: row.readNullable<int>('granted_points'),
      maxPoints: row.readNullable<int>('max_points'),
      reportJson: row.readNullable<String>('report_json'),
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
