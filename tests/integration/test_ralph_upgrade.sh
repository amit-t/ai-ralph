#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
UPGRADE="${REPO_ROOT}/ralph-upgrade.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

upstream="$scratch/upstream.git"
clone="$scratch/clone"
"${REPO_ROOT}/tests/fixtures/bare-upstream/setup.sh" "$upstream" "1.0.0"
git clone -q "$upstream" "$clone"

# Bump upstream
work="$(mktemp -d)"
git clone -q "$upstream" "$work"
printf '{"version":"1.1.0","check_ttl_hours":12,"channel":"stable","requires":{},"changelog_url":"x"}\n' > "$work/version.json"
git -C "$work" -c user.email=t@t -c user.name=t commit -aq -m "bump"
git -C "$work" push -q origin main

RALPH_CLONE="$clone" \
  WB_UPDATES_CACHE_DIR="$scratch/cache" \
  bash "$UPGRADE" --yes --skip-install || { printf "FAIL: upgrade returned non-zero\n" >&2; exit 1; }

new_v="$(jq -r .version "$clone/version.json")"
[[ "$new_v" == "1.1.0" ]] || { printf "FAIL: clone not on 1.1.0 (got %s)\n" "$new_v" >&2; exit 1; }
[[ -f "$scratch/cache/ralph-prior.json" ]] || { printf "FAIL: prior cache not written\n" >&2; exit 1; }

# Rollback
RALPH_CLONE="$clone" \
  WB_UPDATES_CACHE_DIR="$scratch/cache" \
  bash "$UPGRADE" --rollback --skip-install
v="$(jq -r .version "$clone/version.json")"
[[ "$v" == "1.0.0" ]] || { printf "FAIL: rollback did not restore 1.0.0 (got %s)\n" "$v" >&2; exit 1; }

# Dirty refusal
clone2="$scratch/clone2"
"${REPO_ROOT}/tests/fixtures/bare-upstream/setup.sh" "$scratch/upstream2.git" "1.0.0"
git clone -q "$scratch/upstream2.git" "$clone2"
echo dirty > "$clone2/dirty.txt"
set +e
RALPH_CLONE="$clone2" WB_UPDATES_CACHE_DIR="$scratch/cache2" bash "$UPGRADE" --yes --skip-install
rc=$?
set -e
[[ "$rc" -eq 2 ]] || { printf "FAIL: expected exit 2 on dirty tree, got %s\n" "$rc" >&2; exit 1; }

# Non-main refusal
clone3="$scratch/clone3"
"${REPO_ROOT}/tests/fixtures/bare-upstream/setup.sh" "$scratch/upstream3.git" "1.0.0"
git clone -q "$scratch/upstream3.git" "$clone3"
git -C "$clone3" checkout -qb feature
set +e
RALPH_CLONE="$clone3" WB_UPDATES_CACHE_DIR="$scratch/cache3" bash "$UPGRADE" --yes --skip-install
rc=$?
set -e
[[ "$rc" -eq 2 ]] || { printf "FAIL: expected exit 2 on feature branch, got %s\n" "$rc" >&2; exit 1; }

# Peer-requires block (devkit floor)
clone4="$scratch/clone4"
devkit_clone="$scratch/devkit"
"${REPO_ROOT}/tests/fixtures/bare-upstream/setup.sh" "$scratch/upstream4.git" "1.0.0"
git clone -q "$scratch/upstream4.git" "$clone4"
mkdir -p "$devkit_clone"
printf '{"version":"0.5.0"}\n' > "$devkit_clone/version.json"
work4="$(mktemp -d)"
git clone -q "$scratch/upstream4.git" "$work4"
printf '{"version":"1.1.0","check_ttl_hours":12,"channel":"stable","requires":{"devkit":">=1.0.0"},"changelog_url":"x"}\n' > "$work4/version.json"
git -C "$work4" -c user.email=t@t -c user.name=t commit -aq -m "bump"
git -C "$work4" push -q origin main
set +e
RALPH_CLONE="$clone4" DEVKIT_CLONE="$devkit_clone" WB_UPDATES_CACHE_DIR="$scratch/cache4" bash "$UPGRADE" --yes --skip-install
rc=$?
set -e
[[ "$rc" -eq 3 ]] || { printf "FAIL: expected exit 3 on peer-floor block, got %s\n" "$rc" >&2; exit 1; }

# --force bypass
RALPH_CLONE="$clone4" DEVKIT_CLONE="$devkit_clone" WB_UPDATES_CACHE_DIR="$scratch/cache4" bash "$UPGRADE" --yes --force --skip-install

printf "PASS: test_ralph_upgrade\n"
