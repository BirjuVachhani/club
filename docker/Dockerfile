# =============================================================================
# club — multi-stage Docker build
# =============================================================================
# Stage 1: Build the Dart server using dart build cli
# Stage 2: Build the SvelteKit web UI into static assets
# Stage 3: Minimal runtime image
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1 — Dart server build
# ---------------------------------------------------------------------------
FROM dart:stable AS dart-builder

WORKDIR /app

# Copy workspace root files first for better layer caching
COPY pubspec.yaml pubspec.lock ./

# Copy server-side workspace packages (order: dependencies before dependents).
# The CLI is intentionally NOT copied — it's a client tool, distributed
# via GitHub Releases (see .github/workflows/build-cli.yml). However its
# pubspec.yaml IS required at the workspace root for `dart pub get` to
# resolve the workspace, so copy just the manifest.
COPY packages/club_core/              packages/club_core/
COPY packages/club_api/               packages/club_api/
COPY packages/club_package_reader/    packages/club_package_reader/
COPY packages/club_indexed_blob/      packages/club_indexed_blob/
COPY packages/club_db/                packages/club_db/
COPY packages/club_storage/           packages/club_storage/
COPY packages/club_storage_s3/        packages/club_storage_s3/
COPY packages/club_storage_firebase/  packages/club_storage_firebase/
COPY packages/club_server/            packages/club_server/
COPY packages/club_cli/pubspec.yaml   packages/club_cli/pubspec.yaml

# Resolve dependencies
RUN dart pub get

# Build the server
RUN dart build cli \
  -t packages/club_server/bin/server.dart \
  -o /app/build/server

# Build the scoring subprocess. AOT-compiled separately because the server
# spawns it as a short-lived child per scoring job — keeping pana out of
# the main server process so an RCE in an analyzer plugin or build hook
# can't touch the DB, blob store, or request handlers. See
# packages/club_server/lib/src/scoring/scoring_service.dart for the
# parent-side protocol.
RUN dart build cli \
  -t packages/club_server/bin/scoring_subprocess.dart \
  -o /app/build/scoring_subprocess

# Copy SPDX license data for pana (required in AOT mode for license detection).
RUN cp -r "$(find /root/.pub-cache -path '*/pana-*/lib/src/third_party/spdx/licenses' -type d | head -1)" \
  /app/build/server/bundle/spdx-licenses

# ---------------------------------------------------------------------------
# Stage 2 — SvelteKit static build
# ---------------------------------------------------------------------------
# Pinned to the host's native arch via $BUILDPLATFORM. The output is static
# HTML/JS/CSS — arch-independent — so running it once and reusing the result
# for every target platform avoids QEMU-emulated npm (very slow on arm64
# cross-builds from an amd64 runner).
FROM --platform=$BUILDPLATFORM node:22-alpine AS web-builder

WORKDIR /web

# Install dependencies first for layer caching
COPY packages/club_web/package.json packages/club_web/package-lock.json* ./
RUN npm ci

# Copy the rest of the web source and build
COPY packages/club_web/ ./
RUN npm run build

# ---------------------------------------------------------------------------
# Stage 3 — Minimal runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

# Runtime deps only. git + curl + unzip are used by pana / the Flutter SDK
# setup at runtime. webp ships the screenshot tools pana requires
# (webpinfo, cwebp, dwebp, gif2webp, webpmux). setpriv is part of
# util-linux, which is pre-installed in debian:bookworm-slim — no apt
# install needed — and is how the entrypoint drops the scoring subprocess
# to the unprivileged `scoring` user.
#
# The image is deliberately user-agnostic at the server level: the server
# runs as root by default and respects `docker run --user` / compose's
# `user:` for operator-chosen UIDs. The scoring subprocess is always
# sandboxed regardless — see below.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl git unzip webp && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /data

# Dedicated unprivileged account for the scoring subprocess. Fixed UID/GID
# 1001 so volume permissions are predictable across rebuilds. The server
# process drops to this UID via `setpriv` when it spawns scoring jobs
# (see SCORING_SANDBOX_UID/GID below). An RCE inside pana therefore runs
# as UID 1001 with no access to the server's files.
RUN groupadd --system --gid 1001 scoring && \
    useradd  --system --uid 1001 --gid 1001 --home-dir /nonexistent --shell /usr/sbin/nologin scoring

WORKDIR /app

COPY --from=dart-builder /app/build/server/bundle/              /app/
COPY --from=dart-builder /app/build/scoring_subprocess/bundle/  /app/scoring_subprocess/
COPY --from=web-builder  /web/build/                            /app/static/web/
COPY docker/entrypoint.sh                                       /app/bin/entrypoint.sh
RUN chmod +x /app/bin/entrypoint.sh

VOLUME /data
EXPOSE 8080

# ── Scoring sandbox defaults (override via `docker run -e …` if needed) ──
#
# SCORING_SUBPROCESS_BINARY points at the AOT-compiled scoring subprocess
# so the server skips its `dart run` fallback (which would also require
# the Dart SDK to be on PATH at runtime — which it isn't in this image).
#
# UID/GID 1001 match the scoring user created above.
#
# Default rlimits (ulimit short flags): 4 GB virtual memory, 1 h CPU
# time, 1024 open files. Keeps one bad package from exhausting the host.
# Bump `t` if analyses legitimately exceed an hour.
#
# To disable any layer at runtime, pass `-e SCORING_SANDBOX_UID=` etc.
# with an empty value; SandboxConfig.fromEnv ignores empty values.
ENV SCORING_SUBPROCESS_BINARY=/app/scoring_subprocess/bin/scoring_subprocess \
    SCORING_SANDBOX_UID=1001 \
    SCORING_SANDBOX_GID=1001 \
    SCORING_SANDBOX_RLIMITS=v=4194304,t=3600,n=1024

# Healthcheck without curl — use wget from busybox or a simple tcp check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["sh", "-c", "exec 3<>/dev/tcp/localhost/8080 && echo -e 'GET /api/v1/health HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && grep -q '\"ok\"' <&3"]

ENTRYPOINT ["/app/bin/entrypoint.sh"]
