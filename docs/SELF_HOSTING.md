# club — Self-Hosting Guide

Complete guide to deploying club on your own infrastructure.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Option 1: Docker (Recommended)](#option-1-docker-recommended)
- [Option 2: Docker with PostgreSQL](#option-2-docker-with-postgresql)
- [Option 3: Docker with S3 Storage](#option-3-docker-with-s3-storage)
- [Option 4: From Source](#option-4-from-source)
- [TLS / HTTPS Setup](#tls--https-setup)
- [DNS Configuration](#dns-configuration)
- [First-Time Setup](#first-time-setup)
- [Creating Users](#creating-users)
- [Client Configuration](#client-configuration)
- [CI/CD Integration](#cicd-integration)
- [Maintenance](#maintenance)
- [Upgrading](#upgrading)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

- A server or VM (Linux recommended, 1GB+ RAM, 10GB+ disk)
- Docker and Docker Compose (for Docker deployments)
- A domain name (e.g., `packages.example.com`)
- TLS certificate (auto-provisioned by Caddy, or bring your own)

---

## Option 1: Docker (Recommended)

The simplest deployment. Uses SQLite + filesystem storage. Single container, zero dependencies.

### Step 1: Create project directory

```bash
mkdir -p /opt/club && cd /opt/club
```

### Step 2: Create docker-compose.yml

```yaml
version: "3.9"

services:
  club:
    image: ghcr.io/birjuvachhani/club:latest
    # Or build locally:
    # build:
    #   context: .
    #   dockerfile: docker/Dockerfile
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
```

### Step 3: Create .env file

```bash
# Generate a secure JWT secret
JWT_SECRET=$(openssl rand -hex 32)

cat > .env << EOF
CLUB_SERVER_URL=https://packages.example.com
CLUB_JWT_SECRET=$JWT_SECRET
CLUB_ADMIN_EMAIL=admin@example.com
CLUB_ADMIN_PASSWORD=change-me-after-first-login
EOF
```

### Step 4: Start the server

```bash
docker compose up -d
```

### Step 5: Verify

```bash
curl http://localhost:8080/api/v1/health
# Should return: {"status":"ok",...}
```

The admin token will be printed in the container logs:

```bash
docker compose logs club | grep "Admin token"
```

---

## Option 2: Docker with PostgreSQL

For larger deployments or when you want a more robust database.

### docker-compose.yml

```yaml
version: "3.9"

services:
  club:
    image: ghcr.io/birjuvachhani/club:latest
    container_name: club
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      CLUB_SERVER_URL: https://packages.example.com
      CLUB_JWT_SECRET: ${CLUB_JWT_SECRET}
      CLUB_DB_BACKEND: postgres
      CLUB_POSTGRES_URL: postgres://club:${POSTGRES_PASSWORD}@postgres:5432/club
      CLUB_ADMIN_EMAIL: admin@example.com
    volumes:
      - club_packages:/data/blobs
    depends_on:
      postgres:
        condition: service_healthy

  postgres:
    image: postgres:16-alpine
    container_name: club_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: club
      POSTGRES_USER: club
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - club_postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U club"]
      interval: 10s
      timeout: 3s
      retries: 5

volumes:
  club_packages:
  club_postgres:
```

### .env

```bash
CLUB_JWT_SECRET=<output of: openssl rand -hex 32>
POSTGRES_PASSWORD=<strong-random-password>
```

---

## Option 3: Docker with S3 Storage

For deployments where packages should be stored in S3-compatible object storage (AWS S3, MinIO, DigitalOcean Spaces, etc.).

### .env additions

```bash
CLUB_BLOB_BACKEND=s3
CLUB_S3_BUCKET=club-packages
CLUB_S3_REGION=us-east-1
CLUB_S3_ACCESS_KEY=your-access-key
CLUB_S3_SECRET_KEY=your-secret-key
# For MinIO or self-hosted S3:
# CLUB_S3_ENDPOINT=http://minio:9000
```

---

## Option 4: From Source

For when you want to run club without Docker.

### Prerequisites

- Dart SDK >= 3.7
- Node.js >= 22
- SQLite3

### Build

```bash
git clone https://github.com/BirjuVachhani/club.git
cd club

# Install Dart dependencies
dart pub get

# Generate code
cd packages/club_core
dart run build_runner build --delete-conflicting-outputs
cd ../..

# Build frontend
cd packages/club_web
npm install
npm run build
cd ../..

# Compile server binary
dart build cli -t packages/club_server/bin/server.dart -o build/server
```

The binary will be at `build/server/bundle/bin/server`.

### Run

```bash
export CLUB_SERVER_URL=https://packages.example.com
export CLUB_JWT_SECRET=$(openssl rand -hex 32)
export CLUB_ADMIN_EMAIL=admin@example.com
export CLUB_ADMIN_PASSWORD=change-me
export CLUB_SQLITE_PATH=/var/lib/club/club.db
export CLUB_BLOB_PATH=/var/lib/club/packages
export CLUB_STATIC_FILES_PATH=packages/club_web/build

./build/server/bundle/bin/server
```

### Systemd Service

```ini
# /etc/systemd/system/club.service
[Unit]
Description=club Dart Package Repository
After=network.target

[Service]
Type=simple
User=club
Group=club
ExecStart=/opt/club/build/server/bundle/bin/server
EnvironmentFile=/etc/club/env
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

## TLS / HTTPS Setup

club MUST be served over HTTPS for `dart pub` to send authentication tokens. The recommended approach is a reverse proxy.

### Option A: Caddy (Recommended — Auto TLS)

Caddy automatically provisions Let's Encrypt certificates.

```bash
# Install Caddy
sudo apt install caddy

# Configure
sudo tee /etc/caddy/Caddyfile << 'EOF'
packages.example.com {
    reverse_proxy localhost:8080 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Real-IP {remote_host}
    }
    request_body {
        max_size 100MB
    }
}
EOF

sudo systemctl restart caddy
```

### Option B: nginx + Let's Encrypt

```bash
# Install nginx and certbot
sudo apt install nginx certbot python3-certbot-nginx

# Get certificate
sudo certbot --nginx -d packages.example.com

# Configure nginx
sudo tee /etc/nginx/sites-available/club << 'CONF'
server {
    listen 443 ssl http2;
    server_name packages.example.com;

    ssl_certificate /etc/letsencrypt/live/packages.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/packages.example.com/privkey.pem;

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }
}

server {
    listen 80;
    server_name packages.example.com;
    return 301 https://$host$request_uri;
}
CONF

sudo ln -s /etc/nginx/sites-available/club /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

### Option C: Docker with Caddy sidecar

Add to your docker-compose.yml:

```yaml
  caddy:
    image: caddy:2-alpine
    container_name: club_caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
```

---

## DNS Configuration

Point your domain to your server:

```
packages.example.com  A     <your-server-ip>
packages.example.com  AAAA  <your-server-ipv6>  (optional)
```

Wait for DNS propagation (usually 5-60 minutes).

---

## First-Time Setup

### 1. Get admin credentials

On first startup with `CLUB_ADMIN_EMAIL` set, club creates an admin account and prints the token:

```bash
# Docker
docker compose logs club | grep -E "Admin|token"

# From source
# The token is printed to stdout on first run
```

### 2. Login with the CLI

```bash
# Install the club CLI
dart pub global activate --source path packages/club_cli

# Login
club login https://packages.example.com
# Enter admin email and password
```

### 3. Configure dart pub

```bash
club setup
# This runs: dart pub token add https://packages.example.com
```

### 4. Verify

```bash
# Health check
curl https://packages.example.com/api/v1/health

# Open web UI
open https://packages.example.com
```

---

## Creating Users

club does not support self-registration. Admins create user accounts.

### Via CLI

```bash
club admin user-create --email jane@example.com --name "Jane Doe"
# Prompts for password
```

### Via API

```bash
curl -X POST https://packages.example.com/api/admin/users \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"email":"jane@example.com","password":"initial-pass","displayName":"Jane Doe"}'
```

### Via Web UI

Navigate to `/admin/users` and use the create user form.

---

## Client Configuration

Each developer needs to authenticate with the club server.

### For developers

```bash
# Install CLI (one-time)
dart pub global activate --source path packages/club_cli

# Login (one-time)
club login https://packages.example.com

# Configure dart pub (one-time)
club setup

# Now use packages normally
dart pub get
dart pub publish
```

### For per-project setup

In your project's `pubspec.yaml`:

```yaml
dependencies:
  my_private_package:
    hosted: https://packages.example.com
    version: ^1.0.0
```

### For PUB_HOSTED_URL (all packages from club)

```bash
export PUB_HOSTED_URL=https://packages.example.com
dart pub get
```

---

## CI/CD Integration

### GitHub Actions

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1

      - name: Configure club
        run: dart pub token add https://packages.example.com --env-var CLUB_TOKEN
        env:
          CLUB_TOKEN: ${{ secrets.CLUB_TOKEN }}

      - name: Get dependencies
        run: dart pub get

      - name: Publish (on tag)
        if: startsWith(github.ref, 'refs/tags/')
        run: dart pub publish --force
```

### GitLab CI

```yaml
build:
  image: dart:stable
  variables:
    CLUB_TOKEN: $CLUB_TOKEN
  script:
    - dart pub token add https://packages.example.com --env-var CLUB_TOKEN
    - dart pub get
```

### Creating a CI token

Create an API key in the web dashboard at **Settings → API keys**, then store
the printed secret as a CI secret. On the runner:

```bash
club login --key <club_pat_...> <server-url>
# Or set CLUB_TOKEN in the CI environment
```

---

## Maintenance

### Backups

A first-class backup feature is planned for a future release. In the
meantime, back up `/data` — the single source of truth for server
state. A fresh container started against the same volume picks up the
existing database, tarballs, docs, and SDKs automatically.

```bash
# SQLite (safe while server is running)
docker exec club sqlite3 /data/db/club.db ".backup /tmp/backup.db"
docker cp club:/tmp/backup.db ./club-backup-$(date +%Y%m%d).db

# Packages
docker cp club:/data/blobs ./packages-backup/
```

### Monitoring

Monitor the health endpoint:

```bash
# Simple check
curl -sf https://packages.example.com/api/v1/health | jq .status

# In your monitoring system (Datadog, Prometheus, etc.)
# Alert if status != "ok" or if endpoint is unreachable
```

### Logs

```bash
# View logs
docker compose logs -f club

# Last 100 lines
docker compose logs --tail 100 club
```

### Disk Usage

```bash
# Check data volume
docker exec club du -sh /data/
docker exec club du -sh /data/blobs/
docker exec club ls -la /data/db/club.db
```

---

## Upgrading

### Docker

```bash
cd /opt/club

# Snapshot /data first (see Backups section)

# Pull new image
docker compose pull
# Or rebuild:
# docker compose build

# Restart (migrations run automatically)
docker compose up -d

# Verify
docker compose logs club | tail -20
curl -sf https://packages.example.com/api/v1/health
```

### From Source

```bash
cd /opt/club

# Snapshot /data first (see Backups section)

# Pull latest code
git pull

# Rebuild
dart pub get
dart build cli -t packages/club_server/bin/server.dart -o build/server
cd packages/club_web && npm install && npm run build && cd ../..

# Restart (via systemd or manually)
sudo systemctl restart club
```

Database migrations run automatically on startup. No manual migration steps needed.

---

## Troubleshooting

### Server won't start

```bash
# Check logs
docker compose logs club

# Common issues:
# - CLUB_JWT_SECRET not set or too short
# - CLUB_SERVER_URL not set
# - Port 8080 already in use
# - Permission denied on /data volume
```

### dart pub publish fails with 401

```bash
# Check token is registered
dart pub token list

# Re-register
dart pub token remove https://packages.example.com
club setup

# Check server logs for the auth failure reason
docker compose logs -f club
```

### dart pub get fails with connection refused

```bash
# Verify server is reachable
curl -v https://packages.example.com/api/v1/health

# Check DNS
nslookup packages.example.com

# Check TLS
openssl s_client -connect packages.example.com:443
```

### "Package not found" but it was published

```bash
# Check the package exists
curl -H "Authorization: Bearer $TOKEN" \
  https://packages.example.com/api/packages/my_package | jq .

# Check search index
curl -H "Authorization: Bearer $TOKEN" \
  "https://packages.example.com/api/search?q=my_package" | jq .
```

### Database locked errors (SQLite)

```bash
# Verify no other process has the database open
docker exec club fuser /data/db/club.db

# If persistent, consider switching to PostgreSQL
```

### Out of disk space

```bash
# Check disk usage
docker system df -v
docker exec club du -sh /data/

# Clean up Docker
docker image prune -a
docker volume prune

# Consider S3 for package storage
```

---

## Security Checklist

- [ ] Generate a strong JWT secret (`openssl rand -hex 32`)
- [ ] Change the admin password after first login
- [ ] Use HTTPS (Caddy or nginx with TLS)
- [ ] Bind port 8080 to localhost only (`127.0.0.1:8080:8080`)
- [ ] Set up automated backups
- [ ] Monitor the health endpoint
- [ ] Review Docker container resource limits
- [ ] Rotate API tokens periodically
- [ ] Use CI/CD tokens with minimal scopes (`read` for builds, `read,write` for publish)
