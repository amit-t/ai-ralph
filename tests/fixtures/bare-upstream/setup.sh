#!/usr/bin/env bash
set -euo pipefail
out="$1"
ver="${2:-1.4.0}"
mkdir -p "$out"
work="$(mktemp -d)"
trap "rm -rf '$work'" EXIT
git -C "$work" init -q -b main
printf '{"version":"%s","released":"2026-05-09","check_ttl_hours":12,"channel":"stable","requires":{},"changelog_url":"https://example.com"}\n' "$ver" > "$work/version.json"
git -C "$work" -c user.email=t@t -c user.name=t add version.json
git -C "$work" -c user.email=t@t -c user.name=t commit -q -m "init"
git -C "$work" push -q --mirror "$out"
