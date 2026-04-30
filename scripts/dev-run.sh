#!/usr/bin/env bash
# =============================================================================
# dev-run.sh — Run the club Docker image locally for testing.
#
# Creates a container with sensible dev defaults. Data persists in a named
# Docker volume so it survives restarts.
#
# Usage:
#   ./scripts/dev-run.sh              # Start (or restart) the container
#   ./scripts/dev-run.sh --clean      # Remove existing data and start fresh
#   ./scripts/dev-run.sh --stop       # Stop the container
#   ./scripts/dev-run.sh --logs       # Tail container logs
#
# Overrides (set in your shell before running):
#   IMAGE, TAG, PORT, JWT_SECRET, ADMIN_EMAIL, ADMIN_PASSWORD
# =============================================================================
set -euo pipefail

IMAGE_NAME="${IMAGE:-club}"
IMAGE_TAG="${TAG:-dev}"
CONTAINER_NAME="club-dev"
# Must match the `name:` in docker-compose.dev.yml and
# docker/docker-compose.yml so data is shared across all launch methods
# and survives rebuilds.
VOLUME_NAME="club_data"
PORT="${PORT:-8080}"

# Default dev secrets (DO NOT use these in production)
JWT_SECRET="${JWT_SECRET:-dev-secret-at-least-32-characters-long-for-local-testing-only}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

# ── Handle flags ──────────────────────────────────────────────

if [[ "${1:-}" == "--stop" ]]; then
  echo "Stopping ${CONTAINER_NAME}..."
  docker stop "${CONTAINER_NAME}" 2>/dev/null || true
  docker rm "${CONTAINER_NAME}" 2>/dev/null || true
  echo "Stopped."
  exit 0
fi

if [[ "${1:-}" == "--logs" ]]; then
  docker logs -f "${CONTAINER_NAME}"
  exit 0
fi

if [[ "${1:-}" == "--clean" ]]; then
  echo ""
  echo "WARNING: This will permanently delete the '${VOLUME_NAME}' volume."
  echo "         All packages, users, tokens, and SQLite data will be lost."
  echo ""
  read -rp "Type 'yes' to confirm: " CONFIRM
  if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted. Nothing changed."
    exit 0
  fi
  echo "Removing existing container and data..."
  docker stop "${CONTAINER_NAME}" 2>/dev/null || true
  docker rm "${CONTAINER_NAME}" 2>/dev/null || true
  docker volume rm "${VOLUME_NAME}" 2>/dev/null || true
  echo "Clean."
fi

# ── Check image exists ────────────────────────────────────────

if ! docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" &>/dev/null; then
  echo "Image ${IMAGE_NAME}:${IMAGE_TAG} not found."
  echo "Build it first: ./scripts/dev-build.sh"
  exit 1
fi

# ── Stop existing container if running ────────────────────────

if docker ps -q -f "name=${CONTAINER_NAME}" | grep -q .; then
  echo "Stopping existing ${CONTAINER_NAME}..."
  docker stop "${CONTAINER_NAME}" >/dev/null
  docker rm "${CONTAINER_NAME}" >/dev/null
fi

if docker ps -aq -f "name=${CONTAINER_NAME}" | grep -q .; then
  docker rm "${CONTAINER_NAME}" >/dev/null
fi

# ── Start container ───────────────────────────────────────────

echo "Starting ${CONTAINER_NAME}..."
echo "  Image:  ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  Port:   http://localhost:${PORT}"
echo "  Admin:  ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}"
echo "  Volume: ${VOLUME_NAME}"
echo ""

docker run -d \
  --name "${CONTAINER_NAME}" \
  -p "${PORT}:8080" \
  -v "${VOLUME_NAME}:/data" \
  -e "SERVER_URL=http://localhost:${PORT}" \
  -e "JWT_SECRET=${JWT_SECRET}" \
  -e "ADMIN_EMAIL=${ADMIN_EMAIL}" \
  -e "ADMIN_PASSWORD=${ADMIN_PASSWORD}" \
  "${IMAGE_NAME}:${IMAGE_TAG}"

# ── Wait for healthy ──────────────────────────────────────────

echo "Waiting for server to be ready..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${PORT}/api/v1/health" >/dev/null 2>&1; then
    echo ""
    echo "club is running at http://localhost:${PORT}"
    echo ""

    # Show admin token on first run
    sleep 1
    ADMIN_TOKEN=$(docker logs "${CONTAINER_NAME}" 2>&1 | grep "Admin token:" | tail -1 | sed 's/.*Admin token: //')
    if [[ -n "${ADMIN_TOKEN}" ]]; then
      echo "Admin token: ${ADMIN_TOKEN}"
      echo ""
      echo "Quick test:"
      echo "  curl -H 'Authorization: Bearer ${ADMIN_TOKEN}' http://localhost:${PORT}/api/search"
      echo ""
    fi

    echo "Logs:  ./scripts/dev-run.sh --logs"
    echo "Stop:  ./scripts/dev-run.sh --stop"
    echo "Clean: ./scripts/dev-run.sh --clean"
    exit 0
  fi
  printf "."
  sleep 1
done

echo ""
echo "Server did not become healthy in 30 seconds."
echo "Check logs: docker logs ${CONTAINER_NAME}"
exit 1
