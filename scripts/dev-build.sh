#!/usr/bin/env bash
# =============================================================================
# dev-build.sh — Build the club Docker image locally for testing.
#
# The image will be tagged `club:dev`. This is a stable, local-only tag
# referenced by `dev-run.sh`, `docker-dev/docker-compose.yml`, and
# `docker-compose.dev.yml` — keeping it stable means those files don't
# need to be edited every time you rebuild.
#
# Overrides:
#   IMAGE      override repo name (default: club)
#   TAG        override the tag (default: dev)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_NAME="${IMAGE:-club}"
IMAGE_TAG="${TAG:-dev}"
PRIMARY="${IMAGE_NAME}:${IMAGE_TAG}"

echo "Building club Docker image..."
echo "  Image:   ${PRIMARY}"
echo "  Context: ${PROJECT_ROOT}"
echo ""

docker buildx build \
  --load \
  -f "${PROJECT_ROOT}/docker/Dockerfile" \
  -t "${PRIMARY}" \
  "${PROJECT_ROOT}"

echo ""
echo "Build complete: ${PRIMARY}"
echo ""
echo "Image size:"
docker images "${PRIMARY}" --format "  {{.Size}}"
echo ""
echo "Run it with:"
echo "  ./scripts/dev-run.sh"
echo ""
echo "Or manually:"
echo "  docker run -p 8080:8080 -e SERVER_URL=http://localhost:8080 -e JWT_SECRET=\$(openssl rand -hex 32) -e ADMIN_EMAIL=admin@localhost -e ADMIN_PASSWORD=admin ${PRIMARY}"
