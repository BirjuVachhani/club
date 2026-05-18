## 0.3.0

### Changed

- **Copy-to-pubspec now yields a working hosted dependency.** Both the package card and the package detail page previously copied `name: ^version`, which resolves against pub.dev. They now copy a full hosted block pointing at the current server:

  ```yaml
  name:
    hosted: https://your-server
    version: x.y.z
  ```

- **Redesigned the "package not found" page.** It now echoes the missing package name from the URL, explains why a lookup can fail (typo, not yet published, unlisted or no access), and offers a "Search for …" action prefilled with that name alongside "Browse all packages". The card is properly centered instead of hugging the left edge.

### Added

- **Installation hint on the package page.** The `club add` instructions now link to the CLI installation guide for visitors who don't have the CLI yet.
- **Navigation progress bar.** A thin progress bar now appears at the top of the page during in-app navigation. Client-side routing never triggers the browser's native tab spinner, so slow page loads previously felt frozen; the bar restores that "something is loading" feedback.

### Fixed

- **Browser back/forward on package pages**: opening a package, going back, then forward failed to restore the package view. Syncing the active tab to the URL hash passed `null` to `history.replaceState`, which wiped SvelteKit's internal navigation state for that history entry. It now preserves the existing state object.
- **Invite page layout**: the invite acceptance page no longer shrinks to its content width; it now fills and centers correctly.
- **Dropdown chevron spacing**: select dropdowns across the web app now use a consistent custom chevron with proper right spacing, so the arrow no longer touches the outline border (role selects on the publishers admin and users admin pages, the package publisher control, and the SDK settings selects).

### Docs

- The "Login & Setup" CLI guide is now ordered correctly in the docs sidebar.

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
