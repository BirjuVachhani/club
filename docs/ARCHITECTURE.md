# club — System Architecture

## Overview

club is a single-process Dart server that implements the Dart Pub Repository
Specification v2, serves a web UI visually identical to pub.dev, and provides
a CLI tool for authentication and publishing.

The system uses constructor-injected dependency inversion with three pluggable
storage layers. The default stack (SQLite + filesystem + FTS5) requires zero
external dependencies and runs as a single Docker container.

---

## High-Level Architecture

```
                    ┌──────────────────┐
                    │   Reverse Proxy   │
                    │  (Caddy / nginx)  │
                    │   TLS termination │
                    └────────┬─────────┘
                             │ :443 → :8080
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│                     club_server                                 │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                    Middleware Pipeline                      │  │
│  │  RequestLogger → Auth → Accept Header → Error Handler      │  │
│  └──────────────────────────┬─────────────────────────────────┘  │
│                             │                                    │
│  ┌──────────┐  ┌───────────┴──────────┐  ┌────────────────────┐ │
│  │  Pub API  │  │   Static File Server  │  │   Admin/Auth API   │ │
│  │  Handlers │  │   (SvelteKit build)   │  │     Handlers       │ │
│  └─────┬─────┘  └──────────┬───────────┘  └─────────┬─────────┘ │
│        │                   │                         │           │
│  ┌─────┴───────────────────┘─────────────────────────┴─────────┐ │
│  │                      club_core                              │ │
│  │  Services: AuthService, PublishService, PackageService,      │ │
│  │            PublisherService                                  │ │
│  │  Models:   Package, PackageVersion, User, Token, Publisher   │ │
│  │  Interfaces: MetadataStore, BlobStore, SearchIndex           │ │
│  └─────┬───────────────────┬───────────────────┬───────────────┘ │
│        │                   │                   │                 │
│  ┌─────┴──────┐  ┌────────┴────────┐  ┌──────┴──────────────┐  │
│  │  club_db   │  │  club_storage   │  │   Search Index      │  │
│  │  SQLite     │  │  Filesystem      │  │   SQLite FTS5       │  │
│  │  (or PG)    │  │  (or S3)         │  │   (or Meilisearch)  │  │
│  └─────────────┘  └─────────────────┘  └─────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
                             ▲
    ┌────────────────┐       │ Built at Docker build time,
    │  club_web      │───────┘ output served as static files
    │  (SvelteKit)    │
    │  adapter-static │   No Node.js at runtime
    └────────────────┘

    ┌──────────────┐         ┌──────────────────┐
    │  club_cli    │ ──────►│   club_api       │
    │  Login/Setup  │  uses  │   (Client SDK)    │
    │  Tokens/Admin │        │   ClubClient     │──► club server
    └──────────────┘         └──────────────────┘
                                     │
                             dart pub token add
                                     ▼
                             ~/.pub-cache/credentials.json

    ┌──────────────────────────────────────┐
    │  Your Dart app / CI tool / script     │
    │  import 'package:club_api/...';     │──► club_api ──► club server
    └──────────────────────────────────────┘
```

---

## Monorepo Structure

Dart workspace (Dart 3.5+ `workspace:` feature) with all packages in one repo:

```
club/
├── pubspec.yaml                    # Workspace root
├── packages/
│   ├── club_server/               # Dart API server + static file serving
│   │   ├── bin/
│   │   │   └── server.dart         # main() — bootstrap and start
│   │   ├── lib/
│   │   │   ├── src/
│   │   │   │   ├── api/            # Pub spec v2 + auth + admin JSON handlers
│   │   │   │   ├── middleware/     # Auth, error, logging, accept header
│   │   │   │   ├── static/        # Static file serving (SvelteKit build output)
│   │   │   │   ├── config/
│   │   │   │   │   ├── app_config.dart
│   │   │   │   │   └── env_keys.dart
│   │   │   │   ├── router.dart    # API routes + static fallback
│   │   │   │   └── bootstrap.dart # Wiring: create stores, services, router
│   │   │   └── club_server.dart
│   │   └── pubspec.yaml
│   │
│   ├── club_web/                  # SvelteKit frontend (static export)
│   │   ├── src/
│   │   │   ├── routes/            # File-based routing (pages)
│   │   │   ├── lib/               # Components, stores, utils
│   │   │   └── app.html           # HTML shell
│   │   ├── static/                # pub.dev CSS, images, fonts
│   │   ├── svelte.config.js       # adapter-static config
│   │   ├── package.json
│   │   └── vite.config.ts
│   │
│   ├── club_core/                 # Domain models, interfaces, services
│   │   ├── lib/
│   │   │   ├── src/
│   │   │   │   ├── models/         # Domain records + API DTOs
│   │   │   │   ├── repositories/   # Abstract interfaces
│   │   │   │   ├── services/       # Business logic
│   │   │   │   ├── validation/     # Package name, version validators
│   │   │   │   └── exceptions.dart
│   │   │   └── club_core.dart
│   │   └── pubspec.yaml
│   │
│   ├── club_db/                   # Drift/SQLite implementation
│   │   ├── lib/
│   │   │   ├── src/
│   │   │   │   ├── tables.dart
│   │   │   │   ├── database.dart
│   │   │   │   ├── repositories/   # Concrete Drift implementations
│   │   │   │   └── migrations/
│   │   │   └── club_db.dart
│   │   └── pubspec.yaml
│   │
│   ├── club_storage/              # Blob storage interface + filesystem impl
│   │   ├── lib/
│   │   │   ├── src/
│   │   │   │   ├── storage_backend.dart
│   │   │   │   └── filesystem/
│   │   │   └── club_storage.dart
│   │   └── pubspec.yaml
│   │
│   ├── club_api/                  # Client SDK for programmatic server access
│   │   ├── lib/
│   │   │   ├── src/
│   │   │   │   ├── club_client.dart    # Main client class
│   │   │   │   ├── packages.dart        # Package operations
│   │   │   │   ├── publishing.dart      # Publish flow
│   │   │   │   ├── auth.dart            # Login, token management
│   │   │   │   ├── publishers.dart      # Publisher operations
│   │   │   │   ├── search.dart          # Search queries
│   │   │   │   └── admin.dart           # Admin operations
│   │   │   └── club_api.dart           # Barrel export
│   │   └── pubspec.yaml
│   │
│   └── club_cli/                  # CLI tool (uses club_api)
│       ├── bin/
│       │   └── club.dart
│       ├── lib/
│       │   ├── src/
│       │   │   ├── commands/
│       │   │   ├── credentials.dart
│       │   │   └── config.dart
│       │   └── club_cli.dart
│       └── pubspec.yaml
│
├── static/                         # Shared static assets (copied into club_web)
│   ├── css/
│   ├── img/
│   └── material/
├── config/
│   └── config.example.yaml
├── docker/
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── docker-compose.postgres.yml
│   ├── caddy/Caddyfile
│   └── nginx/club.conf
├── docs/
└── research/
    └── pub-dev/                    # Reference pub.dev source (gitignored)
```

---

## Package Dependency Graph

```
club_server (Dart API server binary)
  ├── club_core
  ├── club_db
  │   └── club_core
  ├── club_storage
  │   └── club_core
  └── serves static files from club_web build output

club_web (SvelteKit frontend — static export, no runtime)
  └── calls club_server API via fetch()

club_api (Dart client SDK — publishable package)
  └── club_core (shares DTOs/models)

club_cli (Dart CLI tool — uses client SDK)
  └── club_api
      └── club_core
```

**club_core** has zero I/O dependencies — only `pub_semver`, `crypto`,
`json_annotation`, `equatable`, `meta`, `clock`. This makes it safe to
unit test with pure fakes.

**club_api** is a publishable Dart package. Users can `dart pub add club_api`
to interact with any club server programmatically from their own tools,
scripts, or CI/CD pipelines. It provides a typed `ClubClient` class that
wraps all HTTP calls.

**club_cli** uses `club_api` internally — no raw HTTP calls. This means
the CLI and any custom tooling share the same battle-tested client code.

---

## Storage Abstraction

Three interfaces define the storage contract. Implementations are resolved
at startup based on configuration.

### MetadataStore

Handles all relational data: packages, versions, users, tokens, publishers,
likes, audit log.

```dart
abstract interface class MetadataStore {
  Future<void> open();
  Future<void> close();
  Future<void> runMigrations();

  // Package CRUD, version CRUD, user CRUD, token CRUD,
  // publisher CRUD, likes, audit log, transactions
  // See DATABASE.md for full interface
}
```

| Implementation | Package | Backend |
|---------------|---------|---------|
| `SqliteMetadataStore` | club_db | SQLite (drift) |
| `PostgresMetadataStore` | club_db | PostgreSQL (drift) |

### BlobStore

Handles binary tarball storage.

```dart
abstract interface class BlobStore {
  Future<void> open();
  Future<void> close();
  Future<BlobInfo> put(String package, String version, Stream<List<int>> bytes);
  Future<Stream<List<int>>> get(String package, String version);
  Future<bool> exists(String package, String version);
  Future<void> delete(String package, String version);
  Future<Uri?> signedDownloadUrl(String package, String version);
}
```

| Implementation | Package | Backend |
|---------------|---------|---------|
| `FilesystemBlobStore` | club_storage | Local filesystem |
| `S3BlobStore` | club_storage | S3-compatible (AWS, MinIO) |

### SearchIndex

Handles full-text package search.

```dart
abstract interface class SearchIndex {
  Future<void> open();
  Future<void> close();
  Future<void> indexPackage(IndexDocument doc);
  Future<void> removePackage(String package);
  Future<SearchResult> search(SearchQuery query);
  Future<void> reindex(Stream<IndexDocument> documents);
}
```

| Implementation | Package | Backend |
|---------------|---------|---------|
| `SqliteSearchIndex` | club_db | SQLite FTS5 |
| `MeilisearchIndex` | club_db | Meilisearch |

---

## Startup Wiring

`bin/server.dart` → `bootstrap()`:

```
1. Load AppConfig from env vars + optional YAML file
2. Validate config (required fields, backend-specific checks)
3. Resolve storage implementations:
   - MetadataStore ← config.dbBackend (sqlite/postgres)
   - BlobStore     ← config.blobBackend (filesystem/s3)
   - SearchIndex   ← config.searchBackend (sqlite/meilisearch)
4. Open all stores, run migrations
5. Create services (AuthService, PublishService, PackageService, PublisherService)
6. Create handlers, build middleware pipeline, assemble Router
7. Start shelf_io HTTP server
8. Register SIGTERM handler for graceful shutdown
9. Bootstrap admin account if CLUB_ADMIN_EMAIL is set and no users exist
```

---

## Request Flow

### `dart pub get` — Package Resolution

```
dart pub get
  → GET /api/packages/<name>
    → AuthMiddleware: validate Bearer token
    → PubApiHandler.listVersions()
      → PackageService.listVersions(name)
        → MetadataStore.lookupPackage(name)
        → MetadataStore.listVersions(name)
      ← PackageData JSON (pub spec v2)

  → GET /api/archives/<name>-<version>.tar.gz
    → AuthMiddleware: validate Bearer token
    → ArchiveHandler.serve()
      → BlobStore.signedDownloadUrl(name, version)
        if non-null → 302 redirect
        if null     → BlobStore.get() → proxy stream
```

### `dart pub publish` — Package Upload

```
dart pub publish
  → GET /api/packages/versions/new
    → AuthMiddleware: validate Bearer token
    → UploadHandler.getUploadUrl()
      → Create upload session (UUID, user, expiry)
      ← { url: "<server>/api/packages/versions/upload",
          fields: { upload_id: "<guid>" } }

  → POST /api/packages/versions/upload (multipart form data)
    → AuthMiddleware: validate Bearer token
    → UploadHandler.receiveUpload()
      → Stream tarball to temp file (never buffer in memory)
      → Update session state → 'received'
      ← 302 → /api/packages/versions/newUploadFinish?upload_id=<guid>

  → GET /api/packages/versions/newUploadFinish?upload_id=<guid>
    → AuthMiddleware: validate Bearer token
    → UploadHandler.finalizeUpload()
      → PublishService.publish(uploadGuid, userId):
          1. Read temp file, compute SHA-256
          2. Extract + validate archive (pub_package_reader)
          3. Parse pubspec, validate version
          4. Check authorization (uploader or publisher admin)
          5. Check duplicate version
          6. Extract README, CHANGELOG, libraries
          7. DB transaction:
             - Create/update Package
             - Create PackageVersion
             - Update latest version pointers
             - Append audit log
             - FTS index triggers fire
          8. BlobStore.put(package, version, bytes)
          9. Delete temp file
      ← { success: { message: "Successfully uploaded..." } }
```

### Web UI Page Render

```
GET /packages/<name>
  → AuthMiddleware: validate session cookie (redirect to /login if absent)
  → PackageHandler.showPackage()
    → PackageService.getPackageDetail(name)
    → Render DOM tree:
        renderLayoutPage(
          pageLayoutNode(
            siteHeaderNode(),
            searchBannerNode(),
            detailPageNode(
              packageHeaderNode(),
              tabsNode(readmeTab, changelogTab, versionsTab, installTab),
              packageInfoBoxNode()
            ),
            footerNode()
          )
        )
    → Serialize DOM to HTML string
    ← Response.ok(html, headers: {'content-type': 'text/html'})
```

---

## Frontend Architecture

### SvelteKit with Static Export

The frontend is a SvelteKit application built with `adapter-static`. At Docker
build time, it compiles to plain HTML + JS + CSS files. The Dart server serves
these as static files — **no Node.js at runtime**.

### How It Works

```
Docker build time:
  npm run build (SvelteKit)
    → adapter-static
    → /build/ directory (HTML, JS, CSS)
    → Copied into Docker image at /app/static/web/

Runtime:
  Dart shelf server
    → /api/* routes → JSON API handlers
    → /* everything else → shelf_static serves /app/static/web/
    → SvelteKit client-side router takes over in the browser
    → Pages fetch data from /api/* via fetch()
```

### SvelteKit Route Structure

```
packages/club_web/src/routes/
├── +layout.svelte                  # Shared layout: header, footer, dark mode
├── +layout.ts                      # Auth check: redirect to /login if no token
├── +page.svelte                    # / → redirect to /packages
├── login/+page.svelte              # Login form
├── packages/
│   ├── +page.svelte                # Package listing + search + filters
│   ├── +page.ts                    # Fetch: GET /api/search or /api/packages
│   └── [pkg]/
│       ├── +page.svelte            # Package detail (readme tab)
│       ├── +page.ts                # Fetch: GET /api/packages/<pkg>
│       ├── changelog/+page.svelte
│       ├── versions/+page.svelte
│       ├── install/+page.svelte
│       └── admin/+page.svelte
├── publishers/
│   ├── +page.svelte                # Publisher list
│   └── [id]/+page.svelte           # Publisher detail + packages
├── my-packages/+page.svelte
├── my-liked-packages/+page.svelte
├── settings/
│   └── tokens/+page.svelte         # Token management
└── admin/
    ├── users/+page.svelte
    └── packages/+page.svelte
```

### Data Loading Pattern

Each page loads data via SvelteKit's `load` function, which calls the API:

```typescript
// src/routes/packages/[pkg]/+page.ts
export async function load({ params, fetch }) {
  const [pkgRes, scoreRes] = await Promise.all([
    fetch(`/api/packages/${params.pkg}`),
    fetch(`/api/packages/${params.pkg}/score`),
  ]);
  return {
    package: await pkgRes.json(),
    score: await scoreRes.json(),
  };
}
```

In the static export, these `load` functions run **client-side** in the browser.
The SvelteKit client-side router intercepts navigation and calls `load` via
`fetch()` to the API.

### CSS / Design System

Copied from pub.dev and adapted:

- pub.dev's SCSS compiled to CSS, included in `club_web/static/css/`
- CSS custom properties for light/dark themes from `_variables.scss`
- Material Design component styles from `third_party/material/`
- Google Fonts (Google Sans family)
- Dark mode via CSS classes + localStorage (same approach as pub.dev)

### What's Changed from pub.dev

- Removed: Google Analytics, GTM, announcement banner, scoring UI, dartdoc links
- Added: Login page, token management page, admin panel
- Modified: Logo/branding, install instructions (point to club server), auth flow
- Technology: Svelte components instead of Dart DOM builder functions

### Auth in the SPA

Since the frontend is a static SPA:

1. Login page calls `POST /api/auth/login` → receives API token
2. Token stored in `localStorage` (or `httpOnly` cookie set by the server)
3. All subsequent `fetch()` calls include `Authorization: Bearer <token>`
4. SvelteKit's `+layout.ts` checks for token; redirects to `/login` if absent
5. Token expiry handled client-side with redirect to `/login`

See [FRONTEND.md](FRONTEND.md) for full frontend documentation.

---

## Authentication Architecture

### Two Token Types

1. **Session JWT** — for web UI, stored in HttpOnly cookie
   - Signed with HMAC-SHA256 using `CLUB_JWT_SECRET`
   - Short-lived (configurable, default 1 hour)
   - Contains: `userId`, `email`, `isAdmin`, `exp`

2. **API Token** — for `dart pub` client and CI/CD
   - Format: `club_<32-char-hex>` (39 chars total)
   - Stored in DB as SHA-256 hash (raw shown once at creation)
   - Long-lived (configurable, default 365 days)
   - Contains scopes: `read`, `write`, `admin`

### Auth Middleware Detection

```
Authorization: Bearer <token>
  │
  ├── starts with "club_" → API token path
  │   → SHA-256(token)
  │   → MetadataStore.lookupToken(hash)
  │   → Check: not revoked, not expired
  │   → Update last_used_at
  │   → Load User
  │
  └── otherwise → JWT session path
      → Verify HMAC signature
      → Check: not expired
      → Extract userId
      → Load User
```

---

## Error Handling

All errors conform to the pub spec v2 format:

```json
{"error": {"code": "<CODE>", "message": "<human-readable message>"}}
```

### Exception Hierarchy

```
ClubException (abstract)
  ├── NotFoundException       → 404
  ├── AuthException           → 401
  ├── ForbiddenException      → 403
  ├── InvalidInputException   → 400
  ├── PackageRejectedException → 400 (code: "PackageRejected")
  └── ConflictException       → 409
```

The `ErrorMiddleware` catches all `ClubException` subclasses and renders
the appropriate HTTP status + JSON body. Unhandled exceptions return 500
with a generic message (no stack traces in production).

---

## Key Dependencies

| Package | Version | Used In | Purpose |
|---------|---------|---------|---------|
| `shelf` | ^1.4 | club_server | HTTP server framework |
| `shelf_router` | ^1.1 | club_server | URL routing |
| `drift` | ^2.19 | club_db | SQLite/PostgreSQL ORM |
| `sqlite3` | ^2.4 | club_db | Native SQLite bindings |
| `pub_semver` | ^2.1 | club_core | Semantic version parsing |
| `pub_package_reader` | ^0.5 | club_core | Tarball validation/extraction |
| `pubspec_parse` | ^1.3 | club_core | pubspec.yaml parsing |
| `crypto` | ^3.0 | club_core | SHA-256 for token hashing |
| `dart_jsonwebtoken` | ^2.9 | club_server | JWT signing/verification |
| `bcrypt` | ^1.1 | club_server | Password hashing |
| `uuid` | ^4.4 | club_server | UUID generation |
| `http` | ^1.2 | club_api | HTTP client for API calls |
| `args` | ^2.5 | club_cli | CLI argument parsing |
| `markdown` | ^7.0 | club_server | Markdown → HTML rendering |
| `yaml` | ^3.1 | club_server | Config file parsing |

---

## Security Considerations

- **All access requires authentication** — no anonymous endpoints except health check
- **Passwords**: bcrypt with cost=12
- **API tokens**: stored as SHA-256 hash, raw shown once
- **JWT secret**: minimum 32 characters, validated at startup
- **Session cookies**: HttpOnly, Secure, SameSite=Strict
- **CSRF protection**: on all state-modifying web endpoints
- **HTML sanitization**: allowlist-based sanitizer on all rendered Markdown
- **Upload streaming**: tarballs streamed to disk, never buffered in memory
- **Temp file cleanup**: background timer removes expired upload sessions
- **Atomic file writes**: temp file + rename pattern prevents partial writes
- **SQLite WAL mode**: concurrent reads during writes
- **Input validation**: package names, versions, emails validated before storage
