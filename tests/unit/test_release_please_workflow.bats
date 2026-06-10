#!/usr/bin/env bats

@test "release-please only runs in origin repository" {
  repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  origin_url="$(git -C "$repo_root" remote get-url origin)"
  repo_name="${origin_url##*/}"
  repo_name="${repo_name%.git}"
  workflow="$repo_root/.github/workflows/release-please.yml"
  expected="    if: github.repository == 'amit-t/${repo_name}'"

  [ -f "$workflow" ]
  run grep -Fx "$expected" "$workflow"
  [ "$status" -eq 0 ]
}
