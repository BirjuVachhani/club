# club — Build Plan

Phased implementation roadmap. Each phase produces a working increment.

---

## Phase 1: Foundation

**Goal:** Dart workspace scaffolding, domain models, all interfaces.

### Tasks

- [ ] Create workspace `pubspec.yaml` with all packages listed
- [ ] Scaffold `club_core` with pubspec, barrel exports
- [ ] Define domain model records:
  - `Package`, `PackageVersion`, `User`, `AuthToken`
  - `Publisher`, `PublisherMember`, `UploadSession`, `AuditLogRecord`
  - `PackageCompanion`, `UserCompanion`, etc. (creation companions)
- [ ] Define pub spec v2 API DTOs:
  - `PackageData`, `VersionInfo`, `UploadInfo`, `SuccessMessage`
  - `PkgOptions`, `VersionOptions`, `PackagePublisherInfo`
  - `VersionScore` (stub)
- [ ] Define all repository interfaces:
  - `MetadataStore`, `BlobStore`, `SearchIndex`
- [ ] Define exception hierarchy:
  - `ClubException`, `NotFoundException`, `AuthException`
  - `ForbiddenException`, `InvalidInputException`, `PackageRejectedException`
- [ ] Define validation utilities:
  - Package name validator
  - Version canonicalization (wrap `pub_semver`)

**Deliverable:** `club_core` package compiles and exports all types.

---

## Phase 2: Storage Layer

**Goal:** Working SQLite metadata store, filesystem blob store, FTS5 search.

### Tasks

- [ ] Scaffold `club_db` package
- [ ] Define drift table classes (all 10 tables)
- [ ] Write SQL migration scripts (001 through 006)
- [ ] Implement `MigrationRunner` with hash validation
- [ ] Implement `SqliteMetadataStore` (all MetadataStore methods)
- [ ] Scaffold `club_storage` package
- [ ] Implement `FilesystemBlobStore` with atomic writes
- [ ] Implement `SqliteSearchIndex` (FTS5 queries)
- [ ] Write unit tests:
  - MetadataStore CRUD operations (in-memory SQLite)
  - BlobStore put/get/delete (temp directory)
  - SearchIndex indexing and query

**Deliverable:** All three storage implementations pass unit tests.

---

## Phase 3: Core Services

**Goal:** Business logic layer — auth, publishing, package operations.

### Tasks

- [ ] Implement `AuthService`:
  - `createUser` (bcrypt password hashing)
  - `authenticatePassword` (email + password → token)
  - `createApiToken` (generate `club_*` token, store SHA-256 hash)
  - `authenticateToken` (Bearer token → User lookup)
  - `revokeToken`
- [ ] Implement `PublishService`:
  - `startUpload` (create session, return UploadInfo)
  - `receiveUpload` (stream to temp file)
  - `publish` (validate archive, extract content, DB transaction, store blob)
  - Archive validation via `pub_package_reader`
  - Duplicate version detection (idempotent if SHA-256 matches)
  - Upload session cleanup
- [ ] Implement `PackageService`:
  - `listVersions` → `PackageData` (pub spec v2 format)
  - `getVersion` → `VersionInfo`
  - `setOptions` (discontinued, unlisted)
  - `setVersionOptions` (retract)
  - `getUploaders`, `addUploader`, `removeUploader`
  - `setPublisher`
  - Latest version computation (stable vs prerelease)
- [ ] Implement `PublisherService`:
  - Publisher CRUD
  - Member management (add, remove, list)
  - Role checking
- [ ] Implement `LikesService`:
  - Like/unlike
  - Count queries
  - User's liked packages
- [ ] Write unit tests with fake/in-memory stores

**Deliverable:** All services pass unit tests. Full publish → query cycle works.

---

## Phase 4: Server (API + Config + Bootstrap)

**Goal:** Runnable server with HTTP handlers implementing the pub repository spec v2.

### Tasks

- [ ] Scaffold `club_server` package with all sub-directories:
  - `lib/src/api/` — JSON API handlers
  - `lib/src/frontend/` — SSR HTML (Phase 6)
  - `lib/src/middleware/` — request pipeline
  - `lib/src/config/` — configuration
- [ ] Implement `AppConfig` with env var + YAML loading
- [ ] Implement `EnvKeys` constants
- [ ] Implement config validation
- [ ] Implement middleware:
  - `AuthMiddleware` — Bearer token extraction, user context injection
  - `ErrorMiddleware` — ClubException → JSON error response
  - `AcceptHeaderMiddleware` — validate `application/vnd.pub.v2+json`
  - `RequestLoggerMiddleware` — structured request logging
- [ ] Implement pub spec v2 handlers (in `lib/src/api/`):
  - `GET /api/packages/<package>` — list versions
  - `GET /api/packages/<package>/versions/<version>` — version info
  - `GET /api/archives/<package>-<version>.tar.gz` — download/redirect
  - `GET /packages/<package>/versions/<version>.tar.gz` — legacy redirect
  - `GET /api/packages/versions/new` — start upload
  - `POST /api/packages/versions/upload` — receive multipart tarball
  - `GET /api/packages/versions/newUploadFinish` — finalize
- [ ] Implement auth handlers:
  - `POST /api/auth/login`
  - `POST /api/auth/logout`
  - `POST /api/auth/tokens` (create)
  - `GET /api/auth/tokens` (list)
  - `DELETE /api/auth/tokens/<id>` (revoke)
- [ ] Implement package admin handlers:
  - `GET/PUT /api/packages/<package>/options`
  - `GET/PUT /api/packages/<package>/versions/<version>/options`
  - `GET/PUT/DELETE /api/packages/<package>/uploaders`
  - `PUT /api/packages/<package>/publisher`
- [ ] Implement publisher handlers (CRUD + members)
- [ ] Implement likes handlers
- [ ] Implement search handler (`GET /api/search`)
- [ ] Implement package name completion handler
- [ ] Implement score handler (stub returning zeros + like count)
- [ ] Implement health handler (`GET /api/v1/health`)
- [ ] Assemble `Router` combining all API handlers
- [ ] Implement `bootstrap()`:
  - Resolve storage implementations from config
  - Open stores, run migrations
  - Create services
  - Build middleware pipeline and router
  - Start `shelf_io` HTTP server
  - Register SIGTERM handler
  - Bootstrap admin account if configured
- [ ] Implement `bin/server.dart` entry point
- [ ] Write integration tests (in-process shelf handler)
- [ ] End-to-end test: start server → `dart pub publish` → `dart pub get`

**Deliverable:** `dart run bin/server.dart` starts a working pub server.
`dart pub get` and `dart pub publish` work against it.

---

## Phase 5: Web Frontend (SvelteKit)

**Goal:** SvelteKit frontend matching pub.dev design, built as static export.

### Tasks

- [ ] Scaffold `club_web` SvelteKit project with `adapter-static`
- [ ] Configure Vite proxy to forward `/api/*` to Dart server during dev
- [ ] Copy pub.dev CSS/SCSS into `club_web/static/css/`
- [ ] Copy static assets (images, Material bundle) into `club_web/static/`
- [ ] Replace pub.dev branding with club branding (logo, favicon)
- [ ] Implement shared layout (`+layout.svelte`):
  - Site header with navigation
  - Search banner
  - Footer
  - Dark mode toggle (CSS custom properties + localStorage)
  - Auth guard (`+layout.ts` — redirect to `/login` if no token)
- [ ] Implement auth store (Svelte store for token + user state)
- [ ] Implement login page (`/login`)
- [ ] Implement reusable components:
  - `PackageCard.svelte` — package list item
  - `TagBadge.svelte` — SDK/platform/status tags
  - `Pagination.svelte`
  - `SortControl.svelte`
  - `MarkdownRenderer.svelte` — render Markdown with highlight.js
  - `InfoBox.svelte` — package sidebar
  - `LikeButton.svelte` — optimistic toggle
  - `TabLayout.svelte` — tabbed content
- [ ] Implement package listing page (`/packages`):
  - Search form with filter sidebar
  - Package list with scores, tags, metadata
  - Pagination, sort controls
- [ ] Implement package detail page (`/packages/[pkg]`):
  - Package header (name, version, like button, tags)
  - Tabbed layout (Readme, Changelog, Versions, Install, Admin)
  - Info box sidebar (metadata, dependencies, publisher)
  - Markdown rendering for readme/changelog
- [ ] Implement versions page (`/packages/[pkg]/versions`)
- [ ] Implement install tab (with club-specific instructions)
- [ ] Implement package admin tab (uploaders, options)
- [ ] Implement publisher pages (`/publishers`, `/publishers/[id]`)
- [ ] Implement user pages:
  - My packages (`/my-packages`)
  - My liked packages (`/my-liked-packages`)
  - Token management (`/settings/tokens`)
- [ ] Implement admin pages:
  - User management (`/admin/users`)
  - Package moderation (`/admin/packages`)
- [ ] Update `club_server` to serve SvelteKit build output via `shelf_static`
- [ ] Configure SPA fallback (all non-API routes serve `index.html`)
- [ ] Verify `npm run build` produces working static export

**Deliverable:** Full web UI accessible at the server URL. `npm run build`
produces static files served by the Dart server.

---

## Phase 6: Client SDK (club_api)

**Goal:** Publishable Dart client SDK for programmatic club server access.

### Tasks

- [ ] Scaffold `club_api` package
- [ ] Implement `ClubClient` — main entry point with sub-clients
- [ ] Implement `PackagesClient`:
  - `listVersions`, `getVersion`, `downloadArchive`
  - `getOptions`, `setOptions`, `getVersionOptions`, `setVersionOptions`
  - `getPublisher`, `setPublisher`
  - `getUploaders`, `addUploader`, `removeUploader`
  - `getLikeCount`, `getScore`, `listAllNames`
- [ ] Implement `PublishingClient`:
  - Full 3-step upload flow (`startUpload` → `uploadArchive` → `finalizeUpload`)
  - Convenience method `publish(stream)` and `publishFile(path)`
- [ ] Implement `AuthClient`:
  - `login`, `logout`, `createToken`, `listTokens`, `revokeToken`
- [ ] Implement `PublishersClient`:
  - `get`, `create`, `update`, `listMembers`, `addMember`, `removeMember`
- [ ] Implement `SearchClient`:
  - `query`, `completionData`
- [ ] Implement `LikesClient`:
  - `like`, `unlike`, `likedPackages`
- [ ] Implement `AdminClient`:
  - `listUsers`, `createUser`, `updateUser`
  - `deletePackage`, `deleteVersion`
- [ ] Implement `ClubApiException` hierarchy
- [ ] Write unit tests with mock HTTP client

**Deliverable:** `club_api` package compiles and all client methods work
against a running club server.

---

## Phase 7: CLI Tool

**Goal:** `club` CLI for authentication and publishing, using `club_api`.

### Tasks

- [ ] Scaffold `club_cli` package
- [ ] Add `club_api` as dependency
- [ ] Implement `CredentialStore` (read/write `~/.config/club/credentials.json`)
- [ ] Implement `CommandRunner` with all commands (using `ClubClient`):
  - `club login` — authenticate via OAuth PKCE (browser) or `--key` (dashboard-minted PAT)
  - `club logout` — remove credentials
  - `club config` / `club config set-server`
  - `club setup` — run `dart pub token add`
  - `club publish` — wrap `dart pub publish`
  - `club admin user list/create/disable` — via `AdminClient`
  - `club admin package list/moderate` — via `AdminClient`
- [ ] Write tests for credential store and command logic

**Deliverable:** `club login` → `club setup` → `club publish` workflow works.

---

## Phase 8: Docker

**Goal:** Production-ready Docker image and deployment config.

### Tasks

- [ ] Write multi-stage `Dockerfile`
- [ ] Write `docker-compose.yml` (default stack)
- [ ] Write `docker-compose.postgres.yml` (PostgreSQL override)
- [ ] Write `.env.example`
- [ ] Write Caddy config (`Caddyfile`)
- [ ] Write nginx config (`club.conf`)
- [ ] First-class backup/restore feature (deferred — for now, `/data` volume persistence + startup reconciliation cover recreate-container scenarios)
- [ ] Test: `docker compose up` → server starts → publish → download
- [ ] Test: volume persistence across container restarts
- [ ] Test: PostgreSQL override works

**Deliverable:** `docker compose up -d` deploys a working club instance.

---

## Phase 9: End-to-End Testing & CI

**Goal:** Full E2E test suite and CI/CD pipeline.

### E2E Test Script (`test/e2e/run_e2e.sh`)

- [ ] Write E2E bash script that runs against a live server
- [ ] Test: Login and get API token
- [ ] Test: Health check endpoint
- [ ] Test: Create and revoke API tokens
- [ ] Test: Create a test package directory with pubspec/lib/README/CHANGELOG
- [ ] Test: `dart pub publish` to club server succeeds
- [ ] Test: Verify package via API (`GET /api/packages/<name>`)
- [ ] Test: `dart pub get` resolves from club server
- [ ] Test: Download archive directly and verify contents
- [ ] Test: Publish v2, verify version ordering and latest update
- [ ] Test: Retract a version, verify latest falls back
- [ ] Test: Package options (discontinue, unlist)
- [ ] Test: Search returns published package
- [ ] Test: Like/unlike and count consistency
- [ ] Test: Auth failures (no token → 401, invalid token → 401)
- [ ] Test: Revoked token → 401
- [ ] Test: `PUB_HOSTED_URL` works with `dart pub get`
- [ ] Test: `club` CLI basic operations

### CI Pipeline (GitHub Actions)

- [ ] Write `.github/workflows/ci.yml` with 4 parallel jobs:
  - `dart-tests`: analyze, format, unit tests for all Dart packages, integration tests
  - `frontend-tests`: svelte-check, npm test, npm run build
  - `e2e-tests` (depends on above): start server, run E2E script
  - `docker-build` (depends on above): build image, start container, smoke test

### Docker E2E

- [ ] Write `docker-compose.test.yml` for isolated E2E testing
- [ ] Write `Dockerfile.test` for the E2E test runner container

**Deliverable:** Full test suite passes locally and in CI. All dart pub
operations verified against a real server.

See [DEVELOPMENT.md](DEVELOPMENT.md) for the complete test scripts and CI config.

---

## Phase 10: Documentation & Polish

**Goal:** Production-ready documentation and final polish.

### Tasks

- [ ] Review and finalize all docs in `docs/`
- [ ] Write root README.md with quickstart
- [ ] Add LICENSE file
- [ ] Add CHANGELOG.md
- [ ] Code review pass for security issues
- [ ] Code review pass for error handling
- [ ] Performance check (large tarball upload, many packages search)
- [ ] Finalize club branding (logo, favicon)

**Deliverable:** Ready for v1.0.0 release.

---

## Implementation Order Summary

```
Phase 1: Foundation      ─── Pure Dart types, zero dependencies
Phase 2: Storage         ─── SQLite + filesystem, testable in isolation
Phase 3: Services        ─── Business logic on top of storage
Phase 4: Server          ─── API handlers + config + runnable binary
Phase 5: Frontend        ─── Web UI matching pub.dev (inside club_server)
Phase 6: Client SDK      ─── club_api publishable package
Phase 7: CLI             ─── club CLI tool (uses club_api)
Phase 8: Docker          ─── Containerized deployment
Phase 9: Testing         ─── End-to-end integration tests
Phase 10: Polish         ─── Docs, security, release prep
```

Each phase builds on the previous one. Phases 5, 6, and 7 can be worked on
in parallel after Phase 4 is complete.
