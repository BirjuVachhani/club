#!/usr/bin/env bash
# =============================================================================
# dev-server.sh — Run the Dart server + SvelteKit dev server locally.
#
# No Docker needed. Starts both processes. Ctrl+C stops both.
#
# Usage:
#   ./scripts/dev-server.sh          # Empty database (setup wizard)
#   ./scripts/dev-server.sh --dummy  # Pre-seeded with real packages from pub.dev
#
# Prerequisites:
#   - dart pub get (run from repo root)
#   - cd packages/club_web && npm install
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse flags ──────────────────────────────────────────────
USE_DUMMY=false
for arg in "$@"; do
  case "$arg" in
    --dummy) USE_DUMMY=true ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ── Configure paths ──────────────────────────────────────────
if [ "$USE_DUMMY" = true ]; then
  DUMMY_DIR="${PROJECT_ROOT}/dummy_data"

  # Auto-seed if dummy data doesn't exist yet. An empty `packages/` left
  # behind by a crashed seed run should still trigger a re-seed, so we
  # check for any tarball inside it rather than just the directory.
  if [ ! -f "${DUMMY_DIR}/club.db" ] || ! compgen -G "${DUMMY_DIR}/packages/*" > /dev/null; then
    echo "Dummy data not found. Running seed script..."
    "${DUMMY_DIR}/seed.sh"
    echo ""
  fi

  export SQLITE_PATH="${SQLITE_PATH:-${DUMMY_DIR}/club.db}"
  export BLOB_PATH="${BLOB_PATH:-${DUMMY_DIR}/packages}"
  export SDK_BASE_DIR="${SDK_BASE_DIR:-${DUMMY_DIR}/sdks}"
  export DARTDOC_PATH="${DARTDOC_PATH:-${DUMMY_DIR}/dartdoc}"
  export TEMP_DIR="${TEMP_DIR:-${DUMMY_DIR}/tmp/uploads}"
  export LOGS_DIR="${LOGS_DIR:-${DUMMY_DIR}/logs}"
else
  export SQLITE_PATH="${SQLITE_PATH:-/tmp/club-dev.db}"
  export BLOB_PATH="${BLOB_PATH:-/tmp/club-dev-packages}"
  export SDK_BASE_DIR="${SDK_BASE_DIR:-/tmp/club-dev-sdks}"
  export DARTDOC_PATH="${DARTDOC_PATH:-/tmp/club-dev-dartdoc}"
  export TEMP_DIR="${TEMP_DIR:-/tmp/club-dev-uploads}"
  export LOGS_DIR="${LOGS_DIR:-/tmp/club-dev-logs}"
fi

# Dev defaults
export SERVER_URL="${SERVER_URL:-http://localhost:8080}"
# SvelteKit dev server proxies /api to :8080 but keeps the browser's
# Origin at :5173 — whitelist it so origin_guard lets login/signup through.
export ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-http://localhost:5173}"
export JWT_SECRET="${JWT_SECRET:-dev-secret-at-least-32-characters-long-for-local-testing-only}"
export ADMIN_EMAIL="${ADMIN_EMAIL:-admin@localhost}"
# ≥ 8 chars — setup wizard (used by dummy seed) rejects shorter passwords.
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin123}"
export LOG_LEVEL="${LOG_LEVEL:-debug}"

# Cleanup on exit
cleanup() {
  echo ""
  echo "Shutting down..."
  kill $DART_PID 2>/dev/null || true
  kill $SVELTE_PID 2>/dev/null || true
  wait $DART_PID 2>/dev/null || true
  wait $SVELTE_PID 2>/dev/null || true
  echo "Done."
}
trap cleanup EXIT INT TERM

echo "=== club dev server ==="
echo "  API:      http://localhost:8080"
echo "  Web UI:   http://localhost:5173 (SvelteKit HMR)"
if [ "$USE_DUMMY" = true ]; then
  echo "  Mode:     dummy (pre-seeded with real packages)"
  echo "  Admin:    ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}"
else
  echo "  Mode:     fresh (setup wizard on first run)"
fi
echo "  Database: ${SQLITE_PATH}"
echo "  Packages: ${BLOB_PATH}"
echo ""

# Start Dart API server
echo "Starting Dart API server..."
cd "${PROJECT_ROOT}"
dart run packages/club_server/bin/server.dart &
DART_PID=$!

# Wait for API server to be ready
for i in $(seq 1 15); do
  if curl -sf http://localhost:8080/api/v1/health >/dev/null 2>&1; then
    echo "Dart API server ready."
    break
  fi
  sleep 1
done

# Start SvelteKit dev server
echo "Starting SvelteKit dev server..."
cd "${PROJECT_ROOT}/packages/club_web"
npm run dev &
SVELTE_PID=$!

echo ""
echo "Both servers running. Press Ctrl+C to stop."
echo ""

# Wait for either process to exit
# Note: `wait -n` requires Bash 4.3+; macOS ships Bash 3.2, so we poll instead.
while kill -0 $DART_PID 2>/dev/null && kill -0 $SVELTE_PID 2>/dev/null; do
  sleep 1
done
