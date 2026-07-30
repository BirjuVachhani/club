## 0.4.1 (Unreleased)

### Changed

- `club publish` resolves dependencies on the unpacked archive in a temp dir instead of the surrounding pub workspace.
- `AnalyzeValidator` and `StrictDependenciesValidator` now read the resolved archive copy rather than the source tree.

### Fixed

- Publishing a package from a pub workspace whose root needs the Flutter SDK no longer fails version solving.
- `club publish` and `club add` pick `flutter pub` over `dart pub` when the pubspec pulls in the Flutter SDK.
- `DependencyOverrideValidator` no longer silently skips its check in Flutter workspaces.
- Release-notes dialog: looser line-height, more space between bullets, larger section headings.

## 0.4.0

### Added

- **`club publish --from-git <url>`**: publish a package straight from a git repository. The repo is shallow-cloned (`--depth 1`, single branch) into `~/.club/clones/<host>/<org>/<repo>`, and the existing publish flow (dependency resolution, validation, upload) runs on the clone unchanged. Use `--ref <branch|tag|commit>` to publish a specific ref (defaults to the remote default branch), combine with `--auto` for monorepos, or `-C` to target a package in a subdirectory. The clone is removed after a successful publish; on failure it is kept so a re-run reuses it via a shallow fetch and force checkout instead of re-cloning.

### Docs

- **Audited the entire documentation site against the source and corrected factual drift across 37 pages.** Fixes include: wrong API error codes (`Forbidden` to `InsufficientPermissions`, `BadRequest` to `InvalidInput`, `RateLimited` to `RateLimitExceeded`) and response shapes; false "public, no authentication" claims on read endpoints (Club is private, reads require auth); stale `club_api` and CLI versions; missing CLI commands (`add`, `global`) and publish flags; an incorrect schema-migration description (there is a versioned `club_schema` migration chain); wrong Docker runtime user and entrypoint; stale `from-source` Dart SDK version; and broken cross-links.
- **Rewrote the "Docker with PostgreSQL" guide** to state plainly that PostgreSQL is not yet implemented. Setting `DB_BACKEND=postgres` currently fails at startup with `UnimplementedError`, so the previous setup instructions were misleading. SQLite is the only supported metadata store.
- **Removed a non-existent feature from the YAML configuration guide.** The guide documented a `{{ENV_VAR}}` substitution syntax that the config loader does not implement, and claimed nested YAML keys work when only `db.backend`, `blob.backend`, and `blob.path` are read in nested form.
- **Fixed the GitHub Actions examples in the CI/CD guide** to pin `BirjuVachhani/club/actions/setup-club` to a real release tag (`0.3.0`); the previous `@v1` tag does not exist.

## 0.3.0

### Changed

- **Copy-to-pubspec now yields a working hosted dependency.** Both the package card and the package detail page previously copied `name: ^version`, which resolves against pub.dev. They now copy a full hosted block pointing at the current server:

  ```yaml
  name:
    hosted: https://your-server
    version: x.y.z
  ```

- **Redesigned the "package not found" page.** It now echoes the missing package name from the URL, explains why a lookup can fail (typo, not yet published, unlisted or no access), and offers a "Search for …" action prefilled with that name alongside "Browse all packages". The card is properly centered instead of hugging the left edge.

### Performance

- **Streamed page loading.** The home page, package list, and package detail now paint their layout and skeleton placeholders immediately, then fill in as data arrives, instead of holding a blank page until every request resolves.
- **New `/api/discover` endpoint** collapses the per-result request fan-out. It returns search hits already bundled with package, score, and list-info data, so the home page and package list make a single request to render a page of results rather than 1 + N (the list page: 1 + 3N). A shared `buildListInfo` helper backs both the new endpoint and the existing per-package `/api/packages/<package>/list-info`.
- **Parallel auth probe in the root layout.** `/api/setup/status` and `/api/auth/me` now run concurrently rather than one after the other, removing a round-trip from every navigation.

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
