#!/usr/bin/env bash
# ralph-upgrade — pull latest ai-ralph clone + reinstall.
#
# Usage:
#   ralph.upgrade               # prompt
#   ralph.upgrade --yes         # skip prompt
#   ralph.upgrade --rollback    # revert
#   ralph.upgrade --force       # bypass peer-floor
#   ralph.upgrade --reinstall   # re-run install even when version.json
#                                 is unchanged (urgent mid-release fix).
#                                 Still fetches origin/main and rebases so
#                                 the clone picks up new commits behind the
#                                 same version number.
#   ralph.upgrade --skip-install  # (test only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

YES=false
ROLLBACK=false
FORCE=false
REINSTALL=false
SKIP_INSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=true; shift ;;
    --rollback) ROLLBACK=true; shift ;;
    --force) FORCE=true; shift ;;
    --reinstall) REINSTALL=true; shift ;;
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

# The _wb_* helpers in lib/version-check.sh resolve the clone independently via
# _wb_clone_path, which reads RALPH_CLONE with no SCRIPT_DIR fallback. When that
# env var is unset (e.g. a stamped workbench invokes ralph.upgrade directly) the
# helpers go blind: _wb_local_version returns a bogus "0.0.0" (false-positive
# upgrade) and _wb_record_prior hits `return 1`, which kills the script silently
# under set -e. Export the resolved clone so every helper sees the same path.
export RALPH_CLONE="$CLONE"

# Chain per-engine installers (devin, codex) when present. Root install.sh
# only refreshes ~/.ralph/{lib,templates,...} and the Claude bits; engine
# code lives under ~/.ralph/devin and ~/.ralph/codex and is owned by the
# engine-specific install scripts.
_run_engine_installs() {
  local clone="$1"
  if [[ -x "$clone/devin/install_devin.sh" ]]; then
    bash "$clone/devin/install_devin.sh" install || return $?
  fi
  if [[ -x "$clone/codex/install_codex.sh" ]]; then
    bash "$clone/codex/install_codex.sh" install || return $?
  fi
  # Explicit success so the final [[ ... ]] test doesn't bubble its non-zero
  # status out under set -e when an engine installer is absent.
  return 0
}

if $ROLLBACK; then
  prior="${WB_UPDATES_CACHE_DIR:-$HOME/.cache/wb-updates}/ralph-prior.json"
  [[ -f "$prior" ]] || { printf "No prior recorded. Nothing to roll back.\n" >&2; exit 1; }
  prior_sha="$(jq -r .prior_sha "$prior")"
  prior_v="$(jq -r .prior_version "$prior")"
  printf "Rolling back to %s (%s)...\n" "$prior_v" "$prior_sha"
  git -C "$CLONE" checkout -q "$prior_sha"
  if ! $SKIP_INSTALL && [[ -x "$CLONE/install.sh" ]]; then
    bash "$CLONE/install.sh"
    _run_engine_installs "$CLONE"
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
  if ! $REINSTALL; then
    printf "[ralph] already at %s\n" "$local_v"
    exit 0
  fi
  # --reinstall: fetch + rebase any new commits behind the same version, then
  # rerun install. Skips the diff confirmation prompt because there's no
  # version delta to summarise.
  printf "[ralph] reinstall requested at %s (forcing fetch + install)\n" "$local_v"
  git -C "$CLONE" pull --rebase -q origin main
  if ! $SKIP_INSTALL && [[ -x "$CLONE/install.sh" ]]; then
    bash "$CLONE/install.sh"
    _run_engine_installs "$CLONE"
  fi
  _wb_cache_invalidate ralph
  _wb_mark_bootstrapped ralph
  printf "[ralph] reinstalled at %s\n" "$local_v"
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

# Non-fatal: a bare _wb_record_prior under set -e would silently kill the
# upgrade after the user already confirmed if the helper ever returns 1.
_wb_record_prior ralph || printf "[ralph] warning: could not record prior version for rollback\n" >&2
git -C "$CLONE" pull --rebase -q origin main
if ! $SKIP_INSTALL && [[ -x "$CLONE/install.sh" ]]; then
  bash "$CLONE/install.sh"
  _run_engine_installs "$CLONE"
fi
_wb_cache_invalidate ralph
_wb_mark_bootstrapped ralph
printf "[ralph] upgraded %s -> %s.\n" "$local_v" "$upstream_v"
