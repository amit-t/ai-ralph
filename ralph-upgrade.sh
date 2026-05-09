#!/usr/bin/env bash
# ralph-upgrade — pull latest ai-ralph clone + reinstall.
#
# Usage:
#   ralph.upgrade               # prompt
#   ralph.upgrade --yes         # skip prompt
#   ralph.upgrade --rollback    # revert
#   ralph.upgrade --force       # bypass peer-floor
#   ralph.upgrade --skip-install  # (test only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

YES=false
ROLLBACK=false
FORCE=false
SKIP_INSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=true; shift ;;
    --rollback) ROLLBACK=true; shift ;;
    --force) FORCE=true; shift ;;
    --skip-install) SKIP_INSTALL=true; shift ;;
    -h|--help) cat <<USAGE
ralph.upgrade — pull and reinstall ai-ralph.
USAGE
      exit 0 ;;
    *) printf "Unknown flag: %s\n" "$1" >&2; exit 1 ;;
  esac
done

# shellcheck disable=SC1090
. "${LIB_DIR}/version-check.sh"

CLONE="${RALPH_CLONE:-}"
if [[ -z "$CLONE" ]]; then
  CLONE="$SCRIPT_DIR"
fi

if [[ ! -d "$CLONE/.git" ]]; then
  printf "ai-ralph clone not found at %s. Set RALPH_CLONE.\n" "$CLONE" >&2
  exit 1
fi

if $ROLLBACK; then
  prior="${WB_UPDATES_CACHE_DIR:-$HOME/.cache/wb-updates}/ralph-prior.json"
  [[ -f "$prior" ]] || { printf "No prior recorded. Nothing to roll back.\n" >&2; exit 1; }
  prior_sha="$(jq -r .prior_sha "$prior")"
  prior_v="$(jq -r .prior_version "$prior")"
  printf "Rolling back to %s (%s)...\n" "$prior_v" "$prior_sha"
  git -C "$CLONE" checkout -q "$prior_sha"
  if ! $SKIP_INSTALL && [[ -x "$CLONE/install.sh" ]]; then
    bash "$CLONE/install.sh"
  fi
  _wb_cache_invalidate ralph
  printf "[ralph] rolled back to %s.\n" "$prior_v"
  exit 0
fi

status="$(git -C "$CLONE" status --porcelain)"
if [[ -n "$status" ]]; then
  printf "ai-ralph clone has uncommitted changes. Commit/stash and retry.\n" >&2
  exit 2
fi

branch="$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" ]]; then
  printf "ai-ralph clone is on '%s', not 'main'. Switch to main and retry.\n" "$branch" >&2
  exit 2
fi

git -C "$CLONE" fetch -q origin main
local_v="$(_wb_local_version ralph)"
upstream_v_raw="$(git -C "$CLONE" show origin/main:version.json 2>/dev/null || echo '{}')"
upstream_v="$(echo "$upstream_v_raw" | jq -r '.version // "0.0.0"')"

if [[ "$(_wb_compare_semver "$local_v" "$upstream_v")" == "eq" ]]; then
  printf "[ralph] already at %s\n" "$local_v"
  exit 0
fi

if ! $FORCE; then
  devkit_req="$(echo "$upstream_v_raw" | jq -r '.requires.devkit // empty')"
  if [[ -n "$devkit_req" ]]; then
    devkit_local="$(_wb_local_version devkit)"
    if [[ "$(_wb_check_requires "$devkit_req" "$devkit_local")" == "fail" ]]; then
      printf "[ralph] cannot upgrade: requires devkit %s, found %s. Run devkit.upgrade first or pass --force.\n" "$devkit_req" "$devkit_local" >&2
      exit 3
    fi
  fi
fi

printf "[ralph] upgrade %s -> %s\n" "$local_v" "$upstream_v"
printf "Commits to be pulled:\n"
git -C "$CLONE" log HEAD..origin/main --oneline | head -20
if ! $YES; then
  printf "Continue? [y/N] "
  read -r answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    printf "Aborted.\n"; exit 1
  fi
fi

_wb_record_prior ralph
git -C "$CLONE" pull --rebase -q origin main
if ! $SKIP_INSTALL && [[ -x "$CLONE/install.sh" ]]; then
  bash "$CLONE/install.sh"
fi
_wb_cache_invalidate ralph
_wb_mark_bootstrapped ralph
printf "[ralph] upgraded %s -> %s.\n" "$local_v" "$upstream_v"
