#!/usr/bin/env bash
#
# squash_branch.sh — Collapse the entire history of `main` into a single commit.
#
# WHAT IT DOES
#   1. Creates a new orphan branch (no parent, no history) containing the
#      current working tree as a single "initial commit".
#   2. Replaces `main` with this orphan branch locally.
#   3. Rewrites every existing tag to point at the new single commit.
#   4. Force-pushes the rewritten `main` and all tags to `origin`.
#
# WHY YOU MIGHT RUN THIS
#   - Starting fresh on a project and want to discard noisy early history.
#   - Removing accidentally committed data from history (note: see WARNINGS).
#
# WARNINGS — READ BEFORE RUNNING
#   - DESTRUCTIVE: rewrites `main` history on the remote via force-push.
#   - All collaborators will need to re-clone; their local `main` will diverge.
#   - Open PRs against `main` will be broken (their base history no longer exists).
#   - Old commits become unreachable on the remote but are NOT immediately
#     deleted. On GitHub they remain accessible by SHA for ~90 days until
#     garbage collection runs. For true removal (e.g. leaked secrets), you
#     must delete and recreate the repository.
#   - All tags will point to the SAME commit after this runs, since the
#     per-release history no longer exists. `git checkout v0.1.0` and
#     `git checkout v0.2.0` will land on the same squashed commit.
#   - Only `main` is rewritten. Other branches are left untouched locally
#     and on the remote.
#
# REQUIREMENTS
#   - Run from the repo root with a clean working tree (or with changes you
#     want included in the squashed commit — they will be committed as-is).
#   - You must have force-push permission on `origin/main`.
#
# USAGE
#   ./scripts/squash_branch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# 1. Stage the current working tree as a brand-new root commit with no parent.
git checkout --orphan fresh
git add -A
git commit -m "initial commit"

# 2. Replace `main` with the orphan branch.
git branch -D main
git branch -m main

# 3. Re-point every existing tag at the new single commit so tags survive
#    the rewrite instead of dangling on now-unreachable commits.
#    `update-ref` is plumbing — it writes the ref directly and bypasses
#    `git tag`'s editor prompt, signing (tag.gpgSign), and annotation logic.
new_commit=$(git rev-parse HEAD)
for tag in $(git tag -l); do
  git update-ref "refs/tags/$tag" "$new_commit"
done

# 4. Force-push the rewritten branch and the retagged tags to origin.
git push -f origin main -u

# Delete all tags on the remote, then push the locally-rewritten tags fresh.
# This is more reliable than `push --tags -f`, which can skip updates in some
# edge cases (e.g. annotated→lightweight transitions, protected-tag rules).
git ls-remote --tags origin | awk '{print $2}' | grep -v '\^{}' | \
  xargs -I {} git push origin --delete {}
git push origin --tags
