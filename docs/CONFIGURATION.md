# club — Configuration Reference

## Overview

club is configured via environment variables, with an optional YAML config
file for convenience. Environment variables always take precedence over the
config file.

**Priority order:** Environment variable > YAML config file > Default value

---

## Configuration Loading

1. If `CLUB_CONFIG` env var is set, load the YAML file it points to
2. Otherwise, check for `/etc/club/config.yaml`
3. Apply all `CLUB_*` environment variables as overrides
4. Validate required fields and backend-specific requirements
5. Fail fast with a clear error message if misconfigured

---

## Environment Variables

### Server

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLUB_SERVER_URL` | **Yes** | — | Public URL of the club server. Used to construct `archive_url` in API responses and upload redirect URLs. Must include scheme (https://). No trailing slash. |
| `CLUB_HOST` | No | `0.0.0.0` | IP address to bind the HTTP server to |
| `CLUB_PORT` | No | `8080` | Port to listen on |
| `CLUB_LOG_LEVEL` | No | `info` | Log verbosity: `debug`, `info`, `warning`, `error` |

### Authentication

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLUB_JWT_SECRET` | **Yes** | — | Secret key for signing JWT session tokens. Minimum 32 characters. Generate with `openssl rand -hex 32`. |
| `CLUB_SESSION_TTL_HOURS` | No | `1` | JWT session token time-to-live in hours |
| `CLUB_TOKEN_EXPIRY_DAYS` | No | `365` | Default API token expiry in days |
| `CLUB_BCRYPT_COST` | No | `12` | bcrypt hashing cost factor (10-14 recommended) |

### Database (Metadata Store)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLUB_DB_BACKEND` | No | `sqlite` | Database backend: `sqlite` or `postgres` |
| `CLUB_SQLITE_PATH` | No | `/data/db/club.db` | Path to SQLite database file. Only used when `CLUB_DB_BACKEND=sqlite`. |
| `CLUB_POSTGRES_URL` | Cond. | — | PostgreSQL connection URL. **Required** when `CLUB_DB_BACKEND=postgres`. Format: `postgres://user:pass@host:5432/dbname` |

### Blob Storage

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLUB_BLOB_BACKEND` | No | `filesystem` | Blob storage backend: `filesystem` or `s3` |
| `CLUB_BLOB_PATH` | No | `/data/blobs` | Root directory for package tarballs. Only used when `CLUB_BLOB_BACKEND=filesystem`. |
| `CLUB_S3_ENDPOINT` | Cond. | — | S3-compatible endpoint URL. Required for MinIO/custom S3. Optional for AWS (uses default). |
| `CLUB_S3_BUCKET` | Cond. | — | S3 bucket name. **Required** when `CLUB_BLOB_BACKEND=s3`. |
| `CLUB_S3_REGION` | Cond. | — | S3 region. **Required** when `CLUB_BLOB_BACKEND=s3`. |
| `CLUB_S3_ACCESS_KEY` | Cond. | — | S3 access key ID. **Required** when `CLUB_BLOB_BACKEND=s3`. |
| `CLUB_S3_SECRET_KEY` | Cond. | — | S3 secret access key. **Required** when `CLUB_BLOB_BACKEND=s3`. |

### Search

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLUB_SEARCH_BACKEND` | No | `sqlite` | Search backend: `sqlite` or `meilisearch` |
| `CLUB_MEILISEARCH_URL` | Cond. | — | Meilisearch URL. **Required** when `CLUB_SEARCH_BACKEND=meilisearch`. |
| `CLUB_MEILISEARCH_KEY` | Cond. | — | Meilisearch API key. **Required** when `CLUB_SEARCH_BACKEND=meilisearch`. |

### Upload

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLUB_TEMP_DIR` | No | `/data/tmp/uploads` | Temporary directory for upload processing |
| `CLUB_MAX_UPLOAD_BYTES` | No | `104857600` | Maximum tarball upload size in bytes (default: 100 MB) |

### Dartdoc

Club generates dartdoc **only for the latest version** of each package. See the user-facing spec for full details: https://docs.club.birju.dev/reference/dartdoc-serving/

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DARTDOC_BACKEND` | No | `filesystem` | `filesystem` serves a local HTML tree via `shelf_static`; `blob` persists an indexed blob to `BlobStore` + serves via byte-range reads. |
| `DARTDOC_PATH` | No | `/data/cache/dartdoc` | Filesystem root for the filesystem backend. Ignored in blob mode. |
| `DARTDOC_CACHE_MAX_MEMORY_MB` | No | `64` | In-process LRU cap for the blob backend. Bytes-counted, not entry-counted. |

### Admin Bootstrap

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLUB_ADMIN_EMAIL` | No | — | If set and no users exist in the database, automatically creates an admin account with this email on first startup. |
| `CLUB_ADMIN_PASSWORD` | No | — | Initial password for the bootstrap admin. Only used with `CLUB_ADMIN_EMAIL`. If not set, a random password is generated and printed to the logs. |

### Config File

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLUB_CONFIG` | No | — | Path to a YAML config file. If not set, checks `/etc/club/config.yaml`. |

---

## YAML Config File

The config file provides a convenient way to set all options in one place.
Environment variables override any value set in the config file.

### Location

- Set via `CLUB_CONFIG` env var, or
- Default: `/etc/club/config.yaml`

### Format

```yaml
# club configuration
# Values can reference environment variables: {{ENV_VAR_NAME}}

# Server
server_url: "https://packages.example.com"
host: "0.0.0.0"
port: 8080
log_level: info

# Authentication
jwt_secret: "{{CLUB_JWT_SECRET}}"
session_ttl_hours: 1
token_expiry_days: 365
bcrypt_cost: 12

# Database
db:
  backend: sqlite                    # sqlite | postgres
  sqlite_path: /data/db/club.db
  # postgres_url: "{{CLUB_POSTGRES_URL}}"

# Blob Storage
blob:
  backend: filesystem                # filesystem | s3
  path: /data/blobs
  # s3:
  #   endpoint: "https://s3.amazonaws.com"
  #   bucket: "club-packages"
  #   region: "us-east-1"
  #   access_key: "{{CLUB_S3_ACCESS_KEY}}"
  #   secret_key: "{{CLUB_S3_SECRET_KEY}}"

# Search
search:
  backend: sqlite                    # sqlite | meilisearch
  # meilisearch:
  #   url: "http://meilisearch:7700"
  #   key: "{{CLUB_MEILISEARCH_KEY}}"

# Upload
temp_dir: /data/tmp/uploads
max_upload_bytes: 104857600          # 100 MB

# Admin Bootstrap
admin_email: "admin@example.com"
# admin_password: "change-me"       # Omit to auto-generate
```

### Variable Substitution

Use `{{ENV_VAR_NAME}}` syntax to reference environment variables in YAML values.
This is useful for keeping secrets out of the config file:

```yaml
jwt_secret: "{{CLUB_JWT_SECRET}}"
db:
  postgres_url: "{{CLUB_POSTGRES_URL}}"
```

---

## Validation Rules

The server validates configuration at startup and fails fast with clear
error messages:

| Rule | Error Message |
|------|--------------|
| `CLUB_SERVER_URL` not set | `CLUB_SERVER_URL is required` |
| `CLUB_JWT_SECRET` not set | `CLUB_JWT_SECRET is required` |
| `CLUB_JWT_SECRET` < 32 chars | `CLUB_JWT_SECRET must be at least 32 characters` |
| `CLUB_DB_BACKEND=postgres` without `CLUB_POSTGRES_URL` | `CLUB_POSTGRES_URL must be set when CLUB_DB_BACKEND=postgres` |
| `CLUB_BLOB_BACKEND=s3` without bucket/keys | `CLUB_S3_BUCKET, CLUB_S3_ACCESS_KEY, and CLUB_S3_SECRET_KEY must be set when CLUB_BLOB_BACKEND=s3` |
| `CLUB_SEARCH_BACKEND=meilisearch` without URL | `CLUB_MEILISEARCH_URL must be set when CLUB_SEARCH_BACKEND=meilisearch` |

---

## Configuration Profiles

### Minimal (Development / Testing)

```bash
CLUB_SERVER_URL=http://localhost:8080
CLUB_JWT_SECRET=dev-secret-at-least-32-characters-long
CLUB_ADMIN_EMAIL=admin@localhost
CLUB_ADMIN_PASSWORD=admin
```

### Default Docker (SQLite + Filesystem)

```bash
CLUB_SERVER_URL=https://packages.example.com
CLUB_JWT_SECRET=$(openssl rand -hex 32)
CLUB_ADMIN_EMAIL=admin@example.com
```

### Production (PostgreSQL + S3)

```bash
CLUB_SERVER_URL=https://packages.example.com
CLUB_JWT_SECRET=$(openssl rand -hex 32)
CLUB_DB_BACKEND=postgres
CLUB_POSTGRES_URL=postgres://club:secret@db.example.com:5432/club
CLUB_BLOB_BACKEND=s3
CLUB_S3_BUCKET=club-packages
CLUB_S3_REGION=us-east-1
CLUB_S3_ACCESS_KEY=AKIA...
CLUB_S3_SECRET_KEY=wJalrXUtnFEMI...
CLUB_ADMIN_EMAIL=admin@example.com
```

### Production (PostgreSQL + MinIO)

```bash
CLUB_SERVER_URL=https://packages.example.com
CLUB_JWT_SECRET=$(openssl rand -hex 32)
CLUB_DB_BACKEND=postgres
CLUB_POSTGRES_URL=postgres://club:secret@postgres:5432/club
CLUB_BLOB_BACKEND=s3
CLUB_S3_ENDPOINT=http://minio:9000
CLUB_S3_BUCKET=club-packages
CLUB_S3_REGION=us-east-1
CLUB_S3_ACCESS_KEY=minioadmin
CLUB_S3_SECRET_KEY=minioadmin
```

---

## AppConfig Class

The Dart configuration model in `club_server`:

```dart
class AppConfig {
  // Server
  final String host;              // CLUB_HOST (default: '0.0.0.0')
  final int port;                 // CLUB_PORT (default: 8080)
  final Uri serverUrl;            // CLUB_SERVER_URL (required)
  final String logLevel;          // CLUB_LOG_LEVEL (default: 'info')

  // Auth
  final String jwtSecret;         // CLUB_JWT_SECRET (required, min 32 chars)
  final Duration sessionTtl;      // CLUB_SESSION_TTL_HOURS (default: 1h)
  final int tokenExpiryDays;      // CLUB_TOKEN_EXPIRY_DAYS (default: 365)
  final int bcryptCost;           // CLUB_BCRYPT_COST (default: 12)

  // Database
  final DbBackend dbBackend;      // CLUB_DB_BACKEND (default: sqlite)
  final String sqlitePath;        // CLUB_SQLITE_PATH (default: /data/db/club.db)
  final String? postgresUrl;      // CLUB_POSTGRES_URL

  // Blob Storage
  final BlobBackend blobBackend;  // CLUB_BLOB_BACKEND (default: filesystem)
  final String blobPath;          // CLUB_BLOB_PATH (default: /data/blobs)
  final S3Config? s3;             // CLUB_S3_* vars

  // Search
  final SearchBackend searchBackend; // CLUB_SEARCH_BACKEND (default: sqlite)
  final MeilisearchConfig? meilisearch; // CLUB_MEILISEARCH_* vars

  // Upload
  final String tempDir;           // CLUB_TEMP_DIR (default: /data/tmp/uploads)
  final int maxUploadBytes;       // CLUB_MAX_UPLOAD_BYTES (default: 100MB)

  // Admin Bootstrap
  final String? adminEmail;       // CLUB_ADMIN_EMAIL
  final String? adminPassword;    // CLUB_ADMIN_PASSWORD

  factory AppConfig.fromEnvironment();
  factory AppConfig.fromMap(Map<String, dynamic> map);
  void validate();
}

enum DbBackend { sqlite, postgres }
enum BlobBackend { filesystem, s3 }
enum SearchBackend { sqlite, meilisearch }
```
