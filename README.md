# club

A self-hosted, private Dart package repository. Drop-in replacement for [pub.dev](https://pub.dev) for teams and organizations that need private package hosting.

## Features

- **Full pub spec v2 compatibility** — works with `dart pub get`, `dart pub publish`, `dart pub add`
- **Private by default** — all access requires authentication
- **Looks like pub.dev** — SvelteKit frontend matching pub.dev's design
- **Docker-ready** — single container, zero external dependencies
- **Pluggable storage** — SQLite/PostgreSQL for metadata, filesystem/S3 for packages
- **Full-text search** — SQLite FTS5 with prefix matching
- **Publishers** — organizations with admin/member roles
- **API tokens** — named tokens with scopes for CI/CD
- **CLI tool** — `club` command for login, setup, publish, admin
- **Client SDK** — `club_api` Dart package for programmatic access

## Quick Start

### Docker (Recommended)

```bash
# 1. Clone
git clone https://github.com/BirjuVachhani/club.git
cd club/docker

# 2. Configure
cp .env.example .env
# Edit .env — set JWT_SECRET and SERVER_URL

# 3. Start
docker compose up -d

# 4. Verify
curl http://localhost:8080/api/v1/health
```

### From Source

```bash
# Install deps
dart pub get

# Generate code
cd packages/club_core && dart run build_runner build --delete-conflicting-outputs && cd ../..

# Build frontend
cd packages/club_web && npm install && npm run build && cd ../..

# Build server binary (optional — can also use dart run)
dart build cli -t packages/club_server/bin/server.dart -o build/server

# Start server
SERVER_URL=http://localhost:8080 \
JWT_SECRET=$(openssl rand -hex 32) \
ADMIN_EMAIL=admin@localhost \
ADMIN_PASSWORD=admin \
SQLITE_PATH=/tmp/club.db \
BLOB_PATH=/tmp/club-packages \
dart run packages/club_server/bin/server.dart
```

## Using club

### 1. Install the CLI

One-line install on Linux or macOS:

```bash
curl -fsSL https://club.birju.dev/install.sh | bash
```

The script detects your OS and CPU, pulls the matching archive from the latest [GitHub release](https://github.com/BirjuVachhani/club/releases), verifies its SHA-256, and installs `club` to `~/.local/bin`.

Pin a specific version, change the install dir, or install on Windows — see [scripts/install.sh](scripts/install.sh) and the [CLI installation guide](docs/CLI.md) for the full set of options.

Verify:

```bash
club --version
```

To uninstall later:

```bash
curl -fsSL https://club.birju.dev/uninstall.sh | bash
```

Pass `--purge` to also remove stored credentials under `~/.config/club`. See the [uninstall section of the CLI guide](sites/docs/src/content/docs/cli/installation.mdx) for all options.

### 2. Login

```bash
# CLI — opens a browser for OAuth (PKCE)
club login https://club.example.com

# Or configure dart pub directly
dart pub token add https://club.example.com
```

### 3. Add packages to your project

```yaml
# pubspec.yaml
dependencies:
  my_private_package:
    hosted: https://club.example.com
    version: ^1.0.0
```

```bash
dart pub get
```

### 4. Publish a package

```yaml
# In your package's pubspec.yaml
publish_to: https://club.example.com
```

```bash
dart pub publish
# Or use the CLI:
club publish
```

### 5. CI/CD Integration

```yaml
# GitHub Actions
- name: Configure club
  run: dart pub token add https://club.example.com --env-var CLUB_TOKEN
  env:
    CLUB_TOKEN: ${{ secrets.CLUB_TOKEN }}
```

## Architecture

```
club/
├── packages/
│   ├── club_core/       # Domain models, interfaces, services
│   ├── club_db/         # SQLite storage implementation
│   ├── club_storage/    # Blob storage (filesystem/S3)
│   ├── club_server/     # API server + static file serving
│   ├── club_web/        # SvelteKit frontend (static export)
│   ├── club_api/        # Client SDK for programmatic access
│   └── club_cli/        # CLI tool
├── docker/               # Docker setup + reverse proxy configs
├── config/               # Example configuration files
└── docs/                 # Full documentation
```

## Documentation

| Document | Description |
|----------|-------------|
| [FEATURES.md](docs/FEATURES.md) | Complete feature list |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture |
| [API.md](docs/API.md) | Full API reference |
| [DATABASE.md](docs/DATABASE.md) | Database schema |
| [FRONTEND.md](docs/FRONTEND.md) | SvelteKit frontend docs |
| [CLIENT_SDK.md](docs/CLIENT_SDK.md) | Client SDK (club_api) |
| [CLI.md](docs/CLI.md) | CLI tool documentation |
| [DOCKER.md](docs/DOCKER.md) | Docker deployment guide |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | All config options |
| [DEVELOPMENT.md](docs/DEVELOPMENT.md) | Dev workflow + testing |
| [BUILD_PLAN.md](docs/BUILD_PLAN.md) | Implementation roadmap |
| [SELF_HOSTING.md](docs/SELF_HOSTING.md) | Self-hosting guide |

## Configuration

All configuration via environment variables. Key settings:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SERVER_URL` | Yes | — | Public URL of the server |
| `JWT_SECRET` | Yes | — | 32+ char secret for JWT signing |
| `PORT` | No | `8080` | HTTP listen port |
| `DB_BACKEND` | No | `sqlite` | `sqlite` or `postgres` |
| `BLOB_BACKEND` | No | `filesystem` | `filesystem` or `s3` |
| `ADMIN_EMAIL` | No | — | Bootstrap admin on first run |

See [CONFIGURATION.md](docs/CONFIGURATION.md) for the full reference.

## Storage Backends

| Layer | Default | Alternative |
|-------|---------|-------------|
| Metadata | SQLite | PostgreSQL |
| Packages | Filesystem | S3-compatible |
| Search | SQLite FTS5 | Meilisearch |

Switch backends by changing one environment variable. See [DOCKER.md](docs/DOCKER.md).

## Security

- All access requires authentication (no anonymous endpoints except health check)
- Passwords hashed with bcrypt (cost=12)
- API tokens stored as SHA-256 hashes (raw shown once at creation)
- Session JWTs signed with HMAC-SHA256
- HTML sanitization on all rendered Markdown
- Upload streaming (never buffered in memory)

## License

Apache License 2.0 — see [LICENSE](LICENSE).

The "club" name and branding are not part of the license grant. Forks
and derivatives must use a different name.
