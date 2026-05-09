#!/usr/bin/env bash
gh() {
  if [[ "${GH_SHIM_FAIL:-0}" == "1" ]]; then return 1; fi
  local key
  key="$(printf '%s|' "$@" | md5sum | cut -c1-32)" 2>/dev/null \
   || key="$(printf '%s|' "$@" | shasum | cut -c1-32)"
  local path="${GH_SHIM_RESPONSES_DIR:-/tmp/gh-shim}/$key.json"
  if [[ -f "$path" ]]; then cat "$path"; return 0; fi
  return 1
}
export -f gh 2>/dev/null || true
