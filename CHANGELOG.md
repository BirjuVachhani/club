## 0.7.0

### Added

- Package groups organize related packages into searchable, manually ordered collections with user or publisher ownership.
- Group detail and administration views support package selection, drag-and-drop reordering, and group management.
- Group names participate in discovery, with dedicated group results and matching member packages.

### Changed

- Package, group, and admin listings share consistent cards, menus, search controls, dialogs, and responsive styling.
- Group package listings now include the same platform, screenshot, score, download, publisher, and license metadata as package search results.

### Fixed

- The home page sign-in action remains visible against its background in dark mode.
- Group management feedback, dropdown spacing, dividers, package editing, and action placement now render consistently.

## 0.6.1

### Changed

- The dependency closure review is a dialog instead of an inline panel, and the Visibility section reads as its own section with a real call to action.
- Scrollbars are themed to match the site in both light and dark mode.

### Fixed

- Making a package private now checks public dependents of every package in the cascade, not just the target.
- The web UI only claims to accept breakage it actually showed, so the server can still refuse dependents that appeared after the review.
- A failed closure re-analysis blocks the confirm button instead of leaving it live over stale numbers.
- The closure counts skip packages that are missing or already at the target visibility.
- A preview response that outlives its dialog can no longer overwrite the state of another package.
- Opening a dialog no longer shifts the page sideways.
- Focus rings on inputs inside a dialog are no longer clipped.

## 0.6.0

### Added

- Packages can be marked public, so `dart pub get` resolves them without a token and visitors can browse them without an account.
- Public access is gated twice, by `PUBLIC_PACKAGES_ENABLED` in the environment and an admin toggle under Admin > Public packages. Turning either off makes every public package require credentials again on the next request.
- Marking a package public walks its transitive club-hosted dependency graph and flips the whole closure in one confirmed action.
- The closure spans every version rather than only the latest, because `pub` aborts on a 401 instead of backtracking.
- Only `dependencies` join the closure. Dev dependencies and overrides are listed separately and never force a package public.
- A dependency without an explicit `hosted:` URL for this server is flagged ambiguous and never auto-included.
- Making a package private, or deleting it, runs a reverse dependency check and refuses until the caller includes the dependents or accepts the breakage.
- The anonymous version list omits versions whose club-hosted dependencies are not all public. Their manifests and tarballs stay readable, so a pinned lockfile fails with `pub`'s own credentials message rather than a 404.
- `robots.txt`, reflecting whether anonymous browsing is enabled.
- The admin stats page reports database size, reclaimable space, and the largest tables and indexes.
- Schema v3 adds package visibility, per-version public resolvability, and a dependency edge index. Existing databases migrate on boot.

### Changed

- Unlisted packages are excluded from keyword search, browse, and autocomplete for every caller, signed in or anonymous.
- Uploader email addresses are redacted from list-info and discover responses for anonymous callers.
- Collection reads require a `VisibilityScope`, so a missing filter is a compile error rather than a silent leak.
- Force republish (`?force=true`) is refused on a public package, since rewriting published bytes breaks archive immutability.
- `versions` and `archives` are rejected as package names, as they collide with fixed route segments.
- Package delete actions in the admin table are outlined icon buttons rather than filled red ones.
- `docs/CONFIGURATION.md` rewritten against the code.

### Fixed

- Recently Added on the home page lists the newest packages first.
- Screenshots, README assets, and dartdoc for auth-gated packages are no longer served with `Cache-Control: public`, which let a shared cache re-serve private package content.
- An `AuthException` thrown from a handler keeps its `WWW-Authenticate` header, so `dart pub publish` prompts for credentials instead of failing opaquely.
- A malformed path parameter returns a clean 404 instead of escaping as a 500.

## 0.5.1

### Fixed

- `club publish` no longer fails resolution on a package whose archive carries an `example/` or other nested package.
- Nested packages are excluded from the resolution copy, so their unresolved imports no longer count against the package being published.
- Leak detection allows the Google API key in a generated Firebase client config (`firebase_options.dart`, `google-services.json`, `GoogleService-Info.plist`), which identifies a project rather than authenticating one. Other credentials in those files still fail.

## 0.5.0

### Added

- `club upgrade` upgrades the CLI in place, with `--check`, `--version`, `--pre`, `--dry-run`, and `--json`.
- `club upgrade` refuses Homebrew, `pub global activate`, and source-checkout installs, naming the right command instead.
- A one-line update hint after commands, checked at most daily and silenced by `NO_UPDATE_CHECK`.
- `--pre` / `-Pre` on both install scripts to include pre-releases.
- `club publish --from-git` accepts a GitHub pull request URL and publishes the PR head.
- A pull request publishes as a prerelease of its own version, so `1.2.0` from PR #2 becomes `1.2.0-pr2`.
- `--from-git <pr-url> --auto` suffixes a whole monorepo stack and points the rewritten internal constraints at the prereleases.
- `--from-git` asks which version to publish as, pre-filled with the detected one, skipped by `--version`, `--force`, and CI.
- A version entered at that step is used verbatim, so a PR can be published as any version rather than the derived prerelease.
- `club publish --auto` publishes mutually dependent packages as a group instead of failing on the cycle.
- Cycle members are listed before the confirmation prompt and badged `⟳ cycle` in the publish stack.
- Cycle members get their standalone resolution and `dart analyze` verified after the whole group is published.
- A failed post-publish verification exits 65 and states that the versions are already on the server.
- `scripts/uninstall.ps1` uninstalls on Windows, covering `club.exe`, the `club.cmd` shim, self-upgrade leftovers, the bundle directory, `%APPDATA%\club`, and the user PATH entry.
- The site serves `/uninstall.ps1`, so Windows uninstall is a one-liner, and lists it on the privacy page.

### Changed

- `--version` is now allowed with `--auto` and applies to every package in the closure, including the rewritten internal constraints.
- `--version` is validated as semver before any cloning or resolution work happens.
- The install one-liner now installs the newest stable release instead of the newest tag. Pass `--pre` for the old behaviour.
- `install.sh` reports "Downgrading" when moving to an older version.
- `uninstall.sh --purge` unregisters the pub token for every server in `credentials.json`, which previously survived uninstall in dart's own config.

### Fixed

- A dependency cycle no longer aborts `club publish --auto` with "Break the cycle by replacing one of the path dependencies".
- A package that depends on itself now reports that directly instead of surfacing as a cycle.
- The CHANGELOG validator accepts the version declared in the pubspec, so a derived version from `--version` or a pull request no longer warns.
- `install.ps1` can now replace a running `club.exe` instead of failing with a sharing violation.

## 0.4.1

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
