# version-check.sh — bash-portable shared library for upgrade-notification.
# Origin: ai-devkit (canonical). This is a mirrored copy in ai-ralph. Keep in sync.
# Sourced from bash/zsh; body must remain bash-compatible.
# Functions exported:
#   _wb_compare_semver A B  -> "lt" | "eq" | "gt"
#   _wb_versioncheck TOOL   -> prints banner if upgrade available
#   _wb_check_requires TOOL -> verifies peer floors
#   _wb_record_prior TOOL   -> writes prior cache entry
#   _wb_render_banner TOOL  -> renders upgrade-available message

_VERCHECK_LIB_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_VERCHECK_LIB_DIR" == "${BASH_SOURCE[0]}" ]] && _VERCHECK_LIB_DIR="."
. "$_VERCHECK_LIB_DIR/bootstrap-detection.sh"

_wb_compare_semver() {
  local a="${1%%-*}" b="${2%%-*}"
  local a_major="${a%%.*}"; a="${a#*.}"
  local a_minor="${a%%.*}"; local a_patch="${a#*.}"
  [[ "$a_minor" == "$a" ]] && a_patch="0"
  [[ "$a_patch" == "$a" ]] && a_patch="0"
  local b_major="${b%%.*}"; b="${b#*.}"
  local b_minor="${b%%.*}"; local b_patch="${b#*.}"
  [[ "$b_minor" == "$b" ]] && b_patch="0"
  [[ "$b_patch" == "$b" ]] && b_patch="0"
  if (( a_major < b_major )); then echo "lt"; return; fi
  if (( a_major > b_major )); then echo "gt"; return; fi
  if (( a_minor < b_minor )); then echo "lt"; return; fi
  if (( a_minor > b_minor )); then echo "gt"; return; fi
  if (( a_patch < b_patch )); then echo "lt"; return; fi
  if (( a_patch > b_patch )); then echo "gt"; return; fi
  echo "eq"
}

_wb_check_requires() {
  local constraint="$1" current="$2"
  case "$constraint" in
    '>='*)
      local floor="${constraint#>=}"
      local cmp
      cmp="$(_wb_compare_semver "$current" "$floor")"
      if [[ "$cmp" == "lt" ]]; then echo "fail"; else echo "ok"; fi
      ;;
    *) echo "fail" ;;
  esac
}

_wb_clone_path() {
  local tool="$1"
  local var
  case "$tool" in
    devkit) var="DEVKIT_CLONE" ;;
    ralph)  var="RALPH_CLONE"  ;;
    wb)     echo ""; return ;;
    *)      echo ""; return ;;
  esac
  eval "echo \"\${$var:-}\""
}

_wb_local_version() {
  local tool="$1"
  local clone
  clone="$(_wb_clone_path "$tool")"
  if [[ "$tool" == "wb" ]]; then
    if [[ -n "${WB_TEMPLATE_VERSION_FILE:-}" && -f "$WB_TEMPLATE_VERSION_FILE" ]]; then
      jq -r '.version // "0.0.0"' "$WB_TEMPLATE_VERSION_FILE" 2>/dev/null || echo "0.0.0"
      return
    fi
    echo "0.0.0"; return
  fi
  if [[ -z "$clone" || ! -f "$clone/version.json" ]]; then
    echo "0.0.0"; return
  fi
  local v
  v="$(jq -r '.version // "0.0.0"' "$clone/version.json" 2>/dev/null)" || v="0.0.0"
  if [[ -z "$v" || "$v" == "null" ]]; then v="0.0.0"; fi
  echo "$v"
}

_wb_parse_remote() {
  local url="$1"
  url="${url%.git}"
  url="${url#https://github.com/}"
  url="${url#git@github.com:}"
  echo "$url"
}

_wb_fetch_upstream() {
  local owner="$1" repo="$2"
  local out
  if command -v gh >/dev/null 2>&1; then
    out="$(gh api "repos/${owner}/${repo}/contents/version.json?ref=main" \
                 -H "Accept: application/vnd.github.raw+json" 2>/dev/null)" && {
      [[ -n "$out" ]] && { echo "$out"; return 0; }
    }
  fi
  local tool=""
  case "$repo" in
    ai-devkit) tool="devkit" ;;
    ai-ralph)  tool="ralph"  ;;
    ai-workbench) tool="wb"  ;;
  esac
  if [[ -n "$tool" ]]; then
    local clone
    clone="$(_wb_clone_path "$tool")"
    if [[ -n "$clone" && -d "$clone/.git" ]]; then
      git -C "$clone" fetch -q origin main 2>/dev/null || return 1
      git -C "$clone" show "origin/main:version.json" 2>/dev/null && return 0
    fi
  fi
  return 1
}

_wb_cache_dir() { echo "${WB_UPDATES_CACHE_DIR:-${HOME}/.cache/wb-updates}"; }
_wb_cache_path() { local d; d="$(_wb_cache_dir)"; mkdir -p "$d"; echo "$d/$1.json"; }

_wb_cache_write() {
  local tool="$1" payload="$2" ttl="$3"
  local p ts
  p="$(_wb_cache_path "$tool")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg tool "$tool" --arg ts "$ts" --argjson ttl "$ttl" --argjson up "$payload" \
        '{tool:$tool, checked_at:$ts, ttl_hours:$ttl, upstream:$up, rate_limit_reset_at:null}' \
        > "$p"
}

_wb_cache_is_fresh() {
  local tool="$1"
  local p
  p="$(_wb_cache_path "$tool")"
  [[ -f "$p" ]] || { echo "missing"; return; }
  local ts ttl checked_at_epoch now_epoch age_seconds limit
  ts="$(jq -r .checked_at "$p" 2>/dev/null)"
  ttl="$(jq -r .ttl_hours "$p" 2>/dev/null)"
  [[ -z "$ts" || "$ts" == "null" ]] && { echo "stale"; return; }
  checked_at_epoch="$(date -u -d "$ts" +%s 2>/dev/null \
                     || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
                     || echo 0)"
  now_epoch="$(date -u +%s)"
  age_seconds=$(( now_epoch - checked_at_epoch ))
  limit=$(( ttl * 3600 ))
  if (( age_seconds < limit )); then echo "fresh"; else echo "stale"; fi
}

_wb_cache_read() {
  local tool="$1"; local p; p="$(_wb_cache_path "$tool")"
  jq -c '.upstream' "$p" 2>/dev/null
}

_wb_cache_invalidate() {
  local tool="$1"; rm -f "$(_wb_cache_path "$tool")"
}

_wb_render_banner() {
  local tool="$1" local_v="$2" latest="$3" changelog="$4"
  local upgrade_cmd
  case "$tool" in
    devkit) upgrade_cmd="devkit.upgrade" ;;
    ralph)  upgrade_cmd="ralph.upgrade"  ;;
    wb)     upgrade_cmd="wb.upgrade"     ;;
    *)      upgrade_cmd="${tool}.upgrade" ;;
  esac
  printf "[%s v%s] update %s available. Run %s. Changelog: %s\n" \
    "$tool" "$local_v" "$latest" "$upgrade_cmd" "$changelog"
}

_wb_versioncheck() {
  local tool="$1"
  local owner="${WB_UPSTREAM_OWNER:-amit-t}"
  local repo_var="WB_UPSTREAM_REPO_${tool}"
  local repo=""
  eval "repo=\"\${$repo_var:-}\""
  if [[ -z "$repo" ]]; then
    case "$tool" in
      devkit) repo="ai-devkit" ;;
      ralph)  repo="ai-ralph"  ;;
      wb)     repo="ai-workbench" ;;
      *) return 0 ;;
    esac
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf "[%s] jq missing — required for update notifications. brew install jq\n" "$tool" >&2
    return 0
  fi

  local local_check
  local_check="$(_wb_local_version "$tool")"
  if [[ "$local_check" == "0.0.0" ]]; then
    _wb_emit_bootstrap_nag "$tool"
  fi

  local fresh upstream_json
  fresh="$(_wb_cache_is_fresh "$tool")"
  if [[ "$fresh" == "fresh" ]]; then
    upstream_json="$(_wb_cache_read "$tool")"
  else
    printf "[%s] checking for updates...\n" "$tool" >&2
    if ! upstream_json="$(_wb_fetch_upstream "$owner" "$repo" 2>/dev/null)"; then
      printf "[%s] update check skipped (offline)\n" "$tool" >&2
      return 0
    fi
    local ttl
    ttl="$(echo "$upstream_json" | jq -r '.check_ttl_hours // 12')"
    _wb_cache_write "$tool" "$upstream_json" "$ttl"
  fi

  local latest changelog
  latest="$(echo "$upstream_json" | jq -r '.version // "0.0.0"')"
  changelog="$(echo "$upstream_json" | jq -r '.changelog_url // ""')"
  if [[ "$(_wb_compare_semver "$local_check" "$latest")" == "lt" ]]; then
    _wb_render_banner "$tool" "$local_check" "$latest" "$changelog" >&2
  fi
  return 0
}

_wb_record_prior() {
  local tool="$1"
  local clone
  clone="$(_wb_clone_path "$tool")"
  [[ -z "$clone" || ! -d "$clone/.git" ]] && return 1
  local sha v ts d p
  sha="$(git -C "$clone" rev-parse HEAD 2>/dev/null)" || return 1
  v="$(_wb_local_version "$tool")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  d="${WB_UPDATES_CACHE_DIR:-${HOME}/.cache/wb-updates}"
  mkdir -p "$d"
  p="$d/${tool}-prior.json"
  jq -n --arg tool "$tool" --arg sha "$sha" --arg v "$v" --arg ts "$ts" \
    '{tool:$tool, prior_sha:$sha, prior_version:$v, current_sha:null, current_version:null, upgraded_at:$ts}' > "$p"
}
