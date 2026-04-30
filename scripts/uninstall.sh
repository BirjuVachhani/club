#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — Remove a club CLI installation created by install.sh.
#
# One-liner:
#   curl -fsSL https://club.birju.dev/uninstall.sh | bash
#
# Common flags:
#   ./scripts/uninstall.sh                        # remove binary + bundle
#   ./scripts/uninstall.sh --purge                # also delete ~/.config/club
#   ./scripts/uninstall.sh --install-dir /usr/local/bin
#   ./scripts/uninstall.sh --dry-run              # show what would be removed
#
# Only touches the same paths install.sh writes to:
#   <install-dir>/club                     (binary or wrapper; default ~/.local/bin)
#   ~/.local/share/club                    (bundle dir, only if archive had lib/)
#   ~/.config/club                         (credentials — only with --purge)
#
# Homebrew users should run `brew uninstall club` instead.
# =============================================================================
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SHARE_DIR="${HOME}/.local/share/club"
CONFIG_DIR="${HOME}/.config/club"
PURGE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)   INSTALL_DIR="${2:?--install-dir requires a value}"; shift 2 ;;
    --purge)         PURGE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       sed -n '2,/^# ====/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

BIN="${INSTALL_DIR}/club"

# Collect targets that actually exist so the output reflects reality
# instead of listing phantom paths.
targets=()
[[ -e "$BIN"         ]] && targets+=("$BIN")
[[ -d "$SHARE_DIR"   ]] && targets+=("$SHARE_DIR")
if [[ "$PURGE" == "1" ]] && [[ -d "$CONFIG_DIR" ]]; then
  targets+=("$CONFIG_DIR")
fi

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "Nothing to remove."
  echo "  Looked for: $BIN, $SHARE_DIR$([[ "$PURGE" == "1" ]] && echo ", $CONFIG_DIR")"
  if [[ "$PURGE" != "1" ]] && [[ -d "$CONFIG_DIR" ]]; then
    echo ""
    echo "Note: $CONFIG_DIR still contains credentials. Re-run with --purge to delete it."
  fi
  exit 0
fi

echo "The following will be removed:"
for t in "${targets[@]}"; do
  echo "  - $t"
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo ""
  echo "Dry run — nothing deleted."
  exit 0
fi

for t in "${targets[@]}"; do
  rm -rf -- "$t"
done

echo ""
echo "✓ club CLI uninstalled."

# If credentials were left behind, point the user at --purge so they
# don't discover stale state months from now.
if [[ "$PURGE" != "1" ]] && [[ -d "$CONFIG_DIR" ]]; then
  echo ""
  echo "Note: $CONFIG_DIR was kept. Re-run with --purge to delete stored credentials."
fi
