# club — Docker Deployment Guide

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/BirjuVachhani/club.git
cd club

# 2. Create environment file
cp docker/.env.example docker/.env
# Edit docker/.env — set JWT_SECRET and SERVER_URL

# 3. Start club
cd docker
docker compose up -d

# 4. Check health
curl http://localhost:8080/api/v1/health
```

club is now running at `http://localhost:8080`.

---

## Docker Image

### Building

```bash
# Build from the repository root
docker build -f docker/Dockerfile -t club:latest .
```

### Image Details

- **Base (build stage):** `dart:3.7-sdk` — full Dart SDK for building
- **Base (runtime):** `debian:bookworm-slim` — minimal Linux (~80MB total)
- **Binary:** Native executable built with `dart build cli` (no Dart SDK in runtime image)
- **User:** `club:1000` (non-root)
- **Port:** 8080
- **Data volume:** `/data` (SQLite database + package tarballs)

### Dockerfile

Three-stage build: Dart server + SvelteKit frontend + minimal runtime.

```dockerfile
# Stage 1: Build Dart server
FROM dart:3.7-sdk AS dart-builder
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
COPY packages/ packages/
RUN dart pub get --no-example
RUN dart build cli -t packages/club_server/bin/server.dart -o /app/build/server

# Stage 2: Build SvelteKit frontend
FROM node:22-alpine AS web-builder
WORKDIR /web
COPY packages/club_web/package.json packages/club_web/package-lock.json ./
RUN npm ci
COPY packages/club_web/ .
RUN npm run build
# Output: /web/build/ (static HTML/JS/CSS via adapter-static)

# Stage 3: Runtime
FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates sqlite3 curl && \
    rm -rf /var/lib/apt/lists/*
RUN groupadd -r club -g 1000 && \
    useradd --no-log-init -r -m -g club -u 1000 club
RUN mkdir -p /data/blobs && chown -R club:club /data
COPY --from=dart-builder /app/build/server/bundle/ /app/
COPY --from=web-builder /web/build /app/static/web
COPY config/config.example.yaml /etc/club/config.example.yaml
RUN chmod +x /app/bin/server
USER club:1000
VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:8080/api/v1/health || exit 1
ENTRYPOINT ["/app/bin/server"]
```

**Key points:**
- Stage 1 builds the Dart server binary via `dart build cli` (no Dart SDK in runtime image)
- Stage 2 builds the SvelteKit static export (no Node.js in runtime image)
- Stage 3 is a minimal Debian image (~80MB) with just the binary + static files
- The Dart server serves `/app/static/web/` for all non-API routes

---

## docker-compose

### Default Stack (SQLite + Filesystem)

`docker/docker-compose.yml`:

```yaml
version: "3.9"

services:
  club:
    image: club:latest
    build:
      context: ..
      dockerfile: docker/Dockerfile
    container_name: club
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    env_file: .env
    volumes:
      - club_data:/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/v1/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  club_data:
    driver: local
```

### With PostgreSQL

`docker/docker-compose.postgres.yml` (override file):

```yaml
version: "3.9"

services:
  postgres:
    image: postgres:16-alpine
    container_name: club_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: club
      POSTGRES_USER: club
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env}
    volumes:
      - club_postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U club"]
      interval: 10s
      timeout: 3s
      retries: 5

  club:
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DB_BACKEND: postgres
      POSTGRES_URL: "postgres://club:${POSTGRES_PASSWORD}@postgres:5432/club"

volumes:
  club_postgres:
```

**Usage:**
```bash
docker compose -f docker-compose.yml -f docker-compose.postgres.yml up -d
```

---

## Environment Variables

### Required

| Variable | Description | Example |
|----------|-------------|---------|
| `SERVER_URL` | Public URL of your club server | `https://packages.example.com` |
| `JWT_SECRET` | Secret for JWT signing (min 32 chars) | `openssl rand -hex 32` |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8080` | Listen port |
| `DB_BACKEND` | `sqlite` | `sqlite` or `postgres` |
| `SQLITE_PATH` | `/data/db/club.db` | SQLite database file path |
| `POSTGRES_URL` | — | PostgreSQL connection URL |
| `BLOB_BACKEND` | `filesystem` | `filesystem` or `s3` |
| `BLOB_PATH` | `/data/blobs` | Filesystem blob storage path |
| `S3_ENDPOINT` | — | S3 endpoint URL (for MinIO) |
| `S3_BUCKET` | — | S3 bucket name |
| `S3_REGION` | — | S3 region |
| `S3_ACCESS_KEY` | — | S3 access key |
| `S3_SECRET_KEY` | — | S3 secret key |
| `SEARCH_BACKEND` | `sqlite` | `sqlite` or `meilisearch` |
| `MEILISEARCH_URL` | — | Meilisearch URL |
| `MEILISEARCH_KEY` | — | Meilisearch API key |
| `TOKEN_EXPIRY_DAYS` | `365` | Default token expiry |
| `MAX_UPLOAD_BYTES` | `104857600` | Max upload size (100 MB) |
| `ADMIN_EMAIL` | — | Bootstrap admin email |
| `ADMIN_PASSWORD` | — | Bootstrap admin password |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warning`, `error` |

### Example .env File

```bash
# docker/.env

# Required
SERVER_URL=https://packages.example.com
JWT_SECRET=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2

# Bootstrap admin (only used on first startup when no users exist)
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=change-me-immediately

# Optional: PostgreSQL (uncomment to use)
# DB_BACKEND=postgres
# POSTGRES_PASSWORD=super-secret-password
```

---

## Reverse Proxy Setup

club should be run behind a reverse proxy for TLS termination.
The server binds to `127.0.0.1:8080` to avoid direct exposure.

### Caddy (Recommended)

Caddy provides automatic TLS via Let's Encrypt with zero configuration.

Example `Caddyfile`:

```caddyfile
packages.example.com {
    tls {
        protocols tls1.2 tls1.3
    }

    request_body {
        max_size 100MB
    }

    reverse_proxy club:8080 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Real-IP {remote_host}
    }
}
```

**Add Caddy to docker-compose:**

```yaml
services:
  caddy:
    image: caddy:2-alpine
    container_name: club_caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
```

### nginx

Example nginx site config (e.g. `/etc/nginx/sites-available/club`):

```nginx
upstream club {
    server 127.0.0.1:8080;
    keepalive 32;
}

server {
    listen 80;
    server_name packages.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name packages.example.com;

    ssl_certificate     /etc/letsencrypt/live/packages.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/packages.example.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 100m;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    location / {
        proxy_pass         http://club;
        proxy_http_version 1.1;
        proxy_set_header   Connection "";
        proxy_read_timeout 120s;
    }
}
```

---

## Data Persistence

### Volume Layout

```
/data/                      ← Docker named volume: club_data
├── club.db                ← SQLite database (when using sqlite backend)
└── packages/               ← Package tarballs (when using filesystem backend)
    ├── my_package/
    │   ├── 1.0.0.tar.gz
    │   └── 2.0.0.tar.gz
    └── other_package/
        └── 0.1.0.tar.gz
```

### Backup

A first-class backup feature is planned for a future release. In the
meantime, `/data` is the single source of truth — back it up as a whole
and the server will pick it up on a fresh container.

**Manual snapshot:**

```bash
# SQLite: safe online backup (no downtime)
docker exec club sqlite3 /data/db/club.db ".backup /tmp/backup.db"
docker cp club:/tmp/backup.db ./club-backup.db

# Package tarballs
docker cp club:/data/blobs ./packages-backup/

# Or snapshot the entire volume
docker run --rm -v club_data:/data -v $(pwd):/backup \
  alpine tar czf /backup/club-data-$(date +%Y%m%d).tar.gz -C /data .
```

### Restore

```bash
# Stop server
docker compose stop club

# Restore database
docker cp club-backup.db club:/data/db/club.db

# Restore packages
docker cp packages-backup/. club:/data/blobs/

# Start server
docker compose start club
```

---

## Upgrading

### Standard Upgrade

```bash
cd club/docker

# Pull latest code
git pull

# Rebuild image
docker compose build

# Restart (migrations run automatically on startup)
docker compose up -d
```

### With Breaking Changes

```bash
# 1. Snapshot /data first (see Backup section above)

# 2. Stop, rebuild, start
docker compose down
docker compose build
docker compose up -d

# 3. Check health
curl http://localhost:8080/api/v1/health

# 4. Check logs for migration output
docker compose logs club
```

---

## Production Checklist

- [ ] Set a strong `JWT_SECRET` (use `openssl rand -hex 32`)
- [ ] Set `SERVER_URL` to your public HTTPS URL
- [ ] Set up a reverse proxy with TLS (Caddy recommended)
- [ ] Configure the bootstrap admin account (`ADMIN_EMAIL`)
- [ ] Change the admin password after first login
- [ ] Set up automated backups (daily cron recommended)
- [ ] Monitor the health endpoint (`/api/v1/health`)
- [ ] Set up log aggregation (`docker compose logs -f club`)
- [ ] Bind port 8080 to localhost only (done by default in docker-compose)
- [ ] Consider PostgreSQL for production workloads with multiple users
- [ ] Consider S3 for blob storage if packages are large or numerous
- [ ] Set resource limits in docker-compose for the club container

---

## Troubleshooting

### Server won't start

```bash
# Check logs
docker compose logs club

# Common issues:
# - JWT_SECRET not set or too short (min 32 chars)
# - SERVER_URL not set
# - Port 8080 already in use
# - /data volume permissions (must be owned by uid 1000)
```

### Can't publish packages

```bash
# Check token is registered
dart pub token list

# Re-register token
dart pub token remove https://club.example.com
club setup

# Check server logs
docker compose logs -f club
```

### Database locked errors

```bash
# This usually means another process has the SQLite file open
# Check no backup scripts are holding a lock

# If persistent, switch to PostgreSQL:
# Set DB_BACKEND=postgres in .env
```

### Out of disk space

```bash
# Check volume usage
docker system df -v

# Clean up old Docker images
docker image prune -a

# Check data volume size
docker exec club du -sh /data/
```
