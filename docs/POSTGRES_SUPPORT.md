# club — PostgreSQL Backend (Deferred Design)

**Status:** Deferred. Not implemented. Kept as a ready-to-execute design if demand arises.

**Last updated:** 2026-04-17

---

## Why this is deferred

club is a self-hosted private Dart package registry. Typical deployments
are single-node Docker, with tens to a few thousand packages, dominated by
read traffic (`dart pub get` metadata lookups) and occasional writes
(`dart pub publish`). For that workload, SQLite is not just the default —
it is genuinely the better choice. Adding Postgres would double the test
matrix and long-term maintenance surface for a benefit that most users
will never see.

This document captures the full design so the work can be picked up
quickly when a concrete user need appears.

---

## When to revisit

Implement this when one or more of the following becomes real:

- A user explicitly requires Postgres for corporate data-governance
  reasons ("all persistent state lives in managed Postgres").
- A deployment needs HA / multi-instance horizontally-scaled servers
  behind a load balancer (requires shared DB + shared blob storage).
- A deployment has existing Postgres operational infrastructure
  (backup, replication, monitoring) that it wants to reuse.
- Scale exceeds what a single SQLite instance comfortably handles
  (unlikely for a private registry; possible if club is ever used for
  a large public mirror).

Without one of these, SQLite is strictly better for this product.

---

## SQLite vs Postgres — analysis for this product

### SQLite advantages (the default)

- **Zero ops.** One file on a mounted volume. Backup = copy the file.
  No separate service to run, monitor, upgrade, or scale.
- **Faster for this workload.** In-process reads hit the page cache at
  RAM speed. Postgres adds a network roundtrip per query, which
  measurably increases `dart pub get` latency.
- **Single-writer is a non-issue here.** Publishes are rare. WAL mode
  already makes concurrent reads + occasional writes smooth.
- **FTS5 is excellent** for package search, built-in, no extensions.
- **Single-binary deployment** stays simple. The Docker image remains
  self-contained.

### Postgres advantages (niche for this product)

- **Horizontal scale.** Multiple server pods against one DB. Needs
  shared blob storage too (already supported via S3/GCS).
- **Managed service integration.** RDS/Cloud SQL/Supabase/etc. give
  backups, PITR, replicas out of the box.
- **Operator familiarity.** Ops teams that already run Postgres have
  playbooks and tooling; adding SQLite is a net-new artifact for them.
- **Larger datasets.** Trivially handles millions of packages with the
  right indexes. SQLite could too, but Postgres does it with more
  headroom and better analytic tooling.

### Hidden costs of supporting both

- Every future query, schema change, and feature becomes a two-backend
  problem. Migrations must be written twice.
- FTS5 and tsvector behave differently. Relevance quality diverges
  subtly — users on different backends see different search results
  for the same query.
- Test matrix doubles. CI needs a Postgres service.
- The `INSERT OR IGNORE` / `INSERT OR REPLACE` family has no single
  clean abstraction; dialect awareness leaks into the store unless we
  add helpers (planned — see below).

### Product-level conclusion

For this product's actual workload — single-node self-hosted private
registries, read-dominated, tens to thousands of packages — **SQLite is
strictly better**. Postgres is a niche advantage for users with
specific ops requirements (HA, compliance, existing Postgres infra).

The deferral is not "we haven't gotten to it yet." It is a deliberate
choice not to double the maintenance surface for a benefit most users
will never see. Implement only when a real user need materializes.

---

## Decision log

Each decision below went through an explicit alternatives-vs-tradeoffs
review. They are recorded here so a future implementer can see what was
weighed and why the chosen option was picked — and can revisit if
product context shifts.

### Summary

| # | Decision | Chosen option |
|---|---|---|
| 1 | Code organization | `drift_postgres` + shared `ClubDatabase` |
| 2 | Full-text search on Postgres | `tsvector` + GIN in a dedicated `PostgresSearchIndex` |
| 3 | Migration system | Versioned with `schema_migrations` table |
| 4 | Postgres schema types | Mirror SQLite (`BIGINT` / `TEXT`) |
| 5 | Migration rollout for existing SQLite DBs | Auto-seed on first boot |
| 6 | Data directory | New `DATA_DIR` env var |
| 7 | Docker examples | Commented `postgres:` service + `.env.example` entries |
| 8 | Test strategy | Smoke test gated on `POSTGRES_TEST_URL` |

### 1. Code organization

**Alternatives considered:**

- **(A) `drift_postgres` + shared `ClubDatabase`** — one set of store
  classes, parameterized by a `Dialect` enum. Drift transparently
  rewrites `?` → `$1` placeholders. Dialect-specific SQL fragments
  (~3 sites) hidden behind helpers on `ClubDatabase`.
- **(B) Separate `packages/club_db_postgres` package** — fully parallel
  implementation using the `postgres` package directly. Zero shared
  code, zero dialect branches.
- **(C) Dialect abstraction inside `club_db`** — formal `SqlDialect`
  interface, store classes dialect-parameterized throughout. Cleanest
  long-term, heaviest upfront.

**Chosen: (A).** Store classes stay as one implementation. The
divergent SQL is genuinely tiny (3 call sites in ~1,300 lines). (B)
would duplicate ~1,500 lines and double the maintenance surface for
every future query. (C) is over-engineered for the handful of divergent
statements — the project's "minimal dependencies, no premature
abstraction" philosophy (from CLAUDE.md) argues against it.

**Tradeoff accepted:** A thin `Dialect` enum leaks into `ClubDatabase`.
Two helper methods on it (`insertOrIgnore`, `insertOrReplace`)
centralize the leak. In exchange we get a single source of truth for
every query.

### 2. Full-text search on Postgres

**Alternatives considered:**

- **(A) `tsvector` + GIN in a new `PostgresSearchIndex`** — native
  Postgres FTS, weighted columns (`setweight` A/B/C/D), `ts_rank`.
  Production-grade, no extension required.
- **(B) `pg_trgm` + `ILIKE`** — simpler to implement. Handles typos
  well via trigram similarity. No stemming, lower relevance quality.
  Requires `CREATE EXTENSION pg_trgm` (needs privilege).
- **(C) Defer — require Meilisearch for Postgres users** — make it a
  hard error to combine `DB_BACKEND=postgres` with
  `SEARCH_BACKEND=sqlite`. Smallest scope, but couples two unfinished
  features.

**Chosen: (A).** Matches FTS5's relevance quality most closely and
keeps the feature self-contained. `simple` dictionary chosen over
`english` because package names are identifiers (`flutter_blue_plus`,
`dio`) — stemming would break literal matches and strip short tokens
like `http`.

**Tradeoff accepted:** `PostgresSearchIndex` is a full rewrite of
`SqliteSearchIndex` (~60 lines). There is no sharing with the FTS5
implementation. This is expected — FTS5 `MATCH` and `@@` / `ts_rank`
are semantically different systems.

### 3. Migration system

**Alternatives considered:**

- **(A) Introduce versioned migrations** with a `schema_migrations`
  table. Numbered migrations per logical change. Applies to both
  backends.
- **(B) Keep the current flat idempotent list** and extend it to
  Postgres via `CREATE TABLE IF NOT EXISTS` / `ALTER TABLE ... ADD
  COLUMN IF NOT EXISTS` (Postgres supports both). Same "evolve in
  place" philosophy as today.

**Chosen: (A).** The current SQLite system swallows `ALTER TABLE`
duplicate-column errors by string match — fragile, and silently papers
over real schema drift. Postgres error messages differ, so that error-
match trick would not port cleanly. A proper versioned system is
stricter, auditable, and a one-time cost.

**Tradeoff accepted:** Larger refactor than extending the idempotent
list. Requires a rollout strategy for existing SQLite deployments (see
decision 5).

### 4. Postgres schema types

**Alternatives considered:**

- **(A) Mirror SQLite exactly** — `BIGINT` for ms-timestamps and bools,
  `TEXT` for JSON. Maximizes code reuse: every `_boolToInt` /
  `_intToDateTime` / `jsonEncode` helper works unchanged.
- **(B) Native Postgres types** — `BOOLEAN`, `JSONB`, `TIMESTAMPTZ`.
  More idiomatic, better query ergonomics. Requires parallel
  row-decoding paths in the store and divergent SELECT projections.

**Chosen: (A).** The goal of the initial implementation is "Postgres
works correctly," not "Postgres is maximally idiomatic." Mirroring
SQLite lets the ~1,300-line metadata store ship against both backends
with no decoder changes. Native types can come in a follow-up PR.

**Tradeoff accepted:** Postgres operators looking at the raw DB see
`INTEGER` booleans and ms-epoch timestamps rather than Postgres-native
forms. Acceptable because the app is the only direct reader of the
schema — no external reporting/BI tools are expected to hit the DB.

### 5. Migration rollout for existing SQLite deployments

**Alternatives considered:**

- **(A) Auto-seed on first boot** — if legacy schema tables exist
  (detect via `sqlite_master WHERE name='users'`) but
  `schema_migrations` does not, create the table and insert all
  current migration IDs as already-applied.
- **(B) Clean break** — versioned system only works for fresh
  databases. Document that existing deployments must drop and rebuild.
- **(C) Reverse decision 3** and keep the flat idempotent approach
  for both backends.

**Chosen: (A).** (B) breaks existing self-hosted deployments, which is
unacceptable for a product whose users run long-lived instances with
real data. (C) sidesteps the rollout problem but loses the benefits
that motivated decision 3.

**Tradeoff accepted:** The seed path contains SQLite-specific lookup
code (`sqlite_master`). Acceptable because it is strictly a
one-way-door guard — runs once, is a no-op on all subsequent boots,
and is explicitly gated behind `if (dialect == Dialect.sqlite)`.

### 6. Data directory

**Alternatives considered:**

- **(A) Add `DATA_DIR` env var** (default `/data`). Scoring log lives
  there. `SQLITE_PATH` and `BLOB_PATH` defaults derive from it when
  not set explicitly. Unifies "where persistent state lives" across
  backends.
- **(B) Add `SCORING_LOG_PATH`** — narrow env var for just the scoring
  log. Smallest change, but misses the opportunity to unify paths.
- **(C) Reuse an existing var** (derive from `BLOB_PATH` parent or
  `TEMP_DIR`). Zero new vars.

**Chosen: (A).** The scoring log currently derives from the SQLite
file path (`File(config.sqlitePath).parent.path`), which is semantically
wrong for a Postgres deployment. A single `DATA_DIR` concept reads more
clearly in configs and gives operators one obvious knob. Existing
deployments that already set `SQLITE_PATH` / `BLOB_PATH` explicitly are
unaffected.

**Tradeoff accepted:** One new env var to document. Mitigated by the
fact that it has a sensible default (`/data`) that matches current
behavior.

### 7. Docker examples

**Alternatives considered:**

- **(A) Commented `postgres:` service** in `docker-compose.yml` +
  `DB_BACKEND=postgres` / `POSTGRES_URL=...` in `.env.example`.
  Operators uncomment to opt in.
- **(B) `.env.example` only** — document the env vars, leave compose
  file SQLite-only so the default dev experience stays clean.
- **(C) Skip Docker changes entirely** — operators figure it out.

**Chosen: (A).** Discovery matters for deferred-then-enabled features.
Commented examples are free to add, free to ignore, and save operators
from having to read implementation docs to find the right compose
block.

### 8. Test strategy

**Alternatives considered:**

- **(A) Smoke test** — open DB, run migrations, insert user / package /
  version, search, close. Gated on `POSTGRES_TEST_URL`, skipped when
  unset. Catches 90% of regressions without CI burden.
- **(B) Full interface-level contract suite** — abstract test suite
  exercising every `MetadataStore` / `SearchIndex` / `SettingsStore`
  method against both backends. 500–700 lines of new test code.
- **(C) No automated tests** — manual verification only. Matches the
  current zero-test state of `club_db`.

**Chosen: (A).** (C) is honest given the current state but leaves zero
safety net on the harder-to-debug backend. (B) is the right long-term
target but is out of scope for the initial PR — no test infrastructure
exists to build on yet. The smoke test is the smallest useful unit.

**Tradeoff accepted:** Interface-level coverage gaps remain. The
smoke test catches wiring and migration bugs but not per-method
semantic regressions. Full contract tests are noted as a future
follow-up.

---

## Implementation blueprint

### Package dependencies — `packages/club_db/pubspec.yaml`

```yaml
dependencies:
  drift: ^2.32.1        # existing
  drift_postgres: ^1.3.0
  postgres: ^3.5.4      # pulled transitively; pin for clarity
```

Verify `drift_postgres` version range matches the installed `drift`
version at the time of implementation.

### File map

**`packages/club_db/` — new or changed:**

| Path | Status | Purpose |
|---|---|---|
| `lib/src/database.dart` | Changed | Add `Dialect` enum, `openSqlite()` / `openPostgres()` factories, `insertOrIgnore()` / `insertOrReplace()` dialect helpers. PRAGMAs guarded behind `Dialect.sqlite`. |
| `lib/src/sql/migration.dart` | New | `class Migration { int id; String name; String sql; }` |
| `lib/src/sql/migrations_sqlite.dart` | New | Current `schema.dart` content split into ~21 numbered migrations. |
| `lib/src/sql/migrations_postgres.dart` | New | Same IDs, Postgres-compatible DDL. `package_fts` as real table with `tsvector` + `GIN`. |
| `lib/src/sql/schema.dart` | Deleted | Content lives in the two migration files. |
| `lib/src/migrations.dart` | Rewritten | `schema_migrations` table + legacy-SQLite auto-seeding. |
| `lib/src/drift_metadata_store.dart` | Renamed | Was `sqlite_metadata_store.dart`. Class `DriftMetadataStore`. Fix 3 `INSERT OR IGNORE` / `INSERT OR REPLACE` sites to use helpers. |
| `lib/src/drift_settings_store.dart` | Renamed | Was `sqlite_settings_store.dart`. Class `DriftSettingsStore`. No SQL changes. |
| `lib/src/sqlite_search_index.dart` | Unchanged | Genuinely SQLite-only (FTS5). Name stays honest. |
| `lib/src/postgres_search_index.dart` | New | `tsvector` + GIN + `setweight` + `ts_rank` + `simple` config. |
| `lib/club_db.dart` | Changed | Update exports for renamed classes. |
| `test/postgres_smoke_test.dart` | New | Gated on `POSTGRES_TEST_URL`. Schema-scoped isolation. |
| `dart_test.yaml` | New | `tags: postgres:` |

**`packages/club_server/` — changes:**

| Path | Change |
|---|---|
| `lib/src/config/env_keys.dart` | Add `DATA_DIR`. |
| `lib/src/config/app_config.dart` | Add `dataDir` field (default `/data`). Resolve `sqlitePath` / `blobPath` defaults from it. Add `SearchBackend.postgres` enum value. Auto-resolve `searchBackend` to `postgres` when `dbBackend == postgres` and nothing else is set. |
| `lib/src/bootstrap.dart` | Fill in `DbBackend.postgres` case. Use `DriftMetadataStore` / `DriftSettingsStore`. Use `PostgresSearchIndex` for `SearchBackend.postgres`. Replace `File(config.sqlitePath).parent.path` with `config.dataDir`. |

**Docker:**

| Path | Change |
|---|---|
| `docker/.env.example` | Add commented `DB_BACKEND=postgres`, `POSTGRES_URL=postgres://user:pass@host:5432/club`, `DATA_DIR=/data`. |
| `docker/docker-compose.yml` | Add commented `postgres:` service block (image `postgres:16-alpine`, named volume `pgdata`). |

---

### ClubDatabase shape

```dart
enum Dialect { sqlite, postgres }

class ClubDatabase {
  ClubDatabase._(this._db, this.dialect);

  final _RawDatabase _db;
  final Dialect dialect;

  static Future<ClubDatabase> openSqlite({String? path}) async { ... }

  static Future<ClubDatabase> openPostgres(String url) async {
    final endpoint = _parsePostgresUrl(url);
    final executor = PgDatabase(endpoint: endpoint);
    return ClubDatabase._(_RawDatabase(executor), Dialect.postgres);
  }

  /// INSERT that silently skips unique-constraint conflicts.
  Future<void> insertOrIgnore(
    String table,
    List<String> columns,
    List<Object?> values,
  ) {
    final cols = columns.join(', ');
    final placeholders = List.filled(values.length, '?').join(', ');
    final sql = dialect == Dialect.sqlite
        ? 'INSERT OR IGNORE INTO $table ($cols) VALUES ($placeholders)'
        : 'INSERT INTO $table ($cols) VALUES ($placeholders) '
          'ON CONFLICT DO NOTHING';
    return execute(sql, values);
  }

  /// INSERT that replaces the existing row on conflict.
  Future<void> insertOrReplace(
    String table,
    List<String> columns,
    List<String> conflictKey,
    List<Object?> values,
  ) {
    final cols = columns.join(', ');
    final placeholders = List.filled(values.length, '?').join(', ');
    if (dialect == Dialect.sqlite) {
      return execute(
        'INSERT OR REPLACE INTO $table ($cols) VALUES ($placeholders)',
        values,
      );
    }
    final setClause = columns
        .where((c) => !conflictKey.contains(c))
        .map((c) => '$c = excluded.$c')
        .join(', ');
    return execute(
      'INSERT INTO $table ($cols) VALUES ($placeholders) '
      'ON CONFLICT(${conflictKey.join(', ')}) DO UPDATE SET $setClause',
      values,
    );
  }
}
```

### Migration runner

```dart
Future<void> runMigrations(ClubDatabase db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS schema_migrations (
      id         INTEGER PRIMARY KEY NOT NULL,
      name       TEXT NOT NULL,
      applied_at INTEGER NOT NULL
    )
  ''');

  final migrations = db.dialect == Dialect.sqlite
      ? sqliteMigrations
      : postgresMigrations;

  if (db.dialect == Dialect.sqlite) {
    await _seedIfLegacy(db, migrations);
  }

  final applied = await _loadApplied(db);
  for (final m in migrations) {
    if (applied.contains(m.id)) continue;
    await db.transaction(() async {
      await db.execute(m.sql);
      await db.execute(
        'INSERT INTO schema_migrations (id, name, applied_at) VALUES (?, ?, ?)',
        [m.id, m.name, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
    });
  }
}

Future<void> _seedIfLegacy(ClubDatabase db, List<Migration> migrations) async {
  final rows = await db.select('SELECT COUNT(*) AS cnt FROM schema_migrations');
  if (rows.first.read<int>('cnt') > 0) return;

  // SQLite-only meta table lookup.
  final tableCheck = await db.select(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='users'",
  );
  if (tableCheck.isEmpty) return; // fresh install

  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  for (final m in migrations) {
    await db.execute(
      'INSERT OR IGNORE INTO schema_migrations (id, name, applied_at) '
      'VALUES (?, ?, ?)',
      [m.id, m.name, now],
    );
  }
}
```

### Migration ID map

One numbered entry per logical change. IDs match across both dialect
files.

| ID | Name | Notes |
|---|---|---|
| 1 | create_users | Without avatar columns. |
| 2 | create_api_tokens | |
| 3 | create_user_invites | |
| 4 | create_publishers | |
| 5 | create_publisher_members | |
| 6 | create_packages | |
| 7 | create_package_versions | |
| 8 | create_package_uploaders | |
| 9 | create_package_likes | |
| 10 | create_upload_sessions | |
| 11 | create_audit_log | |
| 12 | create_package_fts | SQLite: `CREATE VIRTUAL TABLE ... USING fts5`. Postgres: real table with `tsvector` + GIN. |
| 13 | create_indexes_core | All initial `CREATE INDEX IF NOT EXISTS` statements. |
| 14 | add_user_avatar | `ALTER TABLE users ADD COLUMN avatar TEXT` + `has_avatar INTEGER NOT NULL DEFAULT 0`. |
| 15 | create_package_scores | |
| 16 | create_server_settings | |
| 17 | create_sdk_installs | Without `archive_url` (already removed). |
| 18 | create_dartdoc_status | |
| 19 | create_download_counts | |
| 20 | create_indexes_extended | Scores / SDK / dartdoc / download indexes. |

Migration 17 defines `sdk_installs` directly without the removed
`archive_url` column, so the legacy SQLite-only `DROP COLUMN` statement
at the bottom of `schema.dart` becomes a no-op for fresh installs and
does not need a migration entry. For legacy SQLite deployments the
auto-seeding path skips ahead — the column removal has already
happened in their live DB.

### Postgres search

Schema (migration 12, Postgres variant):

```sql
CREATE TABLE IF NOT EXISTS package_fts (
  package_name TEXT PRIMARY KEY NOT NULL,
  tsv          TSVECTOR NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_package_fts_tsv
  ON package_fts USING GIN(tsv);
```

Index + search shape:

```sql
-- indexPackage (upsert)
INSERT INTO package_fts (package_name, tsv)
VALUES (
  ?,
  setweight(to_tsvector('simple', ?),              'A') ||
  setweight(to_tsvector('simple', coalesce(?, '')), 'B') ||
  setweight(to_tsvector('simple', coalesce(?, '')), 'C') ||
  setweight(to_tsvector('simple', coalesce(?, '')), 'D')
)
ON CONFLICT(package_name) DO UPDATE SET tsv = excluded.tsv;
-- args: [package, name, description, tags_space_joined, readme_excerpt]

-- search (relevance)
SELECT pf.package_name, ts_rank(pf.tsv, query) AS rank
FROM package_fts pf, to_tsquery('simple', ?) query
WHERE pf.tsv @@ query
ORDER BY rank DESC
LIMIT ? OFFSET ?;

-- search (updated / likes / created)
SELECT pf.package_name
FROM package_fts pf
JOIN packages p ON p.name = pf.package_name,
     to_tsquery('simple', ?) query
WHERE pf.tsv @@ query
ORDER BY p.updated_at DESC   -- or p.likes_count DESC / p.created_at ASC
LIMIT ? OFFSET ?;
```

Sanitize user input into `to_tsquery` form: split on whitespace,
drop tokens containing `&`, `|`, `!`, `:`, `'`, `(`, `)`, `<`, join
the remainder with ` & `. If empty after sanitation, fall back to
`_listAll` (matches the SQLite `SqliteSearchIndex._listAll` path).

### Dialect-divergent call sites in the store

Only three. All three become single-line helper calls:

| Method | Current SQL | After |
|---|---|---|
| `addPublisherMember` | `INSERT OR REPLACE INTO publisher_members ...` | `_db.insertOrReplace('publisher_members', cols, ['publisher_id', 'user_id'], vals)` |
| `addUploader` | `INSERT OR IGNORE INTO package_uploaders ...` | `_db.insertOrIgnore('package_uploaders', cols, vals)` |
| `likePackage` | `INSERT OR IGNORE INTO package_likes ...` | `_db.insertOrIgnore('package_likes', cols, vals)` |

Everything else in `sqlite_metadata_store.dart` (~1,300 lines) — including
`ON CONFLICT ... DO UPDATE SET` upserts, `COALESCE`, `CASE`, `LIKE`,
`NOT EXISTS` subqueries — is standard SQL that works unchanged on both.

### Bootstrap wiring

`packages/club_server/lib/src/bootstrap.dart` DB switch becomes:

```dart
late final ClubDatabase clubDb;
switch (config.dbBackend) {
  case DbBackend.sqlite:
    clubDb = await ClubDatabase.openSqlite(path: config.sqlitePath);
  case DbBackend.postgres:
    final url = config.postgresUrl;
    if (url == null || url.isEmpty) {
      throw StateError('POSTGRES_URL must be set when DB_BACKEND=postgres.');
    }
    clubDb = await ClubDatabase.openPostgres(url);
}
final store = DriftMetadataStore(clubDb);
await store.runMigrations();
metadataStore = store;
```

Search switch:

```dart
switch (config.searchBackend) {
  case SearchBackend.sqlite:
    searchIndex = SqliteSearchIndex(clubDb);
  case SearchBackend.postgres:
    searchIndex = PostgresSearchIndex(clubDb);
  case SearchBackend.meilisearch:
    throw UnimplementedError('Meilisearch backend not yet implemented.');
}
```

Settings store: unchanged wiring, new name — `DriftSettingsStore(clubDb)`.

`dataDir` line (currently line 156):

```dart
// BEFORE:
final dataDir = File(config.sqlitePath).parent.path;
// AFTER:
final dataDir = config.dataDir;
```

### AppConfig changes

```dart
final String dataDir; // default '/data'

// In fromEnvironment:
final dataDir = str(EnvKeys.dataDir, 'data_dir', '/data');

final rawSqlite = str(EnvKeys.sqlitePath, 'sqlite_path', '');
final sqlitePath = rawSqlite.isNotEmpty ? rawSqlite : '$dataDir/club.db';

final rawBlob = str(EnvKeys.blobPath, 'blob_path', '');
final blobPath = rawBlob.isNotEmpty ? rawBlob : '$dataDir/packages';

// Search backend auto-resolve:
final rawSearch = str(EnvKeys.searchBackend, 'search_backend', '');
final searchBackend = switch (rawSearch) {
  'meilisearch' => SearchBackend.meilisearch,
  'postgres'    => SearchBackend.postgres,
  'sqlite'      => SearchBackend.sqlite,
  _ => dbBackend == DbBackend.postgres
      ? SearchBackend.postgres
      : SearchBackend.sqlite,
};
```

### Smoke test

`packages/club_db/test/postgres_smoke_test.dart`:

- Skip entirely if `POSTGRES_TEST_URL` is unset.
- Per test: `DROP SCHEMA IF EXISTS club_test CASCADE; CREATE SCHEMA club_test; SET search_path = club_test;` — avoids needing `CREATE DATABASE`.
- Cases:
  1. Open → `runMigrations()` → migrations table populated with expected IDs.
  2. Insert user + package + version round-trips through `DriftMetadataStore`.
  3. `PostgresSearchIndex.indexPackage` + `search()` returns the package.
  4. Transaction rollback: begin, insert user, throw, verify the user is absent.
  5. Idempotent re-run: `runMigrations()` again is a no-op.

Run command:

```bash
POSTGRES_TEST_URL=postgres://user:pass@localhost:5432/club_test \
  dart test packages/club_db/test/postgres_smoke_test.dart --tags postgres
```

---

## Risks and gotchas to handle during implementation

1. **`drift_postgres` placeholder rewriting.** Drift rewrites `?` →
   `$1`/`$2` for `customSelect` with `Variable` wrappers. `ClubDatabase.select`
   already uses this path. Verify `customStatement` (used by
   `ClubDatabase.execute`) also rewrites placeholders on
   `drift_postgres`. If not, switch `execute` to route through
   `customSelect(...).get()` and discard rows.

2. **Error-message sniffing.** The current migration runner catches
   `ALTER TABLE` "duplicate column" errors by string match. The new
   versioned system drops this entirely. If any future code relies on
   error-string pattern matching (none found at time of writing),
   double-check it works across dialects.

3. **`sqlite_master` in seed logic.** Only safe on SQLite. The seed
   path is guarded behind `if (dialect == Dialect.sqlite)`.

4. **`ON CONFLICT DO NOTHING` conflict target.** Bare form is safe
   when the table has exactly one unique constraint (the PK). Current
   `package_uploaders` and `package_likes` satisfy that. If additional
   unique indexes are ever added, the bare form may match the wrong
   constraint — prefer naming the target explicitly
   (`ON CONFLICT(col1, col2) DO NOTHING`).

5. **`publisher_members` upsert.** Requires named conflict target
   because the `DO UPDATE SET` clause needs it. Helper handles this
   via the `conflictKey` parameter.

6. **`ts_rank` return type.** Postgres returns `FLOAT4`. Drift surfaces
   this as Dart `double`. `SqliteSearchIndex` already reads `rank` as
   `double`, so the `SearchHit.score` assignment survives unchanged.

7. **`to_tsquery` input sanitation.** User input must never reach
   `to_tsquery` unescaped — it has an operator grammar (`&`, `|`, `!`,
   `:*`) that will throw on malformed input. The sketch in the
   Postgres search section above is correct.

8. **`BIGINT` vs `INTEGER` column types.** The Postgres schema must
   use `BIGINT` (not `INTEGER`) for ms-epoch timestamps. Dart `int`
   is 64-bit; `INTEGER` in Postgres is 32-bit and will overflow ~2038
   for some edge cases. Boolean columns can stay `INTEGER` (4 bytes)
   since values are only 0/1.

9. **Migration 12 (package_fts) DDL is structurally different across
   dialects.** SQLite emits a virtual table; Postgres emits a real
   table plus a GIN index. Both map to the same migration ID, but the
   DDL strings have nothing in common. That is expected.

10. **`drift_postgres` connection pooling.** Transactions are pinned to
    a single connection automatically. `ClubDatabase.transaction`
    delegates to drift's `transaction` and behaves identically on
    both backends.

11. **Legacy SQLite DBs with the removed `archive_url` column.** The
    seed path marks all migrations as applied, so neither the old
    flat-schema `DROP COLUMN` nor a new versioned equivalent runs.
    The live DB already has the column removed (that is why the
    statement was there). Nothing to do.

---

## Open questions to answer at implementation time

- **Verify exact `drift_postgres` version range.** Confirm the installed
  `drift` version is compatible; pin both explicitly.
- **Confirm `customStatement` placeholder rewriting on `drift_postgres`.**
  If not supported, route `execute` through `customSelect` as noted
  above.
- **Decide whether to split `schema.dart` deletion into a separate
  cleanup commit** or do it as part of the migration-system commit.
  The new migration files replace its content entirely.

---

## Out of scope (deliberate)

- **Postgres-idiomatic types** (`BOOLEAN`, `JSONB`, `TIMESTAMPTZ`).
  Deferred to keep the Dart helpers uniform and the diff small.
  Easy follow-up in a separate PR if desired.
- **Multi-tenant Postgres schemas / row-level security.** Not
  relevant for a self-hosted single-tenant registry.
- **Read replicas / connection pooling tuning.** `drift_postgres`
  defaults are fine for a single-node server. Revisit if HA deployment
  becomes a real requirement.
- **Interface-level contract tests** that run both backends through
  the same assertions. Valuable, but out of scope for the initial
  implementation PR. Smoke test covers the baseline.

---

## References

- Current schema: [`packages/club_db/lib/src/sql/schema.dart`](../packages/club_db/lib/src/sql/schema.dart)
- Current metadata store: [`packages/club_db/lib/src/sqlite_metadata_store.dart`](../packages/club_db/lib/src/sqlite_metadata_store.dart)
- Current search index: [`packages/club_db/lib/src/sqlite_search_index.dart`](../packages/club_db/lib/src/sqlite_search_index.dart)
- Bootstrap wiring: [`packages/club_server/lib/src/bootstrap.dart`](../packages/club_server/lib/src/bootstrap.dart)
- AppConfig: [`packages/club_server/lib/src/config/app_config.dart`](../packages/club_server/lib/src/config/app_config.dart)
- `drift_postgres`: https://pub.dev/packages/drift_postgres
- `postgres`: https://pub.dev/packages/postgres
- Postgres full-text search: https://www.postgresql.org/docs/current/textsearch.html
