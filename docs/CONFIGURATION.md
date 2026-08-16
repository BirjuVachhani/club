# club Configuration Reference

## Overview

club is configured via environment variables, with an optional YAML config
file for convenience. Environment variables always take precedence over the
config file.

**Priority order:** Environment variable > YAML config file > Default value

Environment variable names are **plain and unprefixed**: `SERVER_URL`,
`JWT_SECRET`, `SQLITE_PATH`. There is no `CLUB_` prefix. A container or
systemd unit already scopes its own environment, so a prefix would add
noise without adding isolation.

The canonical list of names lives in
`packages/club_server/lib/src/config/env_keys.dart`.

---

## Configuration Loading

1. If `CONFIG` is set, load the YAML file it points to.
2. Otherwise, load `/etc/club/config.yaml` if it exists.
3. Apply environment variables as overrides.
4. Validate required fields and backend-specific requirements.
5. Fail fast with a clear error if misconfigured.

---

## Environment Variables

### Server

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SERVER_URL` | Recommended |  | Public URL of the server. Used to build `archive_url` values, upload redirect URLs, and the hosted-dependency allowlist. Include the scheme; no trailing slash. Not enforced at startup, but when it is unset the server falls back to deriving a base URL from request headers, which is fragile behind a proxy. |
| `HOST` | No | `0.0.0.0` | Address to bind to |
| `LISTEN_PORT` | No | `8080` | Port to listen on. Deliberately not `PORT`, which docker-compose uses for the host-side mapping. |
| `LOG_LEVEL` | No | `info` | `debug`, `info`, `warning`, `error` |
| `TRUST_PROXY` | No | `false` | Trust `X-Forwarded-Proto` / `X-Forwarded-For` for scheme detection and client-IP logging. Only enable behind a proxy that overwrites both, otherwise clients can spoof them. |
| `ALLOWED_ORIGINS` | No |  | Comma-separated extra origins accepted on login, signup, setup, and invite endpoints. `SERVER_URL` is always trusted. This is an inbound anti-CSRF check, not CORS: club emits no CORS headers at all. |
| `STATIC_FILES_PATH` | No | auto | Directory holding the built SvelteKit frontend. |

### Authentication

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `JWT_SECRET` | **Yes** |  | Minimum 32 characters. Generate with `openssl rand -hex 32`. See the note below. |
| `SESSION_TTL_HOURS` | No | `1` | Session lifetime in hours |
| `TOKEN_EXPIRY_DAYS` | No | `365` | Default API token expiry in days |
| `BCRYPT_COST` | No | `12` | bcrypt cost factor (10-14 recommended) |
| `SIGNUP_ENABLED` | No | `false` | Expose `/signup` and `POST /api/auth/signup` so anyone can self-register. New accounts get the `member` role. |

> **About `JWT_SECRET`:** the name is historical. club does not issue JWTs.
> Sessions and API tokens are opaque CSPRNG strings (`club_sess_…`,
> `club_pat_…`) stored as SHA-256 hashes. The variable is still required
> and still validated for length, so set it to a real random value, but
> nothing currently signs anything with it.

### Public Packages

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PUBLIC_PACKAGES_ENABLED` | No | `false` | Permit packages to be marked public and served without credentials. Only half the gate: a server admin must also enable the toggle under Admin > Public packages. Setting it back to `false` is a kill switch that makes every public package require credentials again on the next request, without changing any package's stored visibility. |

See [FEATURES.md](FEATURES.md#14-public-packages) for the full model.

### Database (Metadata Store)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DB_BACKEND` | No | `sqlite` | `sqlite` or `postgres` |
| `SQLITE_PATH` | No | `/data/db/club.db` | SQLite file path. Only used when `DB_BACKEND=sqlite`. |
| `POSTGRES_URL` | Cond. |  | **Required** when `DB_BACKEND=postgres`. Format: `postgres://user:pass@host:5432/dbname`. The PostgreSQL backend is not implemented yet and throws at startup. |

### Blob Storage

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BLOB_BACKEND` | No | `filesystem` | `filesystem`, `s3`, or `gcs` |
| `BLOB_PATH` | No | `/data/blobs` | Root for package tarballs. Only used when `BLOB_BACKEND=filesystem`. |
| `S3_ENDPOINT` | Cond. |  | S3-compatible endpoint. Required for MinIO, R2, Spaces, and B2; omit for AWS. |
| `S3_BUCKET` | Cond. |  | **Required** when `BLOB_BACKEND=s3` |
| `S3_REGION` | Cond. |  | **Required** when `BLOB_BACKEND=s3` |
| `S3_ACCESS_KEY` | Cond. |  | **Required** when `BLOB_BACKEND=s3` |
| `S3_SECRET_KEY` | Cond. |  | **Required** when `BLOB_BACKEND=s3` |
| `GCS_BUCKET` | Cond. |  | **Required** when `BLOB_BACKEND=gcs` |
| `GCS_CREDENTIALS_FILE` | No |  | Path to a service-account JSON file. Falls back to Application Default Credentials when neither this nor `GCS_CREDENTIALS_JSON` is set. |
| `GCS_CREDENTIALS_JSON` | No |  | Inline service-account JSON |

### Search

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SEARCH_BACKEND` | No | `sqlite` | `sqlite` or `meilisearch` |
| `MEILISEARCH_URL` | Cond. |  | **Required** when `SEARCH_BACKEND=meilisearch`. The Meilisearch backend is not implemented yet and throws at startup. |
| `MEILISEARCH_KEY` | Cond. |  | Meilisearch API key |

### Upload

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TEMP_DIR` | No | `/data/tmp/uploads` | Scratch directory for upload processing |
| `MAX_UPLOAD_BYTES` | No | `104857600` | Maximum tarball size in bytes (100 MB) |

### Packages and Publishers

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ENFORCE_RETRACTION_WINDOW` | No | `true` | Restrict retraction and restoration to the pub spec's 7-day windows. Set `false` on a private registry where admins need to retract older known-bad releases. |
| `MAX_PUBLISHERS_PER_USER` | No | `10` | Maximum verified publishers one user may own. Internal publishers created by admins do not count. |
| `VERIFICATION_TOKEN_TTL_HOURS` | No | `24` | Lifetime of a pending DNS verification token. Must outlast real DNS propagation. |

### Dartdoc

club generates dartdoc **only for the latest version** of each package.
See <https://docs.club.birju.dev/reference/dartdoc-serving/>.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DARTDOC_BACKEND` | No | `filesystem` | `filesystem` serves a local HTML tree via `shelf_static`; `blob` persists an indexed blob to the blob store and serves byte-range reads. |
| `DARTDOC_PATH` | No | `/data/cache/dartdoc` | Filesystem root. Ignored in blob mode. |
| `DARTDOC_CACHE_MAX_MEMORY_MB` | No | `64` | In-process LRU cap for the blob backend. Counted in bytes, not entries. |

### Scoring

Read directly from the process environment rather than through `AppConfig`.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SDK_BASE_DIR` | No | `/data/cache/sdks` | Where managed Dart and Flutter SDKs are installed |
| `LOGS_DIR` | No | `<data dir>/logs` | Scoring log directory. Inferred from `SQLITE_PATH` when unset. |
| `SCORING_SUBPROCESS_BINARY` | No |  | Override the binary used for the pana subprocess |
| `SCORING_SANDBOX_PREFIX` | No |  | Command prefix for sandboxing the scoring subprocess |
| `SCORING_SANDBOX_UID` | No |  | UID to drop to inside the sandbox |
| `SCORING_SANDBOX_GID` | No |  | GID to drop to inside the sandbox |
| `SCORING_SANDBOX_RLIMITS` | No |  | Resource limits for the sandbox |

Everything else about scoring (enabled, default SDK) is a runtime setting
managed from Admin > Scoring, not an environment variable.

### Config File

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CONFIG` | No | `/etc/club/config.yaml` | Path to a YAML config file |

---

## First-Run Setup

There are **no** `ADMIN_EMAIL` / `ADMIN_PASSWORD` variables. The server does
not create an admin account from the environment.

On first start, with no users in the database, club prints a one-time setup
code to its logs and serves a setup wizard at `/setup`:

```
┌───────────────────────────────────────────────────────┐
│  club, Initial Setup Required                        │
│  Open the setup wizard to create your admin account:  │
│    https://packages.example.com/setup                 │
│  Setup code:  KY5HYP6CUJWN                            │
└───────────────────────────────────────────────────────┘
```

Entering the code proves the operator can read the server's logs. The first
client IP to verify is pinned, so someone who snoops the code cannot use it
from elsewhere. Every API route except setup, health, and version returns
`503` until setup completes.

Development scripts such as `scripts/dev-server.sh` export `ADMIN_EMAIL` and
`ADMIN_PASSWORD` for their own convenience. The server ignores them.

---

## YAML Config File

Environment variables override anything set here.

**Keys are flat.** The loader flattens nested maps by joining with an
underscore, so a nested `db: { sqlite_path: ... }` becomes the key
`db_sqlite_path`, which is not what the server looks up. Write
`sqlite_path` at the top level.

There is **no** `{{ENV_VAR}}` substitution. Keep secrets in the
environment instead of the file.

```yaml
# Server
server_url: "https://packages.example.com"
host: "0.0.0.0"
port: 8080
log_level: info
trust_proxy: true

# Authentication
session_ttl_hours: 1
token_expiry_days: 365
bcrypt_cost: 12
signup_enabled: false

# Public packages
public_packages_enabled: false

# Database
db_backend: sqlite
sqlite_path: /data/db/club.db

# Blob storage
blob_backend: filesystem
blob_path: /data/blobs

# Search
search_backend: sqlite

# Upload
temp_dir: /data/tmp/uploads
max_upload_bytes: 104857600
```

`jwt_secret` may be set here, but prefer `JWT_SECRET` in the environment so
the secret never lands in a file.

---

## Validation Rules

Checked at startup; the server throws and exits on failure.

| Rule | Error |
|------|-------|
| `JWT_SECRET` not set | `JWT_SECRET is required.` |
| `JWT_SECRET` shorter than 32 characters | `JWT_SECRET must be at least 32 characters.` |
| `DB_BACKEND=postgres` without `POSTGRES_URL` | `POSTGRES_URL must be set when DB_BACKEND=postgres.` |
| `BLOB_BACKEND=s3` without S3 config | `S3 configuration required when BLOB_BACKEND=s3.` |
| `BLOB_BACKEND=s3` without keys | `S3_ACCESS_KEY and S3_SECRET_KEY are required when BLOB_BACKEND=s3.` |
| `BLOB_BACKEND=gcs` without a bucket | `GCS_BUCKET is required when BLOB_BACKEND=gcs.` |
| `SEARCH_BACKEND=meilisearch` without a URL | `MEILISEARCH_URL must be set when SEARCH_BACKEND=meilisearch.` |

`SERVER_URL` is not validated. Set it anyway.

---

## Configuration Profiles

### Development

```bash
SERVER_URL=http://localhost:8080
JWT_SECRET=dev-secret-at-least-32-characters-long
SQLITE_PATH=/tmp/club-dev.db
BLOB_PATH=/tmp/club-dev-packages
```

Then open `/setup` and use the code from the logs. `scripts/dev-server.sh`
sets sensible paths for all of this.

### Docker (SQLite + filesystem)

```bash
SERVER_URL=https://packages.example.com
JWT_SECRET=$(openssl rand -hex 32)
TRUST_PROXY=true
```

Defaults put the database, blobs, and caches under `/data`, so a single
volume mounted there covers everything.

### S3-compatible storage

```bash
SERVER_URL=https://packages.example.com
JWT_SECRET=$(openssl rand -hex 32)
TRUST_PROXY=true
BLOB_BACKEND=s3
S3_BUCKET=club-packages
S3_REGION=us-east-1
S3_ACCESS_KEY=AKIA...
S3_SECRET_KEY=wJalrXUtnFEMI...
# S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com   # R2, MinIO, Spaces, B2
```

### Public-facing registry

```bash
SERVER_URL=https://packages.example.com
JWT_SECRET=$(openssl rand -hex 32)
TRUST_PROXY=true
PUBLIC_PACKAGES_ENABLED=true
```

This only *permits* public packages. A server admin must still enable the
toggle under Admin > Public packages, and each package stays private until
someone marks it public.
