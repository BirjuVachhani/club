# club — Feature List

A self-hosted, private Dart package repository. Drop-in replacement for pub.dev
for teams and organizations that need private package hosting.

---

## Table of Contents

- [1. Core Package Registry](#1-core-package-registry)
- [2. Authentication & Authorization](#2-authentication--authorization)
- [3. Web UI](#3-web-ui)
- [4. Search](#4-search)
- [5. Publishers (Organizations)](#5-publishers-organizations)
- [6. Favorites / Likes](#6-favorites--likes)
- [7. Package Administration](#7-package-administration)
- [8. Client SDK (club_api)](#8-client-sdk-club_api)
- [9. CLI Tool (club)](#9-cli-tool-club)
- [10. Docker & Deployment](#10-docker--deployment)
- [11. Storage Backends](#11-storage-backends)
- [12. Configuration](#12-configuration)
- [13. Future / V2 Features](#13-future--v2-features)
- [14. Public Packages](#14-public-packages)

---

## 1. Core Package Registry

Implements the [Dart Pub Repository Specification v2](https://github.com/dart-lang/pub/blob/master/doc/repository-spec-v2.md).

### Package Hosting

- **List all versions** of a package (`GET /api/packages/<package>`)
- **Inspect a specific version** (`GET /api/packages/<package>/versions/<version>`)
- **Download archives** (`GET /api/archives/<package>-<version>.tar.gz`)
- **Legacy download redirect** (`GET /packages/<package>/versions/<version>.tar.gz`)
- Full compatibility with `dart pub get` and `flutter pub get`
- Full compatibility with `dart pub publish`
- Support for `PUB_HOSTED_URL` environment variable
- Support for per-dependency `hosted` URLs in `pubspec.yaml`
- Support for `dart pub token add` credential management

### Package Publishing

- **Two-phase upload flow** adapted for self-hosted deployment:
  1. Client requests upload URL → server returns URL pointing back to itself
  2. Client POSTs tarball as multipart form data directly to the server
  3. Client finalizes upload → server validates, stores, and indexes
- Archive validation:
  - Valid `.tar.gz` format
  - Valid `pubspec.yaml` with required fields
  - Canonical semantic version (via `pub_semver`)
  - Package name validation (lowercase, alphanumeric + underscore, 1-64 chars)
  - SHA-256 hash computation and storage
- README, CHANGELOG, and library list extraction from archive
- Duplicate version detection (idempotent if SHA-256 matches, rejected if different)
- Upload session management with expiration and cleanup
- Configurable max upload size (default: 100 MB)
- Rate limiting per user (configurable burst/hourly limits)

### Version Management

- Semantic version ordering (stable, prerelease, preview)
- Automatic `latest` version tracking (latest stable, latest prerelease)
- Version retraction (`PUT /api/packages/<package>/versions/<version>/options`)
- Retracted versions remain downloadable but excluded from resolution

### Package Metadata

- Full pubspec stored as JSON per version
- README content (Markdown) per version
- CHANGELOG content (Markdown) per version
- Library list per version
- Archive size and SHA-256 hash per version
- Published timestamp per version
- Uploader identity per version

---

## 2. Authentication & Authorization

Private by default: every endpoint requires authentication unless the
operator has explicitly enabled public packages (see
[Public Packages](#14-public-packages)) and a package has been marked
public.

### User Accounts

- Email/password authentication (bcrypt hashed, cost=12)
- Admin-created accounts (no self-registration)
- Admin and regular user roles
- Account enable/disable by admin
- Display name per user

### API Tokens

- Named API tokens for CI/CD integration
- Token format: `club_<32-char-hex>` (39 chars total)
- Tokens stored as SHA-256 hash (raw token shown once at creation, never retrievable)
- First 8 characters stored as prefix for display/identification
- Optional expiration date per token
- Token scopes: `read`, `write`, `admin`
- Last-used timestamp tracking
- Token revocation
- Multiple tokens per user

### Session Management

- JWT-based web sessions (HMAC-SHA256 signed)
- Configurable session TTL (default: 1 hour)
- HttpOnly, Secure, SameSite=Strict cookies
- CSRF protection on state-modifying web endpoints

### Authorization Model

- **Server admin**: full access to all operations
- **Publisher admin**: can publish to publisher-owned packages, manage members
- **Publisher member**: can publish to publisher-owned packages
- **Package uploader**: can publish new versions to packages they own
- **Authenticated user**: can browse, download, search, like packages

### dart pub Integration

- Compatible with `dart pub token add <server-url>`
- Compatible with `Authorization: Bearer <token>` header
- Compatible with `PUB_HOSTED_URL` environment variable
- Compatible with `--hosted-url` flag
- Proper `401 Unauthorized` with `WWW-Authenticate: Bearer` header
- Proper `403 Forbidden` for insufficient permissions

---

## 3. Web UI

Visually identical to pub.dev. Built with SvelteKit (`adapter-static`),
compiled to static HTML/JS/CSS at Docker build time, and served by the
Dart shelf server. No Node.js at runtime. Uses pub.dev's CSS/design system.

### Pages

| Page | Route | Description |
|------|-------|-------------|
| Login | `/login` | Email/password login form |
| Package Listing | `/packages` | Search, filter, sort packages |
| Package Detail | `/packages/<pkg>` | Tabbed view: Readme, Changelog, Versions, Installing, Admin |
| Package Changelog | `/packages/<pkg>/changelog` | Rendered changelog Markdown |
| Package Versions | `/packages/<pkg>/versions` | Version history with timestamps and uploaders |
| Package Install | `/packages/<pkg>/install` | Installation instructions for club |
| Package Admin | `/packages/<pkg>/admin` | Uploader management, options (uploaders/admins only) |
| Version Detail | `/packages/<pkg>/versions/<v>` | Specific version info |
| Publisher List | `/publishers` | All publishers |
| Publisher Detail | `/publishers/<id>` | Publisher info + member list + packages |
| My Packages | `/my-packages` | Current user's packages |
| My Liked Packages | `/my-liked-packages` | Current user's favorites |
| Token Management | `/settings/tokens` | Create, list, revoke API tokens |
| Admin: Users | `/admin/users` | User management (admin only) |
| Admin: Packages | `/admin/packages` | Package moderation (admin only) |

### UI Features

- **Dark mode** with toggle (persisted in localStorage, flash-free via sync JS init)
- **Responsive design** (mobile, tablet, desktop breakpoints)
- **Markdown rendering** with GitHub-flavored Markdown support:
  - Syntax highlighting (highlight.js)
  - Task lists
  - Tables
  - Relative URL rewriting
  - HTML sanitization (allowlist-based)
  - Changelog grouping by version
- **Package info sidebar**: metadata, dependencies, publisher badge, like count
- **Tag badges**: SDK tags, platform tags, status tags (retracted, discontinued, unlisted)
- **Pagination** on listing pages
- **Sort controls**: relevance, recently updated, likes, created
- **Search with filters** (inline search bar, query syntax for tags)
- **Like button** with optimistic UI update
- **Static asset fingerprinting** with far-future cache headers
- **Google Fonts** (Google Sans family) — same as pub.dev
- **Material Design** component styles

---

## 4. Search

### Search Features

- Full-text search across package name, description, and README excerpt
- SQLite FTS5 backend (default) with Unicode tokenizer
- Sort by: relevance, recently updated, likes, created date
- Package name autocomplete endpoint
- Pagination with total hit count
- SDK and platform filtering in the web UI, applied client-side from the
  derived tags on each result

**What search never returns**, on any surface (keyword search, browse,
autocomplete), for every caller:

- Discontinued packages
- Unlisted packages: findable by URL only
- Private packages, when the caller is anonymous

The first two are listing hints and apply to signed-in users as well. The
third is access control. All three are applied by one shared predicate, so
the keyword and browse paths cannot disagree about them.

> The query-syntax operators `sdk:`, `platform:`, and `is:` are not
> implemented server-side. `SearchQuery.tags` exists on the model but no
> backend consumes it; the web UI filters the returned results instead.

### Search Index

- Automatically updated on package publish/update
- Indexed fields: name, description, README excerpt (first 2KB), tags
- Abstracted via `SearchIndex` interface (swappable for Meilisearch, Elasticsearch)
- Full reindex capability

---

## 5. Publishers (Organizations)

Simplified publisher model (no domain verification).

### Features

- Admin-created publishers with ID (slug), display name, description
- Publisher website URL and contact email
- Publisher members with roles: `admin` or `member`
- Packages can be owned by a publisher or by individual uploaders
- Publisher admins can:
  - Add/remove members
  - Publish to publisher-owned packages
  - Transfer packages to/from the publisher
- Publisher members can:
  - Publish to publisher-owned packages
- Publisher badge displayed on package pages
- Publisher detail page with member list and package list

---

## 6. Favorites / Likes

- Authenticated users can like/unlike packages
- Like count displayed on package listing and detail pages
- "My Liked Packages" page for the current user
- Like count used as a sorting/ranking signal in search
- API endpoints:
  - `PUT /api/account/likes/<package>` — like
  - `DELETE /api/account/likes/<package>` — unlike
  - `GET /api/account/likes` — list liked packages
  - `GET /api/packages/<package>/likes` — get like count

---

## 7. Package Administration

### Package Options

- **Discontinue** a package (with optional "replaced by" pointer)
- **Unlist** a package: findable by URL only. Excluded from keyword
  search, browse listings, and name autocomplete, for signed-in users and
  anonymous visitors alike. Still fully downloadable and resolvable by
  anyone who knows the name, and still listed on My Packages and its
  publisher's page.
- **Retract** a specific version

### Uploader Management

- Add/remove uploaders for non-publisher packages
- Transfer package ownership to a publisher
- View upload history via audit log

### Admin Operations (server admin only)

- Delete packages and versions
- Moderate packages (hide from all users)
- Manage all users (create, disable, promote to admin)
- View audit log

### Audit Log

- Append-only log of all significant operations
- Tracked events: package published, version retracted, user login, uploader changes, publisher changes, admin actions
- Fields: timestamp, event kind, agent (user), package, version, summary, JSON payload
- Queryable by package, user, time range

---

## 8. Client SDK (club_api)

Publishable Dart package for programmatic access to any club server.

### Features

- **Typed Dart client** — `ClubClient` class with methods for all API operations
- **Package operations**: list, search, download, get metadata
- **Publishing**: full publish flow (start upload, send tarball, finalize)
- **Authentication**: login, token creation/listing/revocation
- **Publisher management**: create publishers, manage members
- **Admin operations**: user management, package moderation
- **Favorites**: like/unlike packages, list liked packages
- **Configurable**: custom server URL, token, HTTP client
- **Publishable to pub.dev or club**: usable by anyone building tooling

### Use Cases

- **CI/CD pipelines**: publish packages programmatically
- **Custom tooling**: build internal dashboards, migration scripts, audit tools
- **Automation**: batch operations across packages (retract, discontinue, etc.)
- **IDE plugins**: build editor integrations for club
- **Monitoring**: check package health, version counts, etc.

### Usage

```dart
import 'package:club_api/club_api.dart';

final client = ClubClient(
  serverUrl: Uri.parse('https://club.example.com'),
  token: 'club_a1b2c3d4...',
);

// List versions of a package
final packageData = await client.packages.listVersions('my_package');
print(packageData.latest.version);

// Search packages
final results = await client.search.query('http client');
for (final hit in results.hits) {
  print(hit.package);
}

// Publish a package
final archive = File('my_package-1.0.0.tar.gz').openRead();
await client.publishing.publish(archive);

// Create an API token
final token = await client.auth.createToken(name: 'CI Token');
print(token.secret); // shown once
```

See [CLIENT_SDK.md](CLIENT_SDK.md) for full documentation.

---

## 9. CLI Tool (club)

Dart CLI package for interacting with a club server.

### Commands

```
club login <server-url>              Authenticate via browser (OAuth PKCE)
club login --key <club_pat_...>      Authenticate with a dashboard-minted API key
club logout                          Remove stored credentials
club config                          Show current configuration
club config set-server <url>         Set default server URL
club publish                         Publish a package (wraps dart pub publish)
club setup                           Configure dart pub for club server
club admin user list                 List all users (admin only)
club admin user create               Create a new user (admin only)
club admin user disable <user-id>    Disable a user (admin only)
club admin package list              List all packages (admin only)
club admin package moderate <pkg>    Moderate a package (admin only)
```

### Credential Storage

- Credentials stored in `~/.config/club/credentials.json` (Unix) or `%APPDATA%\club\credentials.json` (Windows)
- File permissions: `chmod 600` on Unix
- Multiple server configurations supported
- Default server selection

### dart pub Integration

- `club setup` runs `dart pub token add <server-url>` to store the token in dart pub's native credential store
- `club publish` wraps `dart pub publish` with correct `PUB_HOSTED_URL`
- Environment variable support: `CLUB_TOKEN` for CI/CD (used via `dart pub token add <url> --env-var CLUB_TOKEN`)

---

## 10. Docker & Deployment

### Docker Image

- Multi-stage build: `dart:stable` (build) → `debian:bookworm-slim` (runtime)
- Native binary built with `dart build cli` (~80MB final image)
- Non-root user (`club:1000`)
- Single `/data` volume for database + packages
- Health check endpoint at `/api/v1/health`
- Configurable via environment variables

### docker-compose

- Default: single container with SQLite + filesystem (zero dependencies)
- Optional: PostgreSQL override (`docker-compose.postgres.yml`)
- Named volumes for data persistence
- `.env` file for secrets

### Reverse Proxy

- **Caddy** (recommended): automatic TLS via Let's Encrypt, zero-config
- **nginx**: manual TLS configuration, provided config template
- `client_max_body_size: 100m` for tarball uploads
- Proper header forwarding (`X-Forwarded-Proto`, `X-Real-IP`)

### Backup & Restore

- SQLite: safe online backup via `.backup` command
- PostgreSQL: `pg_dump` / `pg_restore`
- Filesystem blobs: archive `/data/blobs/`
- Provided backup/restore shell scripts
- Single-volume snapshot for atomic consistency

---

## 11. Storage Backends

All storage is abstracted behind interfaces. Swap implementations by changing
one environment variable.

### Metadata Store (`MetadataStore` interface)

| Backend | Env Value | Dependencies | Use Case |
|---------|-----------|-------------|----------|
| **SQLite** (default) | `sqlite` | None (bundled) | Single-server, up to ~10K packages |
| PostgreSQL | `postgres` | External PostgreSQL | Multi-server, large scale |

### Blob Store (`BlobStore` interface)

| Backend | Env Value | Package | Dependencies | Use Case |
|---------|-----------|---------|--------------|----------|
| **Filesystem** (default) | `filesystem` | `club_storage` | None | Single-server, Docker volume |
| S3-compatible | `s3` | `club_storage_s3` | S3-compatible endpoint, HMAC keys | Distributed, CDN, large storage |
| Firebase Storage / GCS | `gcs` (alias: `firebase`) | `club_storage_firebase` | Service-account JSON or ADC | Native GCP integration without HMAC keys |

Each cloud backend lives in its own package and is pulled into `club_server`
as an opt-in dependency. `club_storage` stays lean with just the interface
and the filesystem implementation — tooling that only needs filesystem
storage doesn't drag in `minio` or `googleapis`.

The `s3` backend works against any S3-compatible provider — one
implementation covers all of them. Switching is a `.env` change; there is
no separate backend per S3-compatible provider.

**Verified providers:**

| Provider | Backend | Endpoint / Bucket | Notes |
|----------|---------|-------------------|-------|
| AWS S3 | `s3` | endpoint omitted; region `us-east-1` etc. | SDK derives host from region |
| Cloudflare R2 | `s3` | `https://<account-id>.r2.cloudflarestorage.com`, region `auto` | Zero egress fees; presigned downloads bypass the server entirely |
| MinIO | `s3` | `http://minio:9000` | Self-hosted; `http` allowed only for `localhost` / `minio` host |
| DigitalOcean Spaces | `s3` | `https://<region>.digitaloceanspaces.com` | |
| Backblaze B2 | `s3` | `https://s3.<region>.backblazeb2.com` | |
| Firebase Storage / GCS (interop) | `s3` | `https://storage.googleapis.com`, bucket `<project>.appspot.com`, HMAC keys | Fastest path to Firebase; uses the GCS XML API |
| Firebase Storage / GCS (native) | `gcs` | service-account JSON → inline JSON → ADC | First-class GCP auth; no HMAC keys; signed URLs require the JSON path (ADC falls back to server-proxy) |

**How it works:**

- The server streams uploads directly to the bucket; the SHA-256 hash is
  computed on the same byte stream.
- A tiny sidecar object (`<package>/<version>.json`) stores the size,
  hash, and upload timestamp so metadata reads don't need to download
  the archive.
- Package downloads redirect the client to a **presigned URL** valid for
  one hour — the server never proxies bytes on the hot path. This is the
  main operational win of the S3 backend.
- TLS is enforced: plaintext `http://` endpoints are rejected unless the
  host is `localhost`, `127.0.0.1`, or the docker-compose service name
  `minio` (for local development).
- Bucket existence is verified at startup — misconfigured credentials
  fail fast with a clear error rather than surfacing during the first
  publish.

**Out of scope (intentional):**

- Admin UI settings for storage config. Switching backends is a
  deployment action, not a runtime one.
- Automatic migration between filesystem and S3. Use provider tooling
  (`aws s3 sync`, `mc mirror`, `rclone`) to copy existing blobs, then
  flip the env var. See the Self-Hosting docs for a step-by-step guide.

### Search Index (`SearchIndex` interface)

| Backend | Env Value | Dependencies | Use Case |
|---------|-----------|-------------|----------|
| **SQLite FTS5** (default) | `sqlite` | None (bundled) | Single-server, up to ~10K packages |
| Meilisearch | `meilisearch` | External Meilisearch | Advanced search, typo tolerance |

---

## 12. Configuration

All configuration via environment variables (Docker-friendly) with optional
YAML config file override.

See [CONFIGURATION.md](CONFIGURATION.md) for the complete reference.

### Key Settings

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SERVER_URL` | Yes | — | Public URL of the server |
| `JWT_SECRET` | Yes | — | 32+ char secret for JWT signing |
| `PORT` | No | `8080` | HTTP listen port |
| `DB_BACKEND` | No | `sqlite` | `sqlite` or `postgres` |
| `BLOB_BACKEND` | No | `filesystem` | `filesystem` or `s3` |
| `ADMIN_EMAIL` | No | — | Bootstrap admin account on first run |

---

## 13. Future / V2 Features

These features are **not included in v1** but the architecture supports them:

- **Package scoring** — run `pana` analysis via background worker container
- **API documentation** — run `dartdoc` and host generated docs
- **Download statistics** — track download counts per version, 30-day trends
- **Security advisories** — OSV format advisory endpoint
- **Automated publishing** — GitHub Actions OIDC / GCP service account publishing
- **Email notifications** — new version alerts, uploader invitations
- **Webhooks** — notify external systems on publish events
- **LDAP/SAML/OAuth** — enterprise SSO integration
- **Package topics** — user-defined topic tags
- **Screenshots** — package screenshot hosting and display
- **Atom/RSS feeds** — per-package version feeds
- **Multi-tenancy** — isolated registries per team/project
- **Replication** — mirror packages between club instances
- **Redis cache** — in-memory cache layer for high-traffic deployments

---

## 14. Public Packages

Individual packages can be opted into anonymous access, so `dart pub get`
resolves them without a token and visitors can browse them without an
account. Off by default, and every package is private until someone
deliberately changes it.

### Two gates, on purpose

A package is reachable anonymously only when **all** of these hold:

1. `PUBLIC_PACKAGES_ENABLED=true` in the server environment.
2. The dashboard toggle under Admin > Public packages is on.
3. The package itself is marked public.

The first two answer to different people: the environment variable belongs
to whoever controls the deployment, the toggle to whoever controls the
dashboard. Requiring both means an existing private registry cannot
acquire an anonymous surface from a single click, an upgrade, or a
compromised admin session alone.

Turning either off makes every public package require credentials again on
the next request, with no per-package state to undo. That is the kill
switch. It does not recall anything already downloaded.

### The dependency closure

A public package whose club-hosted dependency stayed private cannot be
resolved by anyone without a token, so marking a package public walks its
transitive dependency tree first and shows what must go with it.

- Only `dependencies` participate. A package's `dev_dependencies` are never
  resolved by its consumers, so a private club-hosted dev dependency breaks
  nothing downstream. They are listed separately and left unselected.
  `dependency_overrides` are honoured only for the root package of a solve
  and are ignored entirely.
- The closure is the union over **all** versions, not just the latest.
  `pub` aborts on a 401 rather than backtracking, so one private dependency
  on one old version can poison resolution for a consumer pinned to the
  newest.
- Only dependencies declared with an explicit `hosted:` URL pointing at
  this server count. A bare `foo: ^1.0.0` that happens to share a name with
  a local package is flagged as ambiguous and never auto-included: an
  anonymous consumer resolves it from pub.dev regardless, so exposing the
  local package would buy nothing.

### Versions that cannot resolve

Making a package public makes every version's bytes public. The anonymous
**version list** additionally omits versions whose club-hosted dependencies
are not all public, because that list is the input to a fresh `pub` solve
and a solver that never sees a version never fails on it.

Their manifests and tarballs stay readable, so a lockfile pinned to a
hidden version still fetches and then fails on the actual private
dependency, with `pub`'s own "requires authentication" message rather than
a confusing 404.

### Going back to private

The dangerous direction. Making a package private, or deleting it, breaks
every public package that depends on it. Both paths run a reverse
dependency check first and refuse until the caller either includes the
dependents in the change or explicitly accepts the breakage. The
confirmation shows a concrete chain per affected package
(`app -> core_ui -> icons`) so the causation is visible.

### What anonymous visitors can and cannot see

| Visible | Hidden |
|---|---|
| Package page, README, CHANGELOG, example | Uploader email addresses |
| Version list, manifests, tarballs | Package activity log |
| Scores and generated API docs | Download counts |
| Publisher name and badge | Publisher member lists |
| Like counts | Who liked what |
| Search and browse, filtered to public and listed packages | Any private package, in any listing |

### Other interactions

- **Publishing** a version into a public package that adds a private
  club-hosted dependency succeeds, but the version is absent from the
  anonymous version list. The publish response says so, an audit record is
  written, and the package page shows it.
- **Force republish** (`?force=true`) is refused on a public package.
  Rewriting the bytes of an already-published version breaks archive
  immutability for anyone who recorded its hash.
- **Unlisted** is orthogonal and composes cleanly: `visibility` decides
  who may read a package, `is_unlisted` decides whether it is advertised.
  Public plus unlisted resolves for `dart pub get` without a token but
  never appears in search, browse, or autocomplete.
- **Retraction** does not reduce exposure. Retracted versions remain listed
  and downloadable.
- Every visibility change is recorded in the audit log with the full set of
  packages it moved, so "who exposed our source, and what went with it" is
  answerable afterwards.
