#!/usr/bin/env bash
# =============================================================================
# uninstall.sh - Remove a club CLI installation created by install.sh.
#
# One-liner:
#   curl -fsSL https://club.birju.dev/uninstall.sh | bash
#
# Common flags:
#   ./scripts/uninstall.sh                        # remove binary + bundle
#   ./scripts/uninstall.sh --purge                # also delete credentials
#   ./scripts/uninstall.sh --install-dir /usr/local/bin
#   ./scripts/uninstall.sh --dry-run              # show what would be removed
#
# Only touches the same paths install.sh writes to:
#   <install-dir>/club                     (binary or wrapper; default ~/.local/bin)
#   ~/.local/share/club                    (bundle dir, only if archive had lib/)
#   ~/.config/club                         (credentials; only with --purge)
#
# --purge additionally unregisters the tokens `club login` / `club setup`
# handed to `dart pub token add`. Those live in dart's own config, not in
# ~/.config/club, so deleting our directory alone would leave them behind.
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
CREDENTIALS="${CONFIG_DIR}/credentials.json"

# Collect targets that actually exist so the output reflects reality
# instead of listing phantom paths.
targets=()
[[ -e "$BIN"         ]] && targets+=("$BIN")
[[ -d "$SHARE_DIR"   ]] && targets+=("$SHARE_DIR")
if [[ "$PURGE" == "1" ]] && [[ -d "$CONFIG_DIR" ]]; then
  targets+=("$CONFIG_DIR")
fi

# ── dart pub tokens ──────────────────────────────────────────────────────
# `club login` and `club setup` both shell out to `dart pub token add
# <server-url>`, which writes into dart's config (~/.config/dart/
# pub-tokens.json) rather than ours. Removing ~/.config/club alone leaves a
# live token pointing at the server, so --purge walks the servers we know
# about and unregisters each one.
#
# The server list has to be read *before* anything is deleted, since
# credentials.json is where it comes from.
servers=()
if [[ "$PURGE" == "1" ]] && [[ -f "$CREDENTIALS" ]]; then
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r url; do
      [[ -n "$url" ]] && servers+=("$url")
    done < <(jq -r '.servers // {} | keys[]' "$CREDENTIALS" 2>/dev/null || true)
  else
    # jq is not guaranteed on a stock machine. credentials.json is always
    # written by Dart's JsonEncoder.withIndent('  '), so the server URLs
    # are reliably the four-space-indented keys under "servers".
    while IFS= read -r url; do
      [[ -n "$url" ]] && servers+=("$url")
    done < <(sed -n 's/^    "\(https\{0,1\}:\/\/[^"]*\)"[[:space:]]*:.*/\1/p' \
               "$CREDENTIALS" 2>/dev/null || true)
  fi
fi

if [[ ${#targets[@]} -eq 0 ]] && [[ ${#servers[@]} -eq 0 ]]; then
  echo "Nothing to remove."
  echo "  Looked for: $BIN, $SHARE_DIR$([[ "$PURGE" == "1" ]] && echo ", $CONFIG_DIR")"
  if [[ "$PURGE" != "1" ]] && [[ -d "$CONFIG_DIR" ]]; then
    echo ""
    echo "Note: $CONFIG_DIR still contains credentials. Re-run with --purge to delete it."
  fi
  exit 0
fi

echo "The following will be removed:"
if [[ ${#targets[@]} -gt 0 ]]; then
  for t in "${targets[@]}"; do
    echo "  - $t"
  done
fi
if [[ ${#servers[@]} -gt 0 ]]; then
  for s in "${servers[@]}"; do
    echo "  - dart pub token for $s"
  done
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo ""
  echo "Dry run. Nothing deleted."
  exit 0
fi

# Unregister pub tokens first: credentials.json is the only record of which
# servers were configured, and the loop above already read it, but doing
# this first keeps the ordering obvious if the rm below ever fails.
if [[ ${#servers[@]} -gt 0 ]]; then
  echo ""
  if command -v dart >/dev/null 2>&1; then
    for s in "${servers[@]}"; do
      if dart pub token remove "$s" >/dev/null 2>&1; then
        echo "  ✓ unregistered dart pub token for $s"
      else
        # Not fatal. The token may already be gone, or dart may be a
        # version without `token remove`. Either way the user gets the
        # exact command to finish the job.
        echo "  ! could not unregister $s" >&2
        echo "    run: dart pub token remove $s" >&2
      fi
    done
  else
    echo "  ! dart is not on PATH, so these pub tokens were left in place:" >&2
    for s in "${servers[@]}"; do
      echo "      dart pub token remove $s" >&2
    done
  fi
fi

if [[ ${#targets[@]} -gt 0 ]]; then
  for t in "${targets[@]}"; do
    rm -rf -- "$t"
  done
fi

echo ""
echo "✓ club CLI uninstalled."

# If credentials were left behind, point the user at --purge so they
# don't discover stale state months from now.
if [[ "$PURGE" != "1" ]] && [[ -d "$CONFIG_DIR" ]]; then
  echo ""
  echo "Note: $CONFIG_DIR was kept, along with any tokens registered with"
  echo "      dart pub. Re-run with --purge to delete both."
fi
