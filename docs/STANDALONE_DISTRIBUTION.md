# club — Standalone Server Distribution

Plan for distributing `club-server` as a native CLI tool (Homebrew, `curl | install.sh`, Chocolatey, PowerShell) without requiring Docker. This is a design document for future implementation — **not yet implemented**.

Last updated: 2026-04-17

---

## 1. Motivation

Today the server ships only as a Docker image (`ghcr.io/.../club`). That works for production operators but excludes:

- Developers who want to run a local private pub server without Docker.
- Small teams running on bare-metal Linux/macOS/Windows servers.
- Users who prefer `brew install` / `curl | sh` ergonomics.

The `club` CLI already ships as native binaries via [.github/workflows/build-cli.yml](../.github/workflows/build-cli.yml), but is distributed through pub.dev as the canonical channel. This document is specifically about the **server** binary.

Scope: only the server. The CLI continues to be distributed via pub.dev.

---

## 2. Decisions already made

These are fixed — future implementation should not re-debate.

| Decision | Value |
|---|---|
| Single file required? | No. Multi-file install is acceptable. |
| User experience | `club-server <command>` CLI tool |
| Platforms | macOS (arm64, x64), Linux (arm64, x64), Windows (x64) |
| Channels | Homebrew + `curl \| install.sh` (macOS/Linux); Chocolatey + PowerShell script (Windows) |
| Pana scoring | Keep optional but supported (downloads Dart SDK at runtime) |
| Data layout | XDG-free, `~/.club/` on Unix, `%USERPROFILE%\.club\` on Windows |
| Service units | Required: systemd (Linux), launchd (macOS), Windows Service |
| Self-update | No. Delegate to `brew upgrade` / re-running install script |
| Starter config | Installer generates `config.yaml` with random `JWT_SECRET` |
| Frontend embedding | Zip appended to binary with trailer offset |
| Release workflow | Same `v*` tag as CLI; separate workflow file |

---

## 3. Current state (verified baseline)

### Build pipeline
- [docker/Dockerfile](../docker/Dockerfile) is the only complete build today.
  - Stage 1 runs `dart build cli -t packages/club_server/bin/server.dart -o /app/build/server`, producing `bundle/bin/server` + `bundle/lib/libsqlite3.*`.
  - Stage 1 also copies SPDX license data from the pub-cache next to the binary (Dockerfile:42-44).
  - Stage 2 runs `npm ci && npm run build` in [packages/club_web](../packages/club_web).
  - Stage 3 (`debian:bookworm-slim`) composes stages and installs `ca-certificates curl git unzip webp`.

### Native dependencies
- [packages/club_db/pubspec.yaml](../packages/club_db/pubspec.yaml) depends on `sqlite3: ^3.3.0`, which emits `libsqlite3.{so,dylib}` as a native asset in `bundle/lib/` on Unix. Windows links statically.
- FTS5 is **mandatory** — migrations in [packages/club_db/lib/src/sql/schema.dart](../packages/club_db/lib/src/sql/schema.dart) create `CREATE VIRTUAL TABLE USING fts5`. The default `sqlite3` package build hook enables FTS5.
- All other server deps are pure Dart (`bcrypt`, `shelf`, `archive`, `tar`, `markdown`, `yaml`, `image`, `dart_jsonwebtoken`, etc.).
- Pana (`^0.23.0`) is an optional heavyweight: it subprocesses `dart`, `dartdoc`, and `cwebp`/`dwebp`/`webpinfo`/`gif2webp`/`webpmux`. Only needed when scoring is enabled.

### Runtime paths
- `sdkBaseDir` defaults to `/data/cache/sdks`, overridable via `SDK_BASE_DIR`.
- `pubCacheDir` defaults to `/data/cache/pub-cache` (hardcoded in bootstrap; make configurable before a standalone release).
- Scoring log path derives from `LOGS_DIR` (default `/data/logs/scoring.log`).
- SPDX dir resolved relative to `Platform.resolvedExecutable` (already portable).

### Configuration
- [packages/club_server/lib/src/config/app_config.dart](../packages/club_server/lib/src/config/app_config.dart) reads env vars or YAML file at `/etc/club/config.yaml` (overridable via `CONFIG` env var).
- `_resolveStaticFilesPath` (line 238) auto-detects `/app/static/web` (Docker) then `packages/club_web/build` (local dev).
- Env keys canonicalized in [packages/club_server/lib/src/config/env_keys.dart](../packages/club_server/lib/src/config/env_keys.dart). Required: `JWT_SECRET` (32+ chars). Defaults target Docker layout.

### Existing release infrastructure to mirror
- [.github/workflows/build-cli.yml](../.github/workflows/build-cli.yml) — matrix of 5 platforms, `dart build cli`, SHA256SUMS, GitHub Release attachment.
- [scripts/build-cli.sh](../scripts/build-cli.sh) — version-burning pattern.
- [.github/workflows/build-docker.yml](../.github/workflows/build-docker.yml) — multi-arch Docker to GHCR; will continue to run in parallel to the new standalone workflow.

---

## 4. Artifact shape

### Archive layout
Archive name follows CLI convention: `club-server-v<version>-<os>-<arch>.<ext>`.
- Unix: `.tar.gz`
- Windows: `.zip`

Contents:
```
club-server-v1.2.3-darwin-arm64/
  bin/
    club-server                # Dart AOT binary with SvelteKit build appended as zip trailer
  lib/
    libsqlite3.dylib           # rpath-relative FFI sidecar (Unix only; Windows links static)
  share/
    spdx-licenses/             # pana license data (copied from pub-cache at build time)
  LICENSE
  README.txt
```

### Install destination
- Unix: `~/.club/install/v<version>/` with `current` symlink → `~/.club/install/current/`
- Shim at `/usr/local/bin/club-server` (fallback `~/.local/bin/club-server`) execs into `current/bin/club-server`
- Windows: `%USERPROFILE%\.club\install\v<version>\` with `current` junction; PATH includes `current\bin`

---

## 5. Runtime architecture

### 5.1 CLI surface (new `CommandRunner` on server binary)

The binary currently takes zero args and just serves. Wrap it in `package:args` `CommandRunner`:

```
club-server                          # alias for 'serve' (preserves Docker zero-arg behavior)
club-server serve                    # explicit
club-server init                     # write ~/.club/config.yaml (random JWT_SECRET) + create dirs
club-server service install          # write + register unit file
club-server service uninstall
club-server service start|stop|status
club-server config show              # print resolved config (redact secrets)
club-server config path              # print config file path
club-server version                  # print version
```

Default behavior when `args.isEmpty || args.first == 'serve'` → existing `main()` logic. This keeps `ENTRYPOINT ["/app/bin/server"]` in [docker/Dockerfile:91](../docker/Dockerfile#L91) working unchanged.

### 5.2 Unified `DATA_DIR` convention

Add `DATA_DIR` env var. Resolution priority per derived path:

```
individual env var  >  yaml key  >  $DATA_DIR/<relative>  >  built-in default
```

Detection is transparent (no "am I in Docker" heuristic): Docker's Dockerfile gains `ENV DATA_DIR=/data`, user-install defaults to `~/.club` via a `PathResolver._userDataDir()` that reads `$HOME`/`$USERPROFILE`.

Derived paths:

| Purpose | Under `$DATA_DIR` | Env override (existing) |
|---|---|---|
| SQLite DB | `db/club.db` | `SQLITE_PATH` |
| Blob storage (tarballs + screenshots + blob-mode dartdoc) | `blobs/` | `BLOB_PATH` |
| Filesystem-mode dartdoc | `cache/dartdoc/` | `DARTDOC_PATH` |
| SDK downloads | `cache/sdks/` | `SDK_BASE_DIR` |
| Pub cache (pana) | `cache/pub-cache/` | *(new)* `PUB_CACHE_DIR` |
| Logs | `logs/` | `LOGS_DIR` |
| Temp uploads | `tmp/uploads/` | `TEMP_DIR` |

`PUB_CACHE_DIR` is the only remaining hardcoded path in [bootstrap.dart](../packages/club_server/lib/src/bootstrap.dart); replace it with `config.pubCacheDir` before shipping standalone.

Config file lookup order: `CONFIG` env var → `$DATA_DIR/config.yaml` → `/etc/club/config.yaml`.

### 5.3 Frontend embedding via appended-zip trailer

**Trailer format (24 bytes at EOF):**
```
[ magic "CLUBSTAT" 8 bytes ]
[ zip_offset uint64 little-endian 8 bytes ]
[ zip_length uint64 little-endian 8 bytes ]
```

Read by seeking to `fileSize - 24` and validating the magic.

**Build-time tool** — new file `packages/club_server/tool/embed_static.dart`:
1. Accept `--binary <path>` and `--web-dir <path>` args.
2. Zip the SvelteKit `build/` directory using `archive` `ZipEncoder`. Preserve `.gz` precompressed variants (adapter-static already produces them with `precompress: true` — see [packages/club_web/svelte.config.js](../packages/club_web/svelte.config.js)).
3. Append zip bytes + trailer to the binary in place.

**Runtime loader** — new file `packages/club_server/lib/src/assets/embedded_assets.dart`:
- `EmbeddedAssetBundle.load()` opens `Platform.resolvedExecutable` as `RandomAccessFile`, seeks to trailer, validates magic, reads zip bytes into memory, decodes with `ZipDecoder`.
- Returns `null` if magic absent → dev-mode falls back to existing `STATIC_FILES_PATH` auto-detect.
- Precompute SHA-256 ETags per file, store in parallel map.

**In-memory handler** — new file `packages/club_server/lib/src/assets/embedded_handler.dart`:
- Replaces `createStaticHandler(...)` call in [packages/club_server/lib/src/router.dart:204-234](../packages/club_server/lib/src/router.dart#L204-L234).
- Behavior:
  1. Normalize request path (strip leading `/`, empty → `index.html`).
  2. Honor `If-None-Match` → 304.
  3. If `Accept-Encoding: gzip` and `$path.gz` exists in bundle → serve gzipped with `Content-Encoding: gzip`.
  4. Otherwise serve `$path` with `Content-Type` from `package:mime` `lookupMimeType`.
  5. Path not found and doesn't start with `_app/` → serve `index.html` (SPA fallback).
  6. Path not found and starts with `_app/` → 404.

`buildHandler` becomes `async` (or bundle is loaded in `bootstrap()` and passed in). Cascade propagates to callers.

### 5.4 First-run config

`club-server init`:
1. Resolve config path: `CONFIG` env → `$DATA_DIR/config.yaml`.
2. If file exists and `--force` absent → print path and exit 0.
3. Create directory, write starter YAML with:
   - `jwt_secret`: 32 random bytes hex-encoded via `dart:math` `Random.secure()`.
   - `data_dir`: expanded `~/.club` path.
   - `listen_port: 8080`.
   - All other keys commented with defaults shown, mirroring [docker/.env.example](../docker/.env.example) structure.

Auto-run on first `serve` if `jwt_secret` missing — makes naive `brew install && club-server` work without mandatory init step.

### 5.5 Service management (**OPEN — decision deferred**)

Two approaches. Option A is recommended but not committed.

**Option A — Binary owns service management (recommended).** New module `packages/club_server/lib/src/service/`:
- `service_manager.dart` — abstract `ServiceManager` interface (`install`, `uninstall`, `start`, `stop`, `status`) + `forPlatform()` factory.
- `systemd_service_manager.dart` — writes `~/.config/systemd/user/club-server.service` (user mode, no root). With `--system` flag writes to `/etc/systemd/system/` via sudo.
- `launchd_service_manager.dart` — writes `~/Library/LaunchAgents/dev.club.server.plist` (user agent), calls `launchctl load`.
- `windows_service_manager.dart` — uses `New-Service` or `sc.exe create`. Checks elevation via `whoami /groups`.

Unit files embed `ExecStart=<Platform.resolvedExecutable>`, `EnvironmentFile=<resolved config path>`, `Restart=on-failure`, `RestartSec=5s`. Signal handling in [packages/club_server/bin/server.dart](../packages/club_server/bin/server.dart) already handles SIGTERM/SIGINT cleanly.

**Option B — Installer scripts own service management.** Each installer (`install.sh`, `install.ps1`, Homebrew `service do` block, Chocolatey `chocolateyInstall.ps1`) embeds its own unit file template. Simpler Dart side, but 4-way duplication and binary upgrades can't update unit format.

**Recommendation: Option A.** Critical status + four distribution channels justify the extra Dart code.

### 5.6 Dev experience (must still work)

When running `dart run packages/club_server/bin/server.dart`:
- `EmbeddedAssetBundle.load()` returns `null` (JIT snapshot has no trailer) → filesystem fallback finds `packages/club_web/build`.
- `DATA_DIR` unset → resolver uses `~/.club` default, but existing per-path env var overrides from the CLAUDE.md dev invocation still win (e.g. `SQLITE_PATH=/tmp/club-dev.db`).
- `JWT_SECRET` set via shell export → no auto-generation fires.

---

## 6. Module layout

### New files

**Runtime:**
- `packages/club_server/lib/src/assets/embedded_assets.dart` — trailer parser, in-memory zip loader
- `packages/club_server/lib/src/assets/embedded_handler.dart` — shelf handler over embedded bundle
- `packages/club_server/lib/src/config/path_resolver.dart` — `DATA_DIR` + derived path helpers
- `packages/club_server/lib/src/commands/serve_command.dart` — existing `main()` body as `Command`
- `packages/club_server/lib/src/commands/init_command.dart` — config + data dir generation
- `packages/club_server/lib/src/commands/config_command.dart` — `show` / `path` subcommands
- `packages/club_server/lib/src/commands/service_command.dart` — delegates to `ServiceManager.forPlatform()`
- `packages/club_server/lib/src/commands/version_command.dart` — prints version from generated stamp
- `packages/club_server/lib/src/service/service_manager.dart` — interface + factory
- `packages/club_server/lib/src/service/systemd_service_manager.dart`
- `packages/club_server/lib/src/service/launchd_service_manager.dart`
- `packages/club_server/lib/src/service/windows_service_manager.dart`

**Build tooling:**
- `packages/club_server/tool/embed_static.dart` — zip + append to binary

**Release pipeline:**
- `.github/workflows/build-server.yml` — matrix build, package, release, publish
- `scripts/build-server.sh` — local equivalent of the CI build

**Packaging templates:**
- `packaging/server/formula.rb.tmpl` — Homebrew formula template
- `packaging/server/club-server.nuspec.tmpl` — Chocolatey nuspec template
- `packaging/server/chocolateyInstall.ps1.tmpl` — Chocolatey install script
- `packaging/server/chocolateyUninstall.ps1` — static Chocolatey uninstall script

**Install scripts (hosted publicly):**
- `sites/docs/public/install.sh` — `curl | sh` installer for macOS + Linux
- `sites/docs/public/install.ps1` — PowerShell installer for Windows

### Modified files

- `packages/club_server/bin/server.dart` — wrap in `CommandRunner`, default to `serve`
- `packages/club_server/lib/src/config/app_config.dart` — add `dataDir`, `sdkDir`, `pubCacheDir` fields; config search order
- `packages/club_server/lib/src/config/env_keys.dart` — add `DATA_DIR`, `SDK_DIR`, `PUB_CACHE_DIR`
- `packages/club_server/lib/src/bootstrap.dart` — replace hardcoded `/data/cache/sdks`, `/data/cache/pub-cache`
- `packages/club_server/lib/src/router.dart` — swap `shelf_static` call for embedded handler with filesystem fallback
- `docker/.env.example` — add `DATA_DIR=/data` commented line
- `docker/Dockerfile` — add `ENV DATA_DIR=/data`; invoke `embed_static.dart` after `dart build cli`

---

## 7. Release pipeline

### Workflow: `.github/workflows/build-server.yml`

Triggered on `v*` tags in parallel with `build-cli.yml` and `build-docker.yml`.

**Matrix:** `{os, arch}`:
- `ubuntu-latest` / x64, arm64
- `macos-13` (x64), `macos-14` (arm64)
- `windows-latest` / x64

**Per-runner steps:**
1. Checkout; resolve version from tag.
2. Burn version into generated `packages/club_server/lib/src/version.dart`.
3. `dart pub get`.
4. `dart build cli -t packages/club_server/bin/server.dart -o build/server`.
5. `cd packages/club_web && npm ci && npm run build`.
6. Run `dart run packages/club_server/tool/embed_static.dart --binary build/server/bundle/bin/server --web-dir packages/club_web/build`.
7. Copy `libsqlite3.*` + SPDX license data into the staging tree.
8. Pack `.tar.gz` (Unix) or `.zip` (Windows). Output `club-server-<version>-<os>-<arch>.<ext>`.
9. Upload as artifact.

**Release job:**
- Downloads all 5 artifacts.
- Generates `SERVER-SHA256SUMS.txt`.
- Uploads to the **same GitHub Release** as the CLI (different filenames prevent collision).

**Publish jobs (run after release):**
- `update-homebrew` — checks out `homebrew-club` tap repo with deploy key, renders `Formula/club-server.rb` from template substituting version + SHA values, commits and pushes.
- `publish-chocolatey` — on `windows-latest`: `choco pack` + `choco push` with `CHOCOLATEY_API_KEY` secret.
- Install scripts at `docs.club.dev/install.{sh,ps1}` are static files already deployed by the docs site; they use the GitHub API to discover the latest version at runtime.

### User-facing install flows

**Homebrew** (macOS + Linux):
```
brew install BirjuVachhani/club/club-server   # tap name TBD
```
Formula installs binary to `libexec/bin`, sidecars to `libexec/lib`, generates thin wrapper at `bin/club-server`. Service registration via `brew services start club-server` (uses formula's `service do` block) OR `club-server service install` (if Option A chosen).

**curl install.sh** (macOS + Linux):
```
curl -fsSL https://docs.club.dev/install.sh | sh
```
Detects OS/arch via `uname`, downloads archive, verifies SHA256, extracts to `~/.club/install/v<ver>/`, updates `current` symlink, creates shim in `/usr/local/bin` (fallback `$HOME/.local/bin`), runs `club-server init`, optionally `club-server service install`.

**Chocolatey** (Windows):
```
choco install club-server
```

**install.ps1** (Windows):
```
iwr -useb https://docs.club.dev/install.ps1 | iex
```

### Build sequence on tag push

1. `git tag v1.2.3 && git push --tags`.
2. Three workflows trigger in parallel: `build-cli.yml`, `build-docker.yml`, `build-server.yml`.
3. `build-server` matrix runs on 5 runners.
4. All three release jobs attach to the same GitHub Release.
5. `update-homebrew` job pushes formula update to the tap repo.
6. `publish-chocolatey` pushes to Chocolatey community feed (moderation queue).
7. Users run `brew upgrade` / re-run `install.sh` / `choco upgrade` to update.

---

## 8. Open questions (to confirm before implementing)

1. **Service management: Option A (binary-owned) or Option B (installer-owned)?** Recommendation: A.

2. **Windows Service account.** Windows services cannot read `%USERPROFILE%\.club\`. Proposal: on Windows, `club-server service install` uses `C:\ProgramData\club\` as `DATA_DIR` and runs as `LocalSystem`. User-level `club-server serve` (no service) keeps `%USERPROFILE%\.club\`.

3. **Linux systemd scope.** Default to `--user` (no root, `~/.config/systemd/user/`), with `--system` flag for root/production installs.

4. **Homebrew tap name.** Plan is `github.com/BirjuVachhani/homebrew-club` → `brew install BirjuVachhani/club/club-server`. Confirm tap repo name.

5. **install.sh hosting URL.** Plan: `https://docs.club.dev/install.sh` via the Astro docs site. Requires `docs.club.dev` domain to be configured. Fallback to GitHub raw URL until it is.

6. **Chocolatey API key.** Needs a Chocolatey community account. Could be deferred — ship install.ps1 first, add Chocolatey later.

7. **Scoring on user installs.** Pana downloads Dart SDK (~200 MB) to `$DATA_DIR/sdks/` on first scoring enablement. Accept as-is, or add installer-level opt-in prompt?

---

## 9. Risks and notes

- **Binary size.** Dart AOT (~10-12 MB) + `libsqlite3` (~1 MB) + SPDX (~500 KB) + embedded frontend (~1-3 MB typical; up to 20 MB if Fira Code font set not trimmed) ≈ 12-35 MB. Acceptable for Homebrew; on the heavy side for `curl | sh`. Frontend font trimming is a separate optimization opportunity.
- **`buildHandler` async cascade.** Making the static file loader async propagates to `bootstrap()`. Minor but touches every caller.
- **Windows Service + DATA_DIR.** The split between user-level (`%USERPROFILE%`) and service-level (`C:\ProgramData`) needs clean handling so that `club-server serve` and the service point at the same data.
- **Tap repo deploy key.** CI needs write access to `homebrew-club` via a deploy key stored as a repo secret. One-time setup.
- **SPDX staleness.** The SPDX license data is copied from the pub-cache at build time. It's frozen at the pana version resolved during CI. Updating requires re-running the release.
- **Chocolatey moderation lag.** Community feed publishes go through a review queue (can be hours-days). Enterprise users may prefer the PowerShell install script.
- **Static SQLite aspiration.** A future improvement: replace the dynamic-lib `sqlite3` build hook with a statically-linked variant, eliminating `libsqlite3.{so,dylib}` sidecar and getting closer to true single-file. Requires upstream work or a custom `hook/build.dart` in `club_db`.

---

## 10. Incremental shipping plan

If full rollout is too much in one go, ship in order:

1. **Runtime code changes only.** `DATA_DIR` convention, `CommandRunner`, `init` command, embedded frontend trailer. Docker continues to work; no new distribution yet.
2. **`build-server.yml` workflow.** Produces native archives on GitHub Releases with no installer yet.
3. **`install.sh` + systemd.** Most common server target. Validates the flow end-to-end.
4. **Homebrew tap.** Macs and Linuxbrew.
5. **Service management via binary** (`club-server service install`) — if Option A.
6. **Windows: install.ps1 + Windows Service.**
7. **Chocolatey.** Last, because of moderation queue and account setup overhead.

Each step is a small, reviewable PR.
