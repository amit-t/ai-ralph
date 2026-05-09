#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
. "${REPO_ROOT}/lib/version-check.sh"

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" != "$want" ]]; then
    printf "FAIL: %s — got '%s', want '%s'\n" "$msg" "$got" "$want" >&2
    exit 1
  fi
}

# semver
assert_eq "$(_wb_compare_semver 1.0.0 1.0.1)" "lt" "1.0.0 < 1.0.1"
assert_eq "$(_wb_compare_semver 1.10.0 1.2.3)" "gt" "1.10.0 > 1.2.3"
assert_eq "$(_wb_compare_semver 1.0.0 1.0.0)" "eq" "1.0.0 == 1.0.0"

# requires
assert_eq "$(_wb_check_requires '>=1.2.0' '1.2.0')" "ok" "constraint pass"
assert_eq "$(_wb_check_requires '>=1.2.0' '1.1.9')" "fail" "constraint fail"

# clone path
( export RALPH_CLONE=/tmp/fake-ralph; assert_eq "$(_wb_clone_path ralph)" "/tmp/fake-ralph" "RALPH_CLONE wins" )

# local_version
fixture="$(mktemp -d)"
trap "rm -rf '$fixture'" EXIT
printf '{"version":"1.2.3"}\n' > "$fixture/version.json"
( export RALPH_CLONE="$fixture"; assert_eq "$(_wb_local_version ralph)" "1.2.3" "local version read" )

# cache TTL
cachedir="$(mktemp -d)"
trap "rm -rf '$fixture' '$cachedir'" EXIT
WB_UPDATES_CACHE_DIR="$cachedir"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$cachedir/ralph.json" <<JSON
{"tool":"ralph","checked_at":"$ts","ttl_hours":12,"upstream":{"version":"1.4.0"}}
JSON
assert_eq "$(_wb_cache_is_fresh ralph)" "fresh" "fresh cache"

cat > "$cachedir/ralph.json" <<'JSON'
{"tool":"ralph","checked_at":"1970-01-01T00:00:00Z","ttl_hours":12,"upstream":{"version":"1.4.0"}}
JSON
assert_eq "$(_wb_cache_is_fresh ralph)" "stale" "stale cache"

# render_banner
out="$(_wb_render_banner ralph 1.2.3 1.4.0 https://example.com/changelog)"
case "$out" in
  *"update 1.4.0 available"*) ;;
  *) printf "FAIL: banner missing 'update 1.4.0 available' — got '%s'\n" "$out" >&2; exit 1 ;;
esac

printf "PASS: test_versioncheck\n"
