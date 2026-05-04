#!/usr/bin/env bash
# =============================================================================
# set-version.sh — Bump the club project version everywhere it's hard-coded.
#
# Updates:
#   • Every packages/*/pubspec.yaml top-level `version:` field.
#   • The runtime server version constant in
#     packages/club_server/lib/src/version.dart, which is read by the
#     /health body, /api/v1/version, and the update-status checker.
#
# Does NOT touch:
#   • packages/club_cli/lib/src/version.dart — that file holds "dev" in the
#     working tree and is overwritten at build time by scripts/build-cli.sh
#     (local) or .github/workflows/build-cli.yml (CI). Changing it here
#     would dirty the tree on every local build.
#   • Docs or MDX examples — those contain illustrative `^1.0.0` strings
#     that aren't our version number.
#   • Git tags — tag + push are a separate, explicit step.
#
# Usage:
#   ./scripts/set-version.sh 0.2.0                 # bump
#   ./scripts/set-version.sh 0.2.0 --pub-get       # bump + refresh lockfile
#   ./scripts/set-version.sh --check               # print current versions
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PUBSPECS=(
  "packages/club_core/pubspec.yaml"
  "packages/club_db/pubspec.yaml"
  "packages/club_indexed_blob/pubspec.yaml"
  "packages/club_storage/pubspec.yaml"
  "packages/club_storage_s3/pubspec.yaml"
  "packages/club_storage_firebase/pubspec.yaml"
  "packages/club_server/pubspec.yaml"
  "packages/club_api/pubspec.yaml"
  "packages/club_cli/pubspec.yaml"
)
VERSION_DART="packages/club_server/lib/src/version.dart"

# ── Parse args ───────────────────────────────────────────────────────────
VERSION=""
RUN_PUB_GET=false
CHECK_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pub-get) RUN_PUB_GET=true; shift ;;
    --check)   CHECK_ONLY=true; shift ;;
    -h|--help) sed -n '2,/^# ====/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*)        echo "Unknown flag: $1" >&2; exit 2 ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "Unexpected extra argument: $1" >&2
        exit 2
      fi
      VERSION="$1"; shift ;;
  esac
done

cd "$PROJECT_ROOT"

# ── --check: print currents and exit ─────────────────────────────────────
if [[ "$CHECK_ONLY" == "true" ]]; then
  for p in "${PUBSPECS[@]}"; do
    v="$(awk '/^version:/ {print $2; exit}' "$p")"
    printf '  %-50s %s\n' "$p" "$v"
  done
  v="$(awk -F"'" "/defaultValue:/ {print \$2; exit}" "$VERSION_DART" || true)"
  printf '  %-50s %s\n' "$VERSION_DART (defaultValue)" "${v:-?}"
  exit 0
fi

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [--pub-get]   (or --check)" >&2
  exit 2
fi

# ── Validate semver-ish ──────────────────────────────────────────────────
# Accept pub-compatible versions: X.Y.Z with optional -prerelease and +build.
# Leading 'v' is rejected so we don't write `version: v0.1.0` into pubspec.
if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
  echo "Not a valid pub version: '$VERSION'" >&2
  echo "Expected MAJOR.MINOR.PATCH[-prerelease][+build], no leading 'v'." >&2
  exit 1
fi

# Need python3 for the Dart file edit (single-quoted string replacement is
# fiddly with sed/awk across GNU/BSD). python3 is present on macOS 12+ and
# every mainstream Linux distro.
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required on PATH for set-version.sh." >&2
  exit 1
fi

echo "Setting version to: $VERSION"
echo ""

# ── Update pubspecs ──────────────────────────────────────────────────────
# Match only the first top-level `version:` line. Using awk to avoid the
# GNU/BSD sed `-i` portability split.
update_pubspec() {
  local file="$1" new="$2"
  awk -v new="$new" '
    !done && /^version:[[:space:]]/ { print "version: " new; done=1; next }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

for p in "${PUBSPECS[@]}"; do
  update_pubspec "$p" "$VERSION"
  echo "  ✓ $p"
done

# ── Update kServerVersion's defaultValue ─────────────────────────────────
# kServerVersion is a `String.fromEnvironment(...)` whose `defaultValue:`
# acts as the source of truth when the build doesn't pass a `--define`.
# We patch that argument so a fresh `dart run` from the working tree
# always reflects the bumped version, and so CI is free to override it
# at compile time without dirtying the file.
python3 - "$VERSION_DART" "$VERSION" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
new = sys.argv[2]
text = path.read_text()
new_text, n = re.subn(
    r"(defaultValue:\s*)'[^']*'",
    r"\1'" + new + "'",
    text,
    count=1,
)
if n != 1:
    sys.exit(f"Could not find a defaultValue: '...' line in {path}")
path.write_text(new_text)
PY
echo "  ✓ $VERSION_DART"

# ── Optionally refresh the workspace lockfile ────────────────────────────
if [[ "$RUN_PUB_GET" == "true" ]]; then
  echo ""
  echo "Running: dart pub get"
  dart pub get
fi

echo ""
echo "Done. Review with:  git diff"
echo "Then commit and tag, e.g.:"
echo "    git commit -am 'chore: bump version to $VERSION'"
echo "    git tag -a v$VERSION -m 'v$VERSION'"
echo "    git push origin main v$VERSION"
