# CLAUDE.md — Project Notes for club

## What is this?

club is a self-hosted, private Dart package repository. It implements the
Dart Pub Repository Specification v2 and is fully compatible with
`dart pub get`, `dart pub publish`, and `dart pub add`.

## Project Structure

Dart monorepo workspace with 7 packages + 2 Astro sites:

- `packages/club_core` — Domain models, repository interfaces, services, validation, exceptions. Zero I/O deps.
- `packages/club_db` — SQLite implementation via drift (raw SQL, no codegen). Implements MetadataStore + SearchIndex.
- `packages/club_storage` — Blob storage abstraction + filesystem implementation.
- `packages/club_server` — API server (shelf), middleware, config, bootstrap. Serves the SvelteKit build as static files.
- `packages/club_web` — SvelteKit frontend (adapter-static). Compiles to static HTML/JS/CSS. No Node.js at runtime.
- `packages/club_api` — Client SDK. Typed `ClubClient` class for programmatic access.
- `packages/club_cli` — CLI tool. Login, tokens, setup, publish, admin commands. Uses club_api.
- `sites/docs` — Astro + Starlight docs site (docs.club.dev).
- `sites/web` — Astro product site (club.dev) — not yet created.

## Key Commands

```bash
# Install all Dart deps
dart pub get

# Generate code (club_core only)
cd packages/club_core && dart run build_runner build --delete-conflicting-outputs

# Analyze all Dart packages
for pkg in club_core club_db club_storage club_server club_api club_cli; do
  dart analyze packages/$pkg
done

# Build SvelteKit frontend
cd packages/club_web && npm run build

# Build server binary (uses dart build cli, not dart compile exe)
dart build cli -t packages/club_server/bin/server.dart -o build/server
# Binary output: build/server/bundle/bin/server

# Run server locally (dev mode, no build needed)
SERVER_URL=http://localhost:8080 \
JWT_SECRET=dev-secret-at-least-32-characters-long-for-testing \
ADMIN_EMAIL=admin@localhost \
ADMIN_PASSWORD=admin \
SQLITE_PATH=/tmp/club-dev.db \
BLOB_PATH=/tmp/club-dev-packages \
dart run packages/club_server/bin/server.dart

# Docker build + test locally
./scripts/dev-build.sh
./scripts/dev-run.sh

# Build docs site
cd sites/docs && npm install && npm run build
```

## Build Notes

- **ALWAYS use `dart build cli`** instead of `dart compile exe`. `dart build cli` is the recommended way to build Dart CLI apps — it leverages build hooks by default.
- Build output structure: `<output_dir>/bundle/bin/<executable>` + `<output_dir>/bundle/lib/<dynamic libraries>`
- The Dockerfile uses `dart build cli -t packages/club_server/bin/server.dart -o /app/build/server`

## Architecture Decisions

- **Storage is abstracted** via 3 interfaces: MetadataStore, BlobStore, SearchIndex. Default: SQLite + filesystem + FTS5. Swap via env vars.
- **Auth**: bcrypt passwords + SHA-256 hashed API tokens (prefix `club_`). JWT for web sessions.
- **Upload flow**: Direct multipart upload to the server (no signed URLs to external storage).
- **Frontend**: SvelteKit with adapter-static. Built at Docker build time, served by the Dart shelf server. No Node.js at runtime.
- **club_db uses raw SQL** via drift (no drift table codegen). This avoids build_runner complexity for the db package.
- **club_core uses json_serializable** codegen for model serialization. Run build_runner after changing models.

## Important Patterns

- All timestamps stored as Unix milliseconds (INTEGER) in SQLite
- Boolean fields stored as INTEGER (0/1) in SQLite
- JSON fields (scopes, libraries) stored as TEXT
- API errors follow pub spec v2 format: `{"error": {"code": "...", "message": "..."}}`
- Token format: `club_<32-hex-chars>` (stored as SHA-256 hash, raw shown once)
- Multipart upload parsing in pub_api.dart is simplified — works for dart pub client

## Docs

- `docs/` — Internal dev docs (markdown)
- `sites/docs/` — Public docs site (Astro + Starlight, deployed to docs.club.dev)
- See README.md for the full index.


## Additional Notes & Rules

- Don't prefix env variables or configs with project name prefix. e.g. CLUB_
