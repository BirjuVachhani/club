#!/bin/sh
# =============================================================================
# Runtime entrypoint for the club image.
#
# The server runs at whatever UID the operator chooses (root by default, or
# via `docker run --user` / compose `user:`). The pana scoring worker,
# however, always runs as the unprivileged `scoring` user (UID/GID 1001)
# via `setpriv` — see packages/club_server/lib/src/scoring/sandbox.dart for
# the sandbox layering. This script makes sure the directories both
# processes touch are writable by *both* UIDs before handing control to
# /app/bin/server.
# =============================================================================
set -e

# /data layout (see packages/club_server/lib/src/bootstrap.dart + AppConfig):
#   /data/db/           SQLite db + WAL            (SQLITE_PATH=/data/db/club.db)
#   /data/blobs/        package tarballs + assets  (BLOB_PATH)
#   /data/cache/        safe-to-wipe, re-derivable
#     ├── sdks/         Dart/Flutter SDKs          (SDK_BASE_DIR)
#     ├── pub-cache/    pana's PUB_CACHE           (hardcoded)
#     └── dartdoc/      rendered dartdoc HTML      (DARTDOC_PATH)
#   /data/logs/         scoring.log                (LOGS_DIR)
#   /data/tmp/          ephemeral (uploads etc.)   (TEMP_DIR)
TEMP_DIR="${TEMP_DIR:-/data/tmp/uploads}"
BLOB_PATH="${BLOB_PATH:-/data/blobs}"
DARTDOC_PATH="${DARTDOC_PATH:-/data/cache/dartdoc}"
SDK_BASE_DIR="${SDK_BASE_DIR:-/data/cache/sdks}"
PUB_CACHE_DIR="/data/cache/pub-cache"
DB_DIR="/data/db"
LOGS_DIR="${LOGS_DIR:-/data/logs}"

mkdir -p "$TEMP_DIR" "$BLOB_PATH" "$DARTDOC_PATH" "$SDK_BASE_DIR" \
    "$PUB_CACHE_DIR" "$DB_DIR" "$LOGS_DIR" /data

# If we're root, relax perms on the paths touched by both the server and
# the scoring worker. 1777 = world-writable with sticky bit, so each UID
# can only delete its own files. This is safe for these ephemeral trees;
# they contain per-job transient state, not credentials. Skipped when the
# operator runs as non-root (--user) — in that case they own the mounted
# volumes already and fine-grained chown is their call.
if [ "$(id -u)" = "0" ]; then
    chmod 1777 "$TEMP_DIR" "$PUB_CACHE_DIR" "$DARTDOC_PATH"
    # SDKs are read by the scoring subprocess but only written by the
    # server (via SdkManager). World-readable is enough.
    chmod -R a+rX "$SDK_BASE_DIR" 2>/dev/null || true
fi

exec /app/bin/server "$@"
