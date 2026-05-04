## 0.2.0

### Added

- **MCP server**: new `club mcp` command exposing Club over the Model Context Protocol. Includes tools for accounts, packages, search, dependencies, and server registry, plus a dartdoc proxy.
- **Internal scoring token**: pana can now resolve private dependencies during scoring via a server-issued internal token, so packages that depend on other Club-hosted packages score correctly.
- **Pana report overrides**: Club-specific scoring overrides applied on top of pana output (with full test coverage).
- **Markdown export** for scoring reports, plus UI improvements on the package Scores tab.
- **WASM and build hooks** detection in derived tags.
- **`pana_tags` column** on `package_scores` to persist pana-derived tags alongside the report.
- **New API models**: `PackageDartdocStatus`, `PackageScoringReport`, `VersionContent`.
- **`ClubClient` additions** for the new endpoints.
- **Server update notifier**: admin-only release-notes dialog and stats-page Version card that surface a new Club release once the matching `ghcr.io/birjuvachhani/club:<ver>` image is actually pullable, so notifications never fire ahead of CI. Includes "OK" (per-version dismiss) and "Remind me later" (24-hour snooze) persisted in `localStorage`, plus a "View on GitHub" link to the release. Backed by a new `UpdateChecker` service refreshed hourly by the in-process scheduler and exposed via `GET /api/admin/update-status`.
- **Public `/api/v1/version` endpoint**: lightweight footer pill rendered for every visitor (signed-out included). The running version is the new single-source `kServerVersion` constant, surfaced everywhere the server advertises itself (footer, `/api/v1/health`, update-status).
- **Docs**: new guides for auto-publish, MCP, prepare, monorepo publishing, and dartdoc serving (with OG images).

### Changed

- **Schema versioning & migrations** in `club_db` refactored for clearer version handling.
- **Sidebar dependency rendering** normalized; `loadPackage` now retains raw dependency descriptors so hosted/git/path/sdk deps render consistently.
- **PackageCard** and packages listing UI refinements.
- **Auth middleware** updated to accept the internal scoring token on scoped routes.
- **Server version** is now defined in a single dedicated file (`packages/club_server/lib/src/version.dart`) via `String.fromEnvironment('CLUB_SERVER_VERSION', defaultValue: …)`, mirroring the CLI pattern. CI can inject the tag at build time without dirtying the working tree, and `scripts/set-version.sh` patches the `defaultValue:` instead of the previous duplicated `/health` literal, eliminating the long-standing risk of pubspec and runtime version drifting apart.
- **Dialog chrome unified** across the SvelteKit app: extracted backdrop, blur, radius, and shadow into shared `--dialog-*` CSS tokens (`app.css`) so every modal (`Dialog`, `IntegrityDialog`, `UpdateNotifierDialog`, SDK rescan modal) renders with the same shape. The overlay is now theme-stable, fixing a dark-mode regression where mixing `--foreground` with transparent brightened the page instead of dimming it.
- `pubspec.lock` is now committed at the repo root.

### Fixed

- npm vulnerabilities in `club_web` dependencies.
- Various small CLI fixes across `add`, `publish`, `prepare`, `login`, `logout`, `setup`, and `config` commands.
- **Dummy seed crash on macOS**: `dummy_data/seed.sh` now sets `TEMP_DIR` and `LOGS_DIR` for its temp server so it no longer falls back to the prod default `/data/...` path, which is read-only on macOS and broke `--dummy` provisioning from a clean checkout.

## 0.1.0

- Initial release.
