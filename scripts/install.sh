#!/usr/bin/env bash
# =============================================================================
# install.sh — Download the club CLI from a GitHub Release and put it on PATH.
#
# One-liner:
#   curl -fsSL https://club.birju.dev/install.sh | bash
#
# Common flags:
#   ./scripts/install.sh                          # newest release (incl. pre-releases)
#   ./scripts/install.sh --version 0.1.0          # pin a specific version
#   ./scripts/install.sh --install-dir /usr/local/bin
#
# Env vars:
#   CLUB_VERSION   Same as --version.
#   CLUB_REPO      Override repo (default: BirjuVachhani/club). For forks.
# =============================================================================
set -euo pipefail

REPO="${CLUB_REPO:-BirjuVachhani/club}"
VERSION="${CLUB_VERSION:-}"
INSTALL_DIR="${HOME}/.local/bin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)       VERSION="${2:?--version requires a value}"; shift 2 ;;
    --install-dir)   INSTALL_DIR="${2:?--install-dir requires a value}"; shift 2 ;;
    --repo)          REPO="${2:?--repo requires a value}"; shift 2 ;;
    -h|--help)       sed -n '2,/^# ====/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── Require curl, tar, shasum/sha256sum ──────────────────────────────────
require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
require curl
require tar

if command -v sha256sum >/dev/null 2>&1; then
  SHA256="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256="shasum -a 256"
else
  echo "Missing sha256sum/shasum — cannot verify downloads." >&2
  exit 1
fi

# ── Detect target ────────────────────────────────────────────────────────
uname_s="$(uname -s)"
uname_m="$(uname -m)"
case "$uname_s" in
  Linux)  os="linux" ;;
  Darwin) os="macos" ;;
  *)      echo "Unsupported OS: $uname_s (Windows users: download the .zip from the release page)" >&2; exit 1 ;;
esac
case "$uname_m" in
  x86_64|amd64)   arch="x64" ;;
  arm64|aarch64)  arch="arm64" ;;
  *) echo "Unsupported CPU: $uname_m" >&2; exit 1 ;;
esac
TARGET="${os}-${arch}"

# ── Resolve tag ──────────────────────────────────────────────────────────
# With an explicit --version we just use it. Otherwise list the releases
# and take the newest entry — unlike /releases/latest, this includes
# pre-releases, so `install.sh` with no args always pulls the most
# recently published tag.
if [[ -n "$VERSION" ]]; then
  TAG="$VERSION"
else
  echo "Resolving latest release from ${REPO}..."
  TAG="$(curl -fsSL -H "Accept: application/vnd.github+json" \
           "https://api.github.com/repos/${REPO}/releases?per_page=1" \
           | tr -d '\n' \
           | grep -oE '"tag_name":[[:space:]]*"[^"]+"' \
           | head -n1 \
           | cut -d'"' -f4)"
  if [[ -z "$TAG" ]]; then
    echo "No releases found for ${REPO}." >&2
    exit 1
  fi
fi

# Strip any leading `v` to get the bare semver used inside asset names.
RESOLVED_VERSION="${TAG#v}"
ARCHIVE_NAME="club-cli-${RESOLVED_VERSION}-${TARGET}.tar.gz"
SUMS_NAME="SHA256SUMS.txt"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

# ── Detect existing installation ─────────────────────────────────────────
# We look in three places, in order of likely interference:
#   1. `$INSTALL_DIR/club` — a prior run of this script.
#   2. `$HOME/.local/share/club/bundle/bin/club` — old bundle layout.
#   3. whatever `club` resolves to on PATH — could be Homebrew or another
#      package manager entirely. We warn about that case below.
INSTALLED_PATH=""
INSTALLED_VERSION=""
if [[ -x "${INSTALL_DIR}/club" ]]; then
  INSTALLED_PATH="${INSTALL_DIR}/club"
elif [[ -x "${HOME}/.local/share/club/bundle/bin/club" ]]; then
  INSTALLED_PATH="${HOME}/.local/share/club/bundle/bin/club"
elif command -v club >/dev/null 2>&1; then
  INSTALLED_PATH="$(command -v club)"
fi

if [[ -n "$INSTALLED_PATH" ]]; then
  # `club --version` prints either "club <ver>" or just "<ver>" depending
  # on the build; grep out the first semver-looking token either way.
  INSTALLED_VERSION="$("$INSTALLED_PATH" --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' \
    | head -n1 || true)"
fi

if [[ -n "$INSTALLED_VERSION" ]]; then
  if [[ "$INSTALLED_VERSION" == "$RESOLVED_VERSION" ]]; then
    echo "Reinstalling club ${RESOLVED_VERSION} (${TARGET}) over existing ${INSTALLED_PATH}"
  else
    echo "Upgrading club ${INSTALLED_VERSION} → ${RESOLVED_VERSION} (${TARGET})"
  fi
else
  echo "Installing club CLI ${RESOLVED_VERSION} (${TARGET})"
fi

# ── Download into a temp dir and verify ──────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "  ↓ ${ARCHIVE_NAME}"
if ! curl -fsSL -o "${TMP}/${ARCHIVE_NAME}" "${BASE}/${ARCHIVE_NAME}"; then
  echo "Could not download ${BASE}/${ARCHIVE_NAME}" >&2
  echo "Check that the release exists and includes a build for ${TARGET}." >&2
  exit 1
fi

echo "  ↓ ${SUMS_NAME}"
if ! curl -fsSL -o "${TMP}/${SUMS_NAME}" "${BASE}/${SUMS_NAME}"; then
  echo "Release ${TAG} has no ${SUMS_NAME} — refusing to install without a checksum." >&2
  exit 1
fi

echo "  ✓ verifying checksum"
EXPECTED="$(awk -v f="$ARCHIVE_NAME" '$2 == f || $2 == "*"f {print $1}' "${TMP}/${SUMS_NAME}")"
if [[ -z "$EXPECTED" ]]; then
  echo "Checksum for ${ARCHIVE_NAME} not found in ${SUMS_NAME}." >&2
  exit 1
fi
ACTUAL="$($SHA256 "${TMP}/${ARCHIVE_NAME}" | awk '{print $1}')"
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "Checksum mismatch!" >&2
  echo "  expected: $EXPECTED" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi

# ── Extract and install ──────────────────────────────────────────────────
tar -C "$TMP" -xzf "${TMP}/${ARCHIVE_NAME}"
STAGE="${TMP}/club-cli-${RESOLVED_VERSION}-${TARGET}"
BIN="${STAGE}/bin/club"
if [[ ! -x "$BIN" ]]; then
  echo "Archive layout unexpected — no executable at ${BIN}." >&2
  exit 1
fi

# `dart build cli` would emit a lib/ directory alongside bin/ if the CLI
# picked up native deps. It doesn't today, but handle both cases so we
# don't silently drop a dynamic library on upgrade.
SHARE_DIR="${HOME}/.local/share/club"
if [[ -d "${STAGE}/lib" ]] && [[ -n "$(ls -A "${STAGE}/lib" 2>/dev/null)" ]]; then
  mkdir -p "$SHARE_DIR" "$INSTALL_DIR"
  rm -rf "${SHARE_DIR}/bundle"
  mkdir -p "${SHARE_DIR}/bundle"
  cp -R "${STAGE}/bin" "${SHARE_DIR}/bundle/bin"
  cp -R "${STAGE}/lib" "${SHARE_DIR}/bundle/lib"
  cat > "${INSTALL_DIR}/club" <<EOF
#!/usr/bin/env bash
exec "${SHARE_DIR}/bundle/bin/club" "\$@"
EOF
  chmod +x "${INSTALL_DIR}/club"
  echo "Installed bundle to: ${SHARE_DIR}/bundle"
  echo "Wrapper at:          ${INSTALL_DIR}/club"
else
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$BIN" "${INSTALL_DIR}/club"
  # Switching from a bundled layout back to a standalone binary leaves
  # the old bundle dir behind. It still works (the new wrapper would
  # find it), but a future upgrade could get confused about which
  # version is installed. Drop it.
  if [[ -d "${SHARE_DIR}/bundle" ]]; then
    rm -rf "${SHARE_DIR}/bundle"
  fi
  echo "Installed to: ${INSTALL_DIR}/club"
fi

# ── PATH hint ────────────────────────────────────────────────────────────
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*)
    echo ""
    echo "✓ ${INSTALL_DIR} is on your PATH."
    # If another `club` binary earlier on PATH is shadowing the one we
    # just installed (common with Homebrew's /opt/homebrew/bin on macOS),
    # warn — otherwise the user "upgrades" but `club --version` keeps
    # reporting the old build and they can't tell why.
    RESOLVED_ON_PATH="$(command -v club 2>/dev/null || true)"
    if [[ -n "$RESOLVED_ON_PATH" ]] && [[ "$RESOLVED_ON_PATH" != "${INSTALL_DIR}/club" ]]; then
      echo ""
      echo "⚠  Another \`club\` binary is shadowing the one we just installed:"
      echo "     on PATH:  ${RESOLVED_ON_PATH}"
      echo "     installed: ${INSTALL_DIR}/club"
      echo "   Remove it or put ${INSTALL_DIR} earlier in your PATH so the"
      echo "   upgraded binary takes effect."
    else
      echo "  Try:  club --version"
    fi
    ;;
  *)
    echo ""
    echo "⚠  ${INSTALL_DIR} is NOT on your PATH yet."
    case "${SHELL:-}" in
      */zsh)  echo "  echo 'export PATH=\"${INSTALL_DIR}:\$PATH\"' >> ~/.zshrc" ;;
      */bash) echo "  echo 'export PATH=\"${INSTALL_DIR}:\$PATH\"' >> ~/.bashrc" ;;
      */fish) echo "  fish_add_path \"${INSTALL_DIR}\"" ;;
      *)      echo "  Add ${INSTALL_DIR} to your shell's PATH." ;;
    esac
    ;;
esac
