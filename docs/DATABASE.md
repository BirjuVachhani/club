# club — Database Schema & Storage Design

## Overview

club uses three storage layers, each behind an abstract interface:

1. **MetadataStore** — relational data (packages, versions, users, tokens, etc.)
2. **BlobStore** — binary tarball archives
3. **SearchIndex** — full-text search

Default stack: SQLite (drift ORM) + filesystem + SQLite FTS5.

---

## Database Schema

### Entity Relationship Diagram

```
┌──────────────┐     ┌───────────────────┐     ┌───────────────┐
│    users      │────<│   api_tokens       │     │  publishers    │
│              │     └───────────────────┘     │               │
│  userId (PK) │                                │  id (PK)      │
│  email (UQ)  │────<┌───────────────────┐     │  displayName   │
│  passwordHash│     │ package_uploaders  │     │  description   │
│  displayName │     │                   │     │  createdBy →   │
│  isAdmin     │     │ packageName (FK) →│──┐  └───────┬───────┘
│  isActive    │     │ userId (FK) →    │  │          │
│  createdAt   │     └───────────────────┘  │  ┌──────┴────────┐
│  updatedAt   │                            │  │publisher_members│
└──────┬───────┘                            │  │               │
       │                                    │  │ publisherId → │
       │←──┌───────────────────┐            │  │ userId →      │
       │   │  package_likes     │            │  │ role          │
       │   │                   │            │  └───────────────┘
       │   │ userId (FK) →    │            │
       │   │ packageName (FK)→│──┐         │
       │   └───────────────────┘  │         │
       │                          ▼         ▼
       │                    ┌──────────────────┐
       │                    │    packages       │
       │                    │                  │
       │                    │  name (PK)       │
       │                    │  publisherId → ? │
       │                    │  latestVersion   │
       │                    │  latestPrerelease│
       │                    │  likesCount      │
       │                    │  isDiscontinued  │
       │                    │  isUnlisted      │
       │                    │  replacedBy      │
       │                    │  createdAt       │
       │                    │  updatedAt       │
       │                    └────────┬─────────┘
       │                             │
       │                    ┌────────┴──────────┐
       │                    │ package_versions   │
       │                    │                   │
       │                    │ packageName (FK) →│
       │                    │ version           │
       │                    │ pubspecJson       │
       │                    │ readmeContent     │
       │                    │ changelogContent  │
       │                    │ archiveSizeBytes  │
       │                    │ archiveSha256     │
       │                    │ uploaderId →      │
       │                    │ publisherId       │
       │                    │ isRetracted       │
       │                    │ isPrerelease      │
       │                    │ publishedAt       │
       │                    └───────────────────┘
       │
       │←──┌───────────────────┐
           │  upload_sessions   │
           │                   │
           │  id (PK)          │
           │  userId (FK) →    │
           │  tempPath         │
           │  state            │
           │  createdAt        │
           │  expiresAt        │
           └───────────────────┘

┌───────────────────┐          ┌─────────────────────────┐
│  audit_log         │          │  package_fts (FTS5)      │
│                   │          │                         │
│  id (PK)          │          │  package (content=)     │
│  createdAt        │          │  name                   │
│  kind             │          │  description            │
│  agentId →        │          │  readmeExcerpt          │
│  packageName      │          │  tags                   │
│  version          │          └─────────────────────────┘
│  publisherId      │
│  summary          │
│  dataJson         │
└───────────────────┘
```

---

## Table Definitions

### users

Stores user accounts. Created by server admin.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `user_id` | TEXT | PRIMARY KEY | UUID v4 |
| `email` | TEXT | NOT NULL, UNIQUE | Login email |
| `password_hash` | TEXT | NOT NULL | bcrypt hash (cost=12) |
| `display_name` | TEXT | NOT NULL | Human-readable name |
| `is_admin` | BOOLEAN | NOT NULL, DEFAULT 0 | Server admin flag |
| `is_active` | BOOLEAN | NOT NULL, DEFAULT 1 | Account enabled flag |
| `created_at` | INTEGER | NOT NULL | Unix milliseconds UTC |
| `updated_at` | INTEGER | NOT NULL | Unix milliseconds UTC |

**Indexes:**
- `idx_users_email` on `email`

---

### api_tokens

API tokens for `dart pub` client and CI/CD.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `token_id` | TEXT | PRIMARY KEY | UUID v4 |
| `user_id` | TEXT | NOT NULL, FK → users | Token owner |
| `name` | TEXT | NOT NULL | Human label (e.g., "CI token") |
| `token_hash` | TEXT | NOT NULL, UNIQUE | SHA-256 of raw token |
| `prefix` | TEXT | NOT NULL | First 8 chars of raw token |
| `scopes` | TEXT | NOT NULL | JSON array: `["read","write"]` |
| `expires_at` | INTEGER | NULL | Unix ms, NULL = never expires |
| `last_used_at` | INTEGER | NULL | Unix ms, updated on each use |
| `revoked_at` | INTEGER | NULL | Unix ms, NULL = active |
| `created_at` | INTEGER | NOT NULL | Unix ms |

**Indexes:**
- `idx_tokens_user_id` on `user_id`
- `idx_tokens_hash` on `token_hash` (UNIQUE)

**Notes:**
- Raw token format: `club_<32-hex-chars>` (39 chars total)
- Only the SHA-256 hash is stored; raw token shown once at creation
- `prefix` is for display: "club_a1b2..." helps users identify which token

---

### packages

One row per package.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `name` | TEXT | PRIMARY KEY | Package name (lowercase, [a-z0-9_], 1-64 chars) |
| `publisher_id` | TEXT | NULL, FK → publishers | Owner publisher, or NULL for individual ownership |
| `latest_version` | TEXT | NULL | Denormalized: latest stable version string |
| `latest_prerelease` | TEXT | NULL | Denormalized: latest prerelease version string |
| `likes_count` | INTEGER | NOT NULL, DEFAULT 0 | Denormalized like count |
| `is_discontinued` | BOOLEAN | NOT NULL, DEFAULT 0 | Marked as discontinued |
| `replaced_by` | TEXT | NULL | Replacement package name |
| `is_unlisted` | BOOLEAN | NOT NULL, DEFAULT 0 | Hidden from search |
| `created_at` | INTEGER | NOT NULL | Unix ms |
| `updated_at` | INTEGER | NOT NULL | Unix ms |

**Indexes:**
- `idx_packages_publisher` on `publisher_id`
- `idx_packages_updated` on `updated_at DESC`

**Notes:**
- `latest_version` is recomputed on every publish using semver comparison
- `likes_count` is denormalized from `package_likes` for sort performance
- A package is owned by either a publisher (`publisher_id` set) or individual uploaders (`package_uploaders` rows)

---

### package_uploaders

Join table: which users can publish to a package (when not publisher-owned).

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `package_name` | TEXT | FK → packages | Package |
| `user_id` | TEXT | FK → users | Authorized uploader |
| `created_at` | INTEGER | NOT NULL | Unix ms |

**Primary Key:** `(package_name, user_id)`

**Notes:**
- Only used when `packages.publisher_id IS NULL`
- When a package is transferred to a publisher, uploader rows are cleared

---

### package_versions

One row per published version.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `package_name` | TEXT | NOT NULL, FK → packages | Parent package |
| `version` | TEXT | NOT NULL | Canonical semver string |
| `pubspec_json` | TEXT | NOT NULL | Full pubspec as JSON |
| `readme_content` | TEXT | NULL | Extracted README.md (Markdown) |
| `changelog_content` | TEXT | NULL | Extracted CHANGELOG.md (Markdown) |
| `libraries` | TEXT | NOT NULL | JSON array of library paths |
| `archive_size_bytes` | INTEGER | NOT NULL | Tarball size in bytes |
| `archive_sha256` | TEXT | NOT NULL | Hex-encoded SHA-256 of tarball |
| `uploader_id` | TEXT | NULL, FK → users | Who published this version |
| `publisher_id` | TEXT | NULL | Snapshot of publisher at publish time |
| `is_retracted` | BOOLEAN | NOT NULL, DEFAULT 0 | Version retracted flag |
| `retracted_at` | INTEGER | NULL | When retracted |
| `is_prerelease` | BOOLEAN | NOT NULL, DEFAULT 0 | Prerelease flag (computed from semver) |
| `dart_sdk_min` | TEXT | NULL | From pubspec environment.sdk |
| `dart_sdk_max` | TEXT | NULL | From pubspec environment.sdk |
| `flutter_sdk_min` | TEXT | NULL | From pubspec environment.flutter |
| `flutter_sdk_max` | TEXT | NULL | From pubspec environment.flutter |
| `published_at` | INTEGER | NOT NULL | Unix ms |

**Primary Key:** `(package_name, version)`

**Indexes:**
- `idx_versions_package` on `package_name`
- `idx_versions_published` on `published_at DESC`

**Notes:**
- `pubspec_json` is the full pubspec content serialized as JSON (not YAML)
- `readme_content` and `changelog_content` are the raw Markdown extracted from the tarball
- `is_prerelease` is set based on `pub_semver`'s `Version.isPreRelease`
- Retracted versions remain in the database and are downloadable but marked in API responses

---

### publishers

Admin-created organizations.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | Slug (e.g., "acme") |
| `display_name` | TEXT | NOT NULL | Human-readable name |
| `description` | TEXT | NULL | Publisher description |
| `website_url` | TEXT | NULL | Publisher website |
| `contact_email` | TEXT | NULL | Contact email |
| `created_by` | TEXT | NOT NULL, FK → users | Admin who created |
| `created_at` | INTEGER | NOT NULL | Unix ms |
| `updated_at` | INTEGER | NOT NULL | Unix ms |

---

### publisher_members

Join table: publisher membership and roles.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `publisher_id` | TEXT | NOT NULL, FK → publishers | Publisher |
| `user_id` | TEXT | NOT NULL, FK → users | Member |
| `role` | TEXT | NOT NULL | `admin` or `member` |
| `created_at` | INTEGER | NOT NULL | Unix ms |

**Primary Key:** `(publisher_id, user_id)`

**Roles:**
- `admin` — can publish, manage members, update publisher info
- `member` — can publish to publisher-owned packages

---

### package_likes

User favorites.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `user_id` | TEXT | NOT NULL, FK → users | Who liked |
| `package_name` | TEXT | NOT NULL, FK → packages | What was liked |
| `created_at` | INTEGER | NOT NULL | Unix ms |

**Primary Key:** `(user_id, package_name)`

**Indexes:**
- `idx_likes_package` on `package_name` (for count queries)

**Notes:**
- On insert/delete, also update `packages.likes_count` (trigger or application code)

---

### upload_sessions

Transient table for in-progress uploads.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | Upload GUID (UUID v4) |
| `user_id` | TEXT | NOT NULL, FK → users | Uploader |
| `temp_path` | TEXT | NOT NULL | Server-local temp file path |
| `state` | TEXT | NOT NULL | `pending`, `received`, `processing`, `complete`, `failed` |
| `created_at` | INTEGER | NOT NULL | Unix ms |
| `expires_at` | INTEGER | NOT NULL | Unix ms (created + 10 minutes) |

**Notes:**
- Rows are deleted after successful finalization or failure
- Background cleanup deletes rows where `expires_at < now` and removes temp files
- Rate limit: max 3 pending sessions per user

---

### audit_log

Append-only event log.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | UUID v4 |
| `created_at` | INTEGER | NOT NULL | Unix ms |
| `kind` | TEXT | NOT NULL | Event type (see below) |
| `agent_id` | TEXT | NULL, FK → users | Acting user (NULL for system) |
| `package_name` | TEXT | NULL | Related package |
| `version` | TEXT | NULL | Related version |
| `publisher_id` | TEXT | NULL | Related publisher |
| `summary` | TEXT | NOT NULL | Human-readable description |
| `data_json` | TEXT | NOT NULL | JSON payload (flexible) |

**Indexes:**
- `idx_audit_created` on `created_at DESC`
- `idx_audit_package` on `package_name`
- `idx_audit_agent` on `agent_id`

**Event Kinds:**

| Kind | Description |
|------|-------------|
| `package.created` | New package first published |
| `package.version_published` | New version published |
| `package.version_retracted` | Version retracted |
| `package.version_unretracted` | Version unretracted |
| `package.discontinued` | Package marked discontinued |
| `package.options_updated` | Package options changed |
| `package.uploader_added` | Uploader added |
| `package.uploader_removed` | Uploader removed |
| `package.publisher_changed` | Package transferred to publisher |
| `package.deleted` | Package deleted by admin |
| `publisher.created` | Publisher created |
| `publisher.updated` | Publisher info updated |
| `publisher.member_added` | Member added to publisher |
| `publisher.member_removed` | Member removed from publisher |
| `user.created` | User account created |
| `user.login` | User logged in |
| `user.disabled` | User account disabled |
| `user.token_created` | API token created |
| `user.token_revoked` | API token revoked |
| `admin.package_deleted` | Admin deleted a package |
| `admin.version_deleted` | Admin deleted a version |

---

### package_fts (FTS5 Virtual Table)

SQLite full-text search index.

```sql
CREATE VIRTUAL TABLE package_fts USING fts5(
  package_name UNINDEXED,
  name,
  description,
  readme_excerpt,
  tags,
  content='packages',
  content_rowid='rowid',
  tokenize='unicode61 remove_diacritics 1'
);
```

**Synchronized via triggers:**

```sql
-- After INSERT on packages
CREATE TRIGGER packages_ai AFTER INSERT ON packages BEGIN
  INSERT INTO package_fts(rowid, package_name, name, description, readme_excerpt, tags)
  VALUES (new.rowid, new.name, new.name, '', '', '');
END;

-- After UPDATE on packages
CREATE TRIGGER packages_au AFTER UPDATE ON packages BEGIN
  INSERT INTO package_fts(package_fts, rowid, package_name, name, description, readme_excerpt, tags)
  VALUES ('delete', old.rowid, old.name, old.name, '', '', '');
  INSERT INTO package_fts(rowid, package_name, name, description, readme_excerpt, tags)
  VALUES (new.rowid, new.name, new.name, '', '', '');
END;

-- After DELETE on packages
CREATE TRIGGER packages_ad AFTER DELETE ON packages BEGIN
  INSERT INTO package_fts(package_fts, rowid, package_name, name, description, readme_excerpt, tags)
  VALUES ('delete', old.rowid, old.name, old.name, '', '', '');
END;
```

**Notes:**
- `readme_excerpt` stores first 2KB of README for search (not full content)
- `tags` stores space-separated tag tokens (e.g., `"sdk:dart sdk:flutter platform:android"`)
- The description and readme_excerpt are updated by the `SearchIndex.indexPackage()` method
  after a new version is published
- FTS5 queries use `MATCH` with optional `*` suffix for prefix search

---

## Blob Storage Layout

### Filesystem (Default)

```
/data/blobs/
├── my_package/
│   ├── 1.0.0.tar.gz
│   ├── 1.1.0.tar.gz
│   └── 2.0.0.tar.gz
├── other_package/
│   └── 0.1.0.tar.gz
└── ...
```

**Atomic writes:** Files are written to `<path>.tmp.<ulid>` first, then
`File.rename()` for atomicity. Orphaned `.tmp.*` files are cleaned up
on server startup.

### S3-Compatible

```
s3://club-packages/
├── my_package/1.0.0.tar.gz
├── my_package/1.1.0.tar.gz
├── my_package/2.0.0.tar.gz
├── other_package/0.1.0.tar.gz
└── ...
```

---

## Migration Strategy

### Approach

Numbered SQL scripts tracked in a `schema_migrations` table.

```
migrations/sql/
├── 001_initial_schema.sql      # users, api_tokens, packages, package_versions
├── 002_uploaders_likes.sql     # package_uploaders, package_likes
├── 003_publishers.sql          # publishers, publisher_members
├── 004_upload_sessions.sql     # upload_sessions
├── 005_audit_log.sql           # audit_log
├── 006_fts_index.sql           # package_fts + triggers
└── ...
```

### Migration Tracking Table

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
  script_name   TEXT PRIMARY KEY,
  script_sha256 TEXT NOT NULL,
  executed_at   TEXT NOT NULL
);
```

### Rules

1. Scripts are **immutable** once applied (SHA-256 hash check on startup)
2. Applied in filename sort order (`001_` before `002_`)
3. Each script runs inside a **transaction** (all-or-nothing)
4. Migration runner executes on every server startup before accepting traffic
5. To modify schema: add a new numbered script, never edit existing ones

### SQLite Pragmas

Set on every database open:

```sql
PRAGMA journal_mode = WAL;        -- Write-Ahead Logging for concurrent reads
PRAGMA synchronous = NORMAL;      -- Safe with WAL mode
PRAGMA foreign_keys = ON;         -- Enforce foreign key constraints
PRAGMA busy_timeout = 5000;       -- Wait 5s on lock contention
```

---

## MetadataStore Interface

Complete Dart interface (lives in `club_core`):

```dart
abstract interface class MetadataStore {
  // Lifecycle
  Future<void> open();
  Future<void> close();
  Future<void> runMigrations();

  // Packages
  Future<Package?> lookupPackage(String name);
  Future<Package> createPackage(PackageCompanion companion);
  Future<Package> updatePackage(String name, PackageCompanion companion);
  Future<void> deletePackage(String name);
  Future<Page<Package>> listPackages({int limit, String? pageToken});

  // Package Versions
  Future<PackageVersion?> lookupVersion(String package, String version);
  Future<PackageVersion> createVersion(PackageVersionCompanion companion);
  Future<PackageVersion> updateVersion(String package, String version, PackageVersionCompanion companion);
  Future<void> deleteVersion(String package, String version);
  Future<List<PackageVersion>> listVersions(String package);
  Future<PackageVersion?> latestVersion(String package);
  Future<PackageVersion?> latestStableVersion(String package);

  // Users
  Future<User?> lookupUserById(String userId);
  Future<User?> lookupUserByEmail(String email);
  Future<User> createUser(UserCompanion companion);
  Future<User> updateUser(String userId, UserCompanion companion);
  Future<void> deleteUser(String userId);

  // Auth Tokens
  Future<AuthToken?> lookupToken(String tokenHash);
  Future<AuthToken> createToken(AuthTokenCompanion companion);
  Future<void> revokeToken(String tokenId);
  Future<List<AuthToken>> listTokensForUser(String userId);

  // Publishers
  Future<Publisher?> lookupPublisher(String publisherId);
  Future<Publisher> createPublisher(PublisherCompanion companion);
  Future<Publisher> updatePublisher(String publisherId, PublisherCompanion companion);
  Future<void> deletePublisher(String publisherId);
  Future<List<PublisherMember>> listPublisherMembers(String publisherId);
  Future<void> addPublisherMember(PublisherMemberCompanion companion);
  Future<void> removePublisherMember(String publisherId, String userId);
  Future<bool> isMemberAdmin(String publisherId, String userId);

  // Uploaders
  Future<List<String>> listUploaders(String packageName);
  Future<void> addUploader(String packageName, String userId);
  Future<void> removeUploader(String packageName, String userId);
  Future<bool> isUploader(String packageName, String userId);

  // Likes
  Future<bool> hasLike(String userId, String packageName);
  Future<void> likePackage(String userId, String packageName);
  Future<void> unlikePackage(String userId, String packageName);
  Future<int> likeCount(String packageName);
  Future<List<String>> likedPackages(String userId);

  // Upload Sessions
  Future<UploadSession?> lookupUploadSession(String id);
  Future<void> createUploadSession(UploadSessionCompanion companion);
  Future<void> updateUploadSessionState(String id, UploadState state);
  Future<void> deleteExpiredUploadSessions();
  Future<int> countPendingUploads(String userId);

  // Audit Log
  Future<void> appendAuditLog(AuditLogCompanion companion);
  Future<List<AuditLogRecord>> queryAuditLog({
    String? packageName,
    String? agentId,
    int limit = 50,
    DateTime? before,
  });

  // Transactions
  Future<T> transaction<T>(Future<T> Function(MetadataStore tx) action);
}
```

---

## BlobStore Interface

```dart
abstract interface class BlobStore {
  Future<void> open();
  Future<void> close();

  Future<BlobInfo> put(String package, String version, Stream<List<int>> bytes,
      {bool overwrite = false});
  Future<Stream<List<int>>> get(String package, String version);
  Future<BlobInfo?> info(String package, String version);
  Future<bool> exists(String package, String version);
  Future<void> delete(String package, String version);
  Future<List<String>> listVersions(String package);
  Future<List<String>> listPackages();
  Future<Uri?> signedDownloadUrl(String package, String version,
      {Duration expiry = const Duration(hours: 1)});
}
```

---

## SearchIndex Interface

```dart
abstract interface class SearchIndex {
  Future<void> open();
  Future<void> close();
  Future<bool> isReady();
  Future<void> indexPackage(IndexDocument doc);
  Future<void> removePackage(String package);
  Future<SearchResult> search(SearchQuery query);
  Future<void> reindex(Stream<IndexDocument> documents);
}
```

---

## Backup & Restore

### SQLite

```bash
# Backup (safe under live writes)
sqlite3 /data/db/club.db ".backup /backups/club-$(date +%Y%m%d).db"

# Restore
cp /backups/club-20260409.db /data/db/club.db
```

### PostgreSQL

```bash
# Backup
pg_dump -Fc club > /backups/club-$(date +%Y%m%d).dump

# Restore
pg_restore -d club /backups/club-20260409.dump
```

### Blob Storage

```bash
# Filesystem backup
tar -czf /backups/packages-$(date +%Y%m%d).tar.gz -C /data packages/

# S3 backup
aws s3 sync s3://club-packages /backups/packages/
```

### Volume-Based Persistence

The `/data` directory is the single source of truth for server state —
SQLite DB, package tarballs, dartdoc HTML, and Flutter SDK installs all
live under it. If you mount `/data` as a Docker volume (or a host
bind-mount), your data survives container recreation: a fresh container
started against the same volume picks everything up and comes back
ready. SDK directories are rediscovered and their setup is re-run
automatically. A first-class backup/restore feature is planned for a
future release.
