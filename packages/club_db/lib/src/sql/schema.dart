/// Canonical database schema for new SQLite databases.
///
/// club is unreleased, so schema changes are folded directly into these
/// `CREATE` statements.
const List<String> schema = [
  // ── Schema Metadata ─────────────────────────────────────────
  '''
  CREATE TABLE IF NOT EXISTS club_schema (
    key   TEXT PRIMARY KEY NOT NULL,
    value INTEGER NOT NULL
  )
  ''',

  // ── Users ────────────────────────────────────────────────────
  // `role` supersedes the legacy `is_admin` flag (owner | admin | editor | viewer).
  // `must_change_password` gates login for accounts created via the admin
  // "generated password" flow until the user sets a new one.
  '''
  CREATE TABLE IF NOT EXISTS users (
    user_id              TEXT PRIMARY KEY NOT NULL,
    email                TEXT NOT NULL UNIQUE,
    password_hash        TEXT NOT NULL,
    display_name         TEXT NOT NULL,
    role                 TEXT NOT NULL DEFAULT 'member',
    must_change_password INTEGER NOT NULL DEFAULT 0,
    avatar               TEXT,
    has_avatar           INTEGER NOT NULL DEFAULT 0,
    is_active            INTEGER NOT NULL DEFAULT 1,
    created_at           INTEGER NOT NULL,
    updated_at           INTEGER NOT NULL
  )
  ''',

  // ── API Tokens ──────────────────────────────────────────────
  // Single table backs both user-facing surfaces:
  //   - kind='session': browser session. Short expires_at, slid on use,
  //     hard-capped by absolute_expires_at. User-agent/IP captured at
  //     creation for the "Active sessions" UI.
  //   - kind='pat':     personal access token (API key). Long-lived or
  //     no expiry. Shown to the user once at creation.
  // Both hash the raw secret; the raw value is never stored.
  '''
  CREATE TABLE IF NOT EXISTS api_tokens (
    token_id             TEXT PRIMARY KEY NOT NULL,
    user_id              TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    kind                 TEXT NOT NULL CHECK (kind IN ('session', 'pat')),
    name                 TEXT NOT NULL,
    token_hash           TEXT NOT NULL UNIQUE,
    prefix               TEXT NOT NULL,
    scopes               TEXT NOT NULL DEFAULT '[]',
    expires_at           INTEGER,
    absolute_expires_at  INTEGER,
    user_agent           TEXT,
    client_ip            TEXT,
    client_city          TEXT,
    client_region        TEXT,
    client_country       TEXT,
    client_country_code  TEXT,
    last_used_at         INTEGER,
    revoked_at           INTEGER,
    created_at           INTEGER NOT NULL
  )
  ''',

  // ── User invites ────────────────────────────────────────────
  // One-time invite tokens issued by admins when creating a new user via
  // "send invite link" mode. The DB stores only the SHA-256 hash; the raw
  // token is shown once to the admin. Consumed in exactly one request.
  '''
  CREATE TABLE IF NOT EXISTS user_invites (
    invite_id   TEXT PRIMARY KEY NOT NULL,
    user_id     TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    token_hash  TEXT NOT NULL UNIQUE,
    expires_at  INTEGER NOT NULL,
    used_at     INTEGER,
    created_by  TEXT REFERENCES users(user_id) ON DELETE SET NULL,
    created_at  INTEGER NOT NULL
  )
  ''',

  // ── Publishers ──────────────────────────────────────────────
  //
  // Publisher IDs are either a verified domain (contains a dot,
  // `verified = 1`) or an arbitrary internal slug (no dots,
  // `verified = 0`). The presence/absence of a dot cleanly partitions
  // the two namespaces — see PublisherService for the enforcement.
  '''
  CREATE TABLE IF NOT EXISTS publishers (
    id            TEXT PRIMARY KEY NOT NULL,
    display_name  TEXT NOT NULL,
    description   TEXT,
    website_url   TEXT,
    contact_email TEXT,
    verified      INTEGER NOT NULL DEFAULT 0,
    created_by    TEXT NOT NULL REFERENCES users(user_id),
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL
  )
  ''',

  // ── Publisher Verifications ─────────────────────────────────
  //
  // Pending DNS-based domain verifications. Users request a token, add
  // it as a TXT record on `_club-verify.<domain>`, and complete the
  // verification. Tokens are SHA-256 hashed; the raw value is held only
  // in the user's browser session.
  '''
  CREATE TABLE IF NOT EXISTS publisher_verifications (
    id          TEXT PRIMARY KEY NOT NULL,
    user_id     TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    domain      TEXT NOT NULL,
    token_hash  TEXT NOT NULL,
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL,
    UNIQUE (user_id, domain)
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_pub_verif_expires ON publisher_verifications (expires_at)',

  // ── Publisher Members ───────────────────────────────────────
  '''
  CREATE TABLE IF NOT EXISTS publisher_members (
    publisher_id TEXT NOT NULL REFERENCES publishers(id) ON DELETE CASCADE,
    user_id      TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    role         TEXT NOT NULL,
    created_at   INTEGER NOT NULL,
    PRIMARY KEY (publisher_id, user_id)
  )
  ''',

  // ── Packages ────────────────────────────────────────────────
  '''
  CREATE TABLE IF NOT EXISTS packages (
    name              TEXT PRIMARY KEY NOT NULL,
    publisher_id      TEXT REFERENCES publishers(id) ON DELETE SET NULL,
    latest_version    TEXT,
    latest_prerelease TEXT,
    likes_count       INTEGER NOT NULL DEFAULT 0,
    is_discontinued   INTEGER NOT NULL DEFAULT 0,
    replaced_by       TEXT,
    is_unlisted       INTEGER NOT NULL DEFAULT 0,
    created_at        INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL
  )
  ''',

  // ── Package Versions ────────────────────────────────────────
  // `tags` is a JSON array of derived SDK/platform strings, e.g.
  //   '["sdk:dart","sdk:flutter","platform:android"]'
  // `example_path` / `example_content` mirror the pub.dev convention —
  // see pub_package_reader/file_names.dart for the priority order.
  '''
  CREATE TABLE IF NOT EXISTS package_versions (
    package_name       TEXT NOT NULL REFERENCES packages(name) ON DELETE CASCADE,
    version            TEXT NOT NULL,
    pubspec_json       TEXT NOT NULL,
    readme_content     TEXT,
    changelog_content  TEXT,
    libraries          TEXT NOT NULL DEFAULT '[]',
    bin_executables    TEXT NOT NULL DEFAULT '[]',
    screenshots        TEXT NOT NULL DEFAULT '[]',
    tags               TEXT NOT NULL DEFAULT '[]',
    example_path       TEXT,
    example_content    TEXT,
    archive_size_bytes INTEGER NOT NULL,
    archive_sha256     TEXT NOT NULL,
    uploader_id        TEXT REFERENCES users(user_id) ON DELETE SET NULL,
    publisher_id       TEXT,
    is_retracted       INTEGER NOT NULL DEFAULT 0,
    retracted_at       INTEGER,
    is_prerelease      INTEGER NOT NULL DEFAULT 0,
    dart_sdk_min       TEXT,
    dart_sdk_max       TEXT,
    flutter_sdk_min    TEXT,
    flutter_sdk_max    TEXT,
    published_at       INTEGER NOT NULL,
    PRIMARY KEY (package_name, version)
  )
  ''',

  // ── Package Uploaders ───────────────────────────────────────
  '''
  CREATE TABLE IF NOT EXISTS package_uploaders (
    package_name TEXT NOT NULL REFERENCES packages(name) ON DELETE CASCADE,
    user_id      TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    created_at   INTEGER NOT NULL,
    PRIMARY KEY (package_name, user_id)
  )
  ''',

  // ── Package Likes ───────────────────────────────────────────
  '''
  CREATE TABLE IF NOT EXISTS package_likes (
    user_id      TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    package_name TEXT NOT NULL REFERENCES packages(name) ON DELETE CASCADE,
    created_at   INTEGER NOT NULL,
    PRIMARY KEY (user_id, package_name)
  )
  ''',

  // ── Upload Sessions ─────────────────────────────────────────
  '''
  CREATE TABLE IF NOT EXISTS upload_sessions (
    id         TEXT PRIMARY KEY NOT NULL,
    user_id    TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    temp_path  TEXT NOT NULL,
    state      TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
  )
  ''',

  // ── Audit Log ───────────────────────────────────────────────
  '''
  CREATE TABLE IF NOT EXISTS audit_log (
    id           TEXT PRIMARY KEY NOT NULL,
    created_at   INTEGER NOT NULL,
    kind         TEXT NOT NULL,
    agent_id     TEXT,
    package_name TEXT,
    version      TEXT,
    publisher_id TEXT,
    summary      TEXT NOT NULL,
    data_json    TEXT NOT NULL DEFAULT '{}'
  )
  ''',

  // ── FTS5 Virtual Table ──────────────────────────────────────
  '''
  CREATE VIRTUAL TABLE IF NOT EXISTS package_fts USING fts5(
    package_name UNINDEXED,
    name,
    description,
    readme_excerpt,
    tags,
    topics
  )
  ''',

  // ── Package Scores ──────────────────────────────────────────
  // Persisted pana analysis results. One row per (package, version).
  // `report_json` holds the full pana Summary JSON for rendering the
  // Scores tab (sections with markdown summaries).
  '''
  CREATE TABLE IF NOT EXISTS package_scores (
    package_name    TEXT NOT NULL,
    version         TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    granted_points  INTEGER,
    max_points      INTEGER,
    report_json     TEXT,
    pana_version    TEXT,
    dart_version    TEXT,
    flutter_version TEXT,
    error_message   TEXT,
    scored_at       INTEGER,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL,
    PRIMARY KEY (package_name, version),
    FOREIGN KEY (package_name, version)
      REFERENCES package_versions(package_name, version) ON DELETE CASCADE
  )
  ''',

  // ── Server Settings ─────────────────────────────────────────
  // Runtime-mutable key-value store for settings managed from the admin UI
  // (e.g. scoring_enabled, default_sdk_version).
  '''
  CREATE TABLE IF NOT EXISTS server_settings (
    key        TEXT PRIMARY KEY NOT NULL,
    value      TEXT NOT NULL,
    updated_at INTEGER NOT NULL
  )
  ''',

  // ── SDK Installs ───────────────────────────────────────────
  // Tracks Flutter SDK versions cloned and managed at runtime
  // for pana-based package scoring.
  '''
  CREATE TABLE IF NOT EXISTS sdk_installs (
    id              TEXT PRIMARY KEY NOT NULL,
    channel         TEXT NOT NULL,
    version         TEXT NOT NULL,
    dart_version    TEXT,
    install_path    TEXT NOT NULL,
    size_bytes      INTEGER,
    status          TEXT NOT NULL DEFAULT 'cloning',
    error_message   TEXT,
    is_default      INTEGER NOT NULL DEFAULT 0,
    installed_at    INTEGER,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
  )
  ''',

  // ── Dartdoc Status ──────────────────────────────────────────
  // Tracks dartdoc generation per package. One row per package — only the
  // latest version's docs are kept on disk.
  '''
  CREATE TABLE IF NOT EXISTS dartdoc_status (
    package_name    TEXT PRIMARY KEY NOT NULL
                      REFERENCES packages(name) ON DELETE CASCADE,
    version         TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    error_message   TEXT,
    generated_at    INTEGER,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
  )
  ''',

  // ── Indexes ─────────────────────────────────────────────────
  'CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)',
  'CREATE INDEX IF NOT EXISTS idx_api_tokens_user_id ON api_tokens(user_id)',
  'CREATE INDEX IF NOT EXISTS idx_api_tokens_token_hash ON api_tokens(token_hash)',
  'CREATE INDEX IF NOT EXISTS idx_user_invites_user_id ON user_invites(user_id)',
  'CREATE INDEX IF NOT EXISTS idx_user_invites_token_hash ON user_invites(token_hash)',
  'CREATE INDEX IF NOT EXISTS idx_packages_publisher_id ON packages(publisher_id)',
  'CREATE INDEX IF NOT EXISTS idx_packages_updated_at ON packages(updated_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_package_versions_package_name ON package_versions(package_name)',
  'CREATE INDEX IF NOT EXISTS idx_package_versions_published_at ON package_versions(published_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_package_likes_package_name ON package_likes(package_name)',
  'CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON audit_log(created_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_audit_log_package_name ON audit_log(package_name)',
  'CREATE INDEX IF NOT EXISTS idx_audit_log_agent_id ON audit_log(agent_id)',
  'CREATE INDEX IF NOT EXISTS idx_package_scores_status ON package_scores(status)',
  'CREATE INDEX IF NOT EXISTS idx_sdk_installs_status ON sdk_installs(status)',
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_sdk_installs_version ON sdk_installs(version, channel)',
  'CREATE INDEX IF NOT EXISTS idx_dartdoc_status_status ON dartdoc_status(status)',

  // ── Daily Download Counts ──────────────────────────────────
  // One row per (package, version, day). The `count` column is incremented
  // atomically via ON CONFLICT DO UPDATE on each archive download.
  // `date_utc` is an ISO-8601 date string ('YYYY-MM-DD') — idiomatic SQLite,
  // allows native date arithmetic, and alphabetic sort = chronological sort.
  // No FK on `version` so download history survives version deletion.
  '''
  CREATE TABLE IF NOT EXISTS package_download_counts (
    package_name  TEXT NOT NULL REFERENCES packages(name) ON DELETE CASCADE,
    version       TEXT NOT NULL,
    date_utc      TEXT NOT NULL,
    count         INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (package_name, version, date_utc)
  )
  ''',

  'CREATE INDEX IF NOT EXISTS idx_download_counts_package ON package_download_counts(package_name, date_utc DESC)',
  'CREATE INDEX IF NOT EXISTS idx_download_counts_version ON package_download_counts(package_name, version, date_utc DESC)',
];
