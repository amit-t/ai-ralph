#!/usr/bin/env bash
# pr_manager.sh — PR lifecycle management for Ralph (all variants)
# Provides: pr_preflight_check, pr_build_title, pr_build_description,
#           worktree_commit_and_pr, worktree_fallback_branch_pr
#
# Prerequisites: sourced AFTER worktree_manager.sh and .ralphrc in each loop script.
# Globals read from environment:
#   _WT_CURRENT_PATH, _WT_CURRENT_BRANCH, _WT_MAIN_DIR  (from worktree_manager.sh)
#   RALPH_DIR, RALPH_ENGINE                              (from loop script)
#   PR_ENABLED, PR_BASE_BRANCH, PR_DRAFT                 (from .ralphrc)
#   MAX_QG_RETRIES                                       (from .ralphrc)
#
# Globals set by this library:
#   RALPH_PR_PUSH_CAPABLE=true|false
#   RALPH_PR_GH_CAPABLE=true|false

# Default exports
RALPH_PR_PUSH_CAPABLE="${RALPH_PR_PUSH_CAPABLE:-false}"
RALPH_PR_GH_CAPABLE="${RALPH_PR_GH_CAPABLE:-false}"

# ── Helpers ───────────────────────────────────────────────────────────────────

_pr_warn_block() {
    local reason="$1"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  WARNING: PR CREATION DISABLED                       ║"
    # reason must be ≤35 chars to fit the box; callers must enforce this
    echo "║  Reason: ${reason}$(printf '%*s' $((37 - ${#reason})) '')║"
    echo "║  Ralph will commit and push branches only.           ║"
    echo "╚══════════════════════════════════════════════════════╝"
}

# ── gh multi-account fallback ───────────────────────────────────────────────────
# Amit (and others) commonly keep more than one gh account logged in, and a given
# repo is usually accessible by only ONE of them. git push uses SSH keys, but gh
# API calls use whichever account is *active*. If the active account lacks repo
# access, the gh call 404s. These helpers retry a gh command across every
# logged-in account, then restore the original active account.
#
# NOTE: `gh auth switch` mutates GLOBAL gh state (shared by the user's shell and
# any --parallel workers). We restore the original active account in all paths to
# keep that window small; a true per-process selection is not exposed by gh.

# List all logged-in gh usernames (active first if discoverable).
_pr_gh_accounts() {
    gh auth status 2>/dev/null \
        | grep -oE 'account [A-Za-z0-9_-]+' \
        | awk '{print $2}'
}

# Current active gh username (empty if none/unknown).
_pr_gh_active_account() {
    gh auth status --active 2>/dev/null \
        | grep -oE 'account [A-Za-z0-9_-]+' \
        | awk '{print $2; exit}'
}

# Heuristic: does this gh stderr look like an access/auth problem worth retrying
# under a different account (vs. a real error we should surface immediately)?
_pr_gh_access_error() {
    grep -qiE 'not accessible|HTTP 40[34]|404|not found|no longer access|must have|permission|not authorized|Could not resolve to a (Repository|User)|authentication|gh auth login' <<<"$1"
}

# Run a gh command, retrying across logged-in accounts on access/auth failure.
# Usage: _pr_gh_try <gh-args...>
# Prints gh's combined output (success URL or failure error) to STDOUT and
# returns gh's rc. Callers capture with $(...) — NO 2>&1 needed; progress logs
# go to stderr (via log_status) and never pollute the captured value.
# Always restores the original active account.
_pr_gh_try() {
    local original active out rc=1
    original=$(_pr_gh_active_account)

    # Build account order: active first, then the rest.
    local -a accts=()
    [[ -n "$original" ]] && accts+=("$original")
    local a
    while IFS= read -r a; do
        [[ -n "$a" && "$a" != "$original" ]] && accts+=("$a")
    done < <(_pr_gh_accounts)

    # No accounts discoverable — just run gh as-is.
    if [[ ${#accts[@]} -eq 0 ]]; then
        out=$(gh "$@" 2>&1); rc=$?
        printf '%s\n' "$out"
        return $rc
    fi

    local acct
    for acct in "${accts[@]}"; do
        if [[ "$acct" != "$(_pr_gh_active_account)" ]]; then
            if ! gh auth switch -u "$acct" >/dev/null 2>&1; then
                continue
            fi
            log_status "INFO" "PR: trying gh as account '$acct'"
        fi
        if out=$(gh "$@" 2>&1); then
            rc=0
            [[ "$acct" != "$original" ]] && log_status "INFO" "PR: gh succeeded as account '$acct'"
            break
        else
            # Capture gh's rc here (inside else); reading $? after `fi` would yield
            # the if-statement's own 0 and mask the failure.
            rc=$?
        fi
        # Stop early on a non-access error (real failure) — don't shop accounts.
        if ! _pr_gh_access_error "$out"; then
            break
        fi
        log_status "WARN" "PR: account '$acct' cannot access repo — trying next account"
    done

    # Restore original active account (best effort).
    if [[ -n "$original" && "$original" != "$(_pr_gh_active_account)" ]]; then
        gh auth switch -u "$original" >/dev/null 2>&1 || true
    fi

    printf '%s\n' "$out"
    return $rc
}

# ── _pr_lookup_existing_pr ────────────────────────────────────────────────────
# Args: $1=branch. Prints the existing PR's URL and returns 0 ONLY when a PR
# exists. _pr_gh_try merges gh's stderr into its stdout, so "no pull requests
# found" error text arrives on stdout — callers must never treat non-empty
# output alone as proof of a PR. Gate on BOTH rc==0 and URL shape.
_pr_lookup_existing_pr() {
    local branch="$1"
    local out
    if out=$(_pr_gh_try pr view "$branch" --json url --jq '.url') \
       && [[ "$out" =~ ^https?:// ]]; then
        printf '%s\n' "$out"
        return 0
    fi
    return 1
}

# ── _pr_ensure_label ──────────────────────────────────────────────────────────
# Ensures a GitHub label exists in the repo, creating it if missing.
# Args: $1=label_name  $2=color (hex without #, default: "d93f0b")
#       $3=description (optional)
# Returns: 0 if label exists or was created; 1 on failure.
_pr_ensure_label() {
    local label_name="$1"
    local color="${2:-d93f0b}"
    local description="${3:-}"

    # Check if label already exists
    if gh label list --limit 200 2>/dev/null | grep -qF "$label_name"; then
        return 0
    fi

    # Create the label
    local create_args=(--name "$label_name" --color "$color")
    [[ -n "$description" ]] && create_args+=(--description "$description")
    if gh label create "${create_args[@]}" 2>/dev/null; then
        log_status "INFO" "Created label '$label_name' in repo"
        return 0
    fi
    return 1
}

# ── _pr_log_task_state ────────────────────────────────────────────────────────
# One canonical, grep-able line summarising the PR workflow outcome.
# Args: $1=branch $2=gates $3=rebase $4=pushed $5=pr $6=label
_pr_log_task_state() {
    log_status "INFO" "task-state branch=$1 quality_gates=$2 rebase=$3 pushed=$4 pr=$5 failure_label=$6"
}

# ── _pr_remote_to_web_url ────────────────────────────────────────────────────
# Normalises git remote URL → HTTPS web base URL for browser links.
# Handles HTTPS, SSH (git@), and embedded credentials in URL.
# Prints web URL to stdout (no trailing slash, no .git). Returns 1 if remote
# is unavailable or URL cannot be determined.
_pr_remote_to_web_url() {
    local url
    url=$(git remote get-url origin 2>/dev/null) || { echo ""; return 1; }
    [[ -z "$url" ]] && { echo ""; return 1; }

    # SSH: git@github.com:owner/repo.git → https://github.com/owner/repo
    if [[ "$url" =~ ^git@ ]]; then
        url="${url#git@}"      # drop "git@"
        url="${url/://}"       # replace first ":" with "/"
        url="https://${url}"
    fi

    # Strip embedded credentials (https://token@host/... → https://host/...)
    url=$(printf '%s' "$url" | sed 's|https://[^@]*@|https://|')

    # Strip .git suffix and trailing slash
    url="${url%.git}"
    url="${url%/}"

    echo "$url"
    return 0
}

# ── _pr_print_compare_url ────────────────────────────────────────────────────
# Prints a clickable GitHub compare URL so the user can open a PR in the browser.
# No-op if the remote URL cannot be determined.
# Args: $1=branch  $2=base_branch
_pr_print_compare_url() {
    local branch="$1"
    local base_branch="$2"
    local web_url
    web_url=$(_pr_remote_to_web_url) || return 0
    [[ -z "$web_url" ]] && return 0

    local compare_url="${web_url}/compare/${base_branch}...${branch}?expand=1"
    log_status "INFO" "Open in browser to create PR → $compare_url"
    echo ""
    echo "  Open to create PR → $compare_url"
    echo ""
    return 0
}

# ── _pr_require_committable_source_diff ──────────────────────────────────────
# Blocks empty / artifact-only PR branches. Ralph may write .ralph artifacts such
# as .ralph/.quality_gate_results after an agent run; those files are not proof
# of source work and must not be pushed as a phantom PR.
_pr_resolve_base_ref() {
    local base_branch="${1:-main}"

    if git rev-parse --verify --quiet "$base_branch" >/dev/null 2>&1; then
        echo "$base_branch"
        return 0
    fi
    if git rev-parse --verify --quiet "origin/$base_branch" >/dev/null 2>&1; then
        echo "origin/$base_branch"
        return 0
    fi
    if git rev-parse --verify --quiet "refs/remotes/origin/$base_branch" >/dev/null 2>&1; then
        echo "refs/remotes/origin/$base_branch"
        return 0
    fi

    return 1
}

_pr_has_committable_source_diff() {
    local base_branch="${1:-main}"
    local base_ref diff_names

    if base_ref=$(_pr_resolve_base_ref "$base_branch"); then
        diff_names=$(git diff --name-only "$base_ref...HEAD" -- . ':(exclude).ralph/**' 2>/dev/null || true)
    else
        # Last-resort guard for tests or unusual repos without a local base ref:
        # still rejects artifact-only HEAD commits.
        diff_names=$(git diff-tree --no-commit-id --name-only -r HEAD -- . ':(exclude).ralph/**' 2>/dev/null || true)
    fi

    [[ -n "$diff_names" ]]
}

_pr_require_committable_source_diff() {
    local base_branch="${1:-main}"
    local branch_name="$2"

    if _pr_has_committable_source_diff "$base_branch"; then
        return 0
    fi

    local message="worker produced no committable source diff; check for denied commit commands (branch: ${branch_name:-unknown}, base: $base_branch)"
    echo "$message" >&2
    log_status "ERROR" "$message"
    return 1
}

# ── _pr_confirm_remote_branch ─────────────────────────────────────────────────
# After a push, the branch ref can take a moment to become visible on the remote.
# gh pr create then fails with "Head sha cannot be blank" / "No commits between".
# Poll `git ls-remote` until the ref appears. Must run from inside the repo dir.
# Args: $1=branch
# Env:  PR_LS_REMOTE_RETRIES (default 5), PR_LS_REMOTE_DELAY seconds (default 2)
# Returns 0 if confirmed; 1 if not confirmed after exhausting retries (caller
# still proceeds — gh surfaces the authoritative error).
_pr_confirm_remote_branch() {
    local branch="$1"
    local max="${PR_LS_REMOTE_RETRIES:-5}"
    local delay="${PR_LS_REMOTE_DELAY:-2}"
    local attempt=1
    while (( attempt <= max )); do
        if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
            return 0
        fi
        (( attempt < max )) && [[ "$delay" != "0" ]] && sleep "$delay"
        (( attempt++ ))
    done
    log_status "WARN" "Remote ref refs/heads/$branch not visible after $max attempt(s); proceeding to gh pr create"
    return 1
}

# ── _pr_commits_ahead ─────────────────────────────────────────────────────────
# Number of commits BRANCH has beyond origin/BASE. Empty string if origin/BASE is
# unknown (never fetched) — callers must treat empty as "unknown", NOT zero, so a
# missing base ref never blocks PR creation. Must run from inside the repo dir.
# Args: $1=base_branch  $2=branch
_pr_commits_ahead() {
    local base="$1" branch="$2"
    git rev-list --count "origin/${base}..${branch}" 2>/dev/null
}

# ── _pr_restore_ralph_snapshot ────────────────────────────────────────────────
# Restore .ralph/** file contents snapshotted before a rebase, then delete the
# snapshot dir. $1="" is a no-op. Always returns 0.
_pr_restore_ralph_snapshot() {
    local snapshot_dir="$1"
    [[ -z "$snapshot_dir" || ! -d "$snapshot_dir" ]] && return 0
    cp -pR "$snapshot_dir/." . 2>/dev/null || true
    rm -rf "$snapshot_dir" 2>/dev/null || true
    return 0
}

# ── _pr_rebase_onto_base ──────────────────────────────────────────────────────
# Rebase the branch checked out in the CURRENT working tree onto origin/BASE.
# Must run from inside the working tree that holds the branch.
# Args: $1=base_branch
# Prints exactly one status word and returns:
#   CHANGED   rc 0  tip moved (caller re-runs quality gates)
#   UNCHANGED rc 0  already up to date
#   SKIPPED   rc 0  no remote base ref
#   DIRTY     rc 2  uncommitted tracked changes outside .ralph/ — NOT a conflict
#   CONFLICT  rc 1  real merge conflict (aborted unless the
#                   worktree_resolve_rebase_conflicts hook resolved it)
#   FAILED    rc 3  rebase failed before producing conflict state
# Dirty tracked .ralph/** files (gate results are written after the
# auto-commit, which excludes .ralph/**, and some target repos track .ralph/)
# are snapshotted, reset to HEAD for the rebase, and restored afterwards.
_pr_rebase_onto_base() {
    local base_branch="$1"

    if ! git fetch origin "$base_branch" >/dev/null 2>&1; then
        echo "SKIPPED"; return 0
    fi
    if ! git rev-parse --verify --quiet "refs/remotes/origin/$base_branch" >/dev/null 2>&1; then
        echo "SKIPPED"; return 0
    fi

    local -a ralph_dirty=() other_dirty=()
    local _f
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        if [[ "$_f" == .ralph/* ]]; then
            ralph_dirty+=("$_f")
        else
            other_dirty+=("$_f")
        fi
    done < <(git diff --name-only HEAD -- 2>/dev/null)

    if [[ ${#other_dirty[@]} -gt 0 ]]; then
        log_status "ERROR" "Rebase blocked by uncommitted tracked changes (not a merge conflict): ${other_dirty[*]}"
        echo "DIRTY"
        return 2
    fi

    local snapshot_dir=""
    if [[ ${#ralph_dirty[@]} -gt 0 ]]; then
        snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/ralph-rebase-snap.XXXXXX")
        for _f in "${ralph_dirty[@]}"; do
            mkdir -p "$snapshot_dir/$(dirname "$_f")"
            cp -p "$_f" "$snapshot_dir/$_f" 2>/dev/null || true
        done
        git checkout HEAD -- "${ralph_dirty[@]}" 2>/dev/null || true
        log_status "INFO" "Stashed dirty tracked ralph artifacts for rebase: ${ralph_dirty[*]}"
    fi

    local before after rebase_out rebase_rc=0
    before=$(git rev-parse HEAD 2>/dev/null)
    rebase_out=$(git rebase "origin/$base_branch" 2>&1) || rebase_rc=$?

    if [[ $rebase_rc -ne 0 ]]; then
        local git_dir status_word="FAILED" status_rc=3
        git_dir=$(git rev-parse --git-dir 2>/dev/null)
        log_status "ERROR" "git rebase origin/$base_branch failed (rc=$rebase_rc): $rebase_out"
        if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
            status_word="CONFLICT"; status_rc=1
            log_status "ERROR" "Conflicted files: $(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
            log_status "ERROR" "Worktree status: $(git status --short 2>/dev/null | tr '\n' ';' )"
            if declare -F worktree_resolve_rebase_conflicts >/dev/null 2>&1 \
               && worktree_resolve_rebase_conflicts "$base_branch" 1>&2; then
                log_status "INFO" "Rebase conflict resolved by worktree_resolve_rebase_conflicts hook"
                status_word=""; status_rc=0
            else
                git rebase --abort >/dev/null 2>&1 || true
            fi
        fi
        if [[ $status_rc -ne 0 ]]; then
            _pr_restore_ralph_snapshot "$snapshot_dir"
            echo "$status_word"
            return $status_rc
        fi
    fi

    after=$(git rev-parse HEAD 2>/dev/null)
    _pr_restore_ralph_snapshot "$snapshot_dir"

    if [[ "$before" != "$after" ]]; then
        echo "CHANGED"
    else
        echo "UNCHANGED"
    fi
    return 0
}

# ── pr_preflight_check ────────────────────────────────────────────────────────
# Check git remote, gh CLI, gh auth. Sets RALPH_PR_PUSH_CAPABLE and
# RALPH_PR_GH_CAPABLE. Always returns 0.
pr_preflight_check() {
    RALPH_PR_PUSH_CAPABLE="true"
    RALPH_PR_GH_CAPABLE="true"

    # Check 1: git origin remote URL exists
    if ! git remote get-url origin &>/dev/null; then
        _pr_warn_block "No git remote named 'origin'"
        log_status "WARN" "PR: No git remote 'origin' — push and PR disabled"
        RALPH_PR_PUSH_CAPABLE="false"
        RALPH_PR_GH_CAPABLE="false"
        return 0
    fi

    # Check 1b: remote is actually reachable (catches missing SSH keys / bad
    # credentials). Retry to survive transient SSH flakes — a single blip must not
    # disable push/PR for the whole run. Use an explicit ConnectTimeout so a hung
    # handshake fails fast instead of stalling, and capture stderr so the real
    # reason is logged (the old &>/dev/null swallowed it).
    local _lsr_err="" _lsr_ok="false" _lsr_try
    for _lsr_try in 1 2 3; do
        if _lsr_err=$(GIT_SSH_COMMAND="ssh -o ConnectTimeout=10 -o BatchMode=yes" \
                      git ls-remote origin HEAD 2>&1); then
            _lsr_ok="true"
            break
        fi
        [[ $_lsr_try -lt 3 ]] && sleep $((_lsr_try * 2))
    done
    if [[ "$_lsr_ok" != "true" ]]; then
        log_status "WARN" "PR: Cannot reach remote 'origin' after 3 tries — push disabled"
        log_status "WARN" "    git ls-remote origin said: ${_lsr_err}"
        log_status "WARN" "    Check SSH keys or credentials: git ls-remote origin"
        RALPH_PR_PUSH_CAPABLE="false"
        # Do NOT disable gh here — gh capability is independent of the push probe
        # (different transport/account). Fall through to the gh checks below.
    fi

    # Check 2: gh CLI installed
    if ! command -v gh &>/dev/null; then
        log_status "WARN" "PR: gh CLI not found — will push branch and print compare URL"
        log_status "INFO" "    Install gh to enable automatic PR creation: https://cli.github.com"
        RALPH_PR_GH_CAPABLE="false"
        return 0
    fi

    # Check 3: gh authenticated
    if ! gh auth status &>/dev/null; then
        log_status "WARN" "PR: gh not authenticated — will push branch and print compare URL"
        log_status "INFO" "    Run 'gh auth login' to enable automatic PR creation"
        RALPH_PR_GH_CAPABLE="false"
        return 0
    fi

    log_status "INFO" "PR preflight: all checks passed (push=true, gh=true)"
    return 0
}

# ── pr_build_title ────────────────────────────────────────────────────────────
# Args: $1=task_id  $2=task_name
# Prints PR title to stdout. Always returns 0.
pr_build_title() {
    local task_id="$1"
    local task_name="$2"
    local title

    if [[ -n "$task_id" && -n "$task_name" ]]; then
        title="ralph: ${task_name} [${task_id}]"
    elif [[ -n "$task_id" ]]; then
        title="ralph: task [${task_id}]"
    else
        local branch
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        title="ralph: automated work [${branch}]"
    fi

    # Truncate to 72 chars: keep first 69, append "..."
    if [[ ${#title} -gt 72 ]]; then
        title="${title:0:69}..."
    fi

    echo "$title"
    return 0
}

# ── pr_build_description ──────────────────────────────────────────────────────
# Args: $1=task_id  $2=task_name  $3=branch  $4=gate_passed  $5=gate_results_file
#       $6=loop_count
# Prints Markdown PR body to stdout. Always returns 0.
pr_build_description() {
    local task_id="$1"
    local task_name="$2"
    local branch="$3"
    local gate_passed="$4"
    local gate_results_file="$5"
    local loop_count="$6"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local engine="${RALPH_ENGINE:-ralph}"

    # Summary section
    echo "## Summary"
    if [[ -n "$task_id" || -n "$task_name" ]]; then
        echo "Task: ${task_name:-unknown} (${task_id:-unknown})"
    fi
    echo "Branch: ${branch}"
    echo ""

    # Quality Gates section
    echo "## Quality Gates"
    if [[ -f "$gate_results_file" && -s "$gate_results_file" ]]; then
        echo "| Gate Command | Result |"
        echo "|---|---|"
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"   # ltrim
            line="${line%"${line##*[![:space:]]}"}"   # rtrim
            [[ -z "$line" ]] && continue
            if [[ "$line" == PASS:\ * ]]; then
                local cmd="${line#PASS: }"
                echo "| \`${cmd}\` | ✅ PASS |"
            elif [[ "$line" == FAIL:\ * ]]; then
                local rest="${line#FAIL: }"
                local cmd exit_code
                if [[ "$rest" =~ ^(.*)" (exit "([0-9]+)")" ]]; then
                    cmd="${BASH_REMATCH[1]}"
                    exit_code="${BASH_REMATCH[2]}"
                else
                    cmd="$rest"
                    exit_code="?"
                fi
                echo "| \`${cmd}\` | ❌ FAIL (exit ${exit_code}) |"
            else
                log_status "DEBUG" "Skipping unparseable gate result line: $line" 2>/dev/null || true
            fi
        done < "$gate_results_file"
    else
        echo "No quality gate data available."
    fi
    echo ""

    # Quality Gate Failures section (only when gates failed)
    if [[ "$gate_passed" == "false" ]]; then
        if [[ -f "$gate_results_file" && -s "$gate_results_file" ]]; then
            local has_failures=false
            while IFS= read -r line; do
                [[ "$line" == FAIL:\ * ]] && has_failures=true && break
            done < "$gate_results_file"

            if [[ "$has_failures" == "true" ]]; then
                echo "## Quality Gate Failures"
                echo "> ⚠️ The following gates failed and could not be resolved:"
                while IFS= read -r line; do
                    line="${line#"${line%%[![:space:]]*}"}"
                    [[ -z "$line" ]] && continue
                    if [[ "$line" == FAIL:\ * ]]; then
                        local rest="${line#FAIL: }"
                        local cmd exit_code
                        if [[ "$rest" =~ ^(.*)" (exit "([0-9]+)")" ]]; then
                            cmd="${BASH_REMATCH[1]}"
                            exit_code="${BASH_REMATCH[2]}"
                        else
                            cmd="$rest"; exit_code="?"
                        fi
                        echo "- \`${cmd}\` — exit code \`${exit_code}\`"
                    fi
                done < "$gate_results_file"
                echo ""
            fi
        fi
    fi

    echo "---"
    echo "🤖 Generated by Ralph [${engine}] loop #${loop_count} — ${timestamp}"

    # Append externally managed PR footer if present and non-empty.
    # Resolution: $WORKSPACE_ROOT/.ralph/pr_footer.md, else $(pwd)/.ralph/pr_footer.md.
    local footer_path
    if [[ -n "${WORKSPACE_ROOT:-}" ]]; then
        footer_path="$WORKSPACE_ROOT/.ralph/pr_footer.md"
    else
        footer_path=".ralph/pr_footer.md"
    fi
    if [[ -s "$footer_path" ]]; then
        echo ""
        cat "$footer_path"
    fi

    return 0
}

# ── worktree_commit_and_pr ────────────────────────────────────────────────────
# Commit work in current worktree, push branch, open PR.
# Args: $1=task_id  $2=task_name  $3=gate_passed("true"|"false")  $4=loop_count
# Returns: 0 on success or intentional skip; 1 on commit/push/PR failure.
worktree_commit_and_pr() {
    local task_id="$1"
    local task_name="$2"
    local gate_passed="$3"
    local loop_count="$4"

    # Honour PR_ENABLED=false — revert to old merge behaviour
    if [[ "${PR_ENABLED:-true}" == "false" ]]; then
        worktree_merge
        return $?
    fi

    # Resolve PR base branch
    local base_branch="${PR_BASE_BRANCH:-}"
    if [[ -z "$base_branch" ]]; then
        base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
                      | sed 's@^refs/remotes/origin/@@')
    fi
    if [[ -z "$base_branch" ]]; then
        base_branch="main"
    fi
    log_status "INFO" "PR base branch: $base_branch"
    local state_rebase="SKIPPED" state_pushed="false" state_pr="skipped" state_label="n/a"

    # ── Step 1: Auto-commit in worktree ──────────────────────────────────────
    # Exclude .ralph/ from the auto-commit: ralph internal state (e.g.
    # .ralph/.quality_gate_results) is not source work and must never become a
    # commit of its own on top of already-committed real work, nor ride along in
    # a PR. If nothing but .ralph/ changed, skip the commit entirely.
    (
        cd "$_WT_CURRENT_PATH" || { log_status "ERROR" "Cannot cd to worktree: $_WT_CURRENT_PATH"; exit 1; }
        if [[ -n "$(git status --porcelain -- . ':(exclude).ralph/**' 2>/dev/null)" ]]; then
            if ! git add -A -- . ':(exclude).ralph/**'; then
                log_status "ERROR" "git add failed in worktree $_WT_CURRENT_PATH"
                exit 1
            fi
            if ! git commit -m "ralph-${RALPH_ENGINE:-ralph}: auto-commit run #${loop_count}"; then
                log_status "ERROR" "Commit failed in worktree $_WT_CURRENT_PATH"
                exit 1
            fi
            log_status "INFO" "Changes committed to $_WT_CURRENT_BRANCH"
        else
            log_status "INFO" "Nothing but ralph internal state to commit — proceeding to push"
        fi
    )
    local commit_result=$?
    if [[ $commit_result -ne 0 ]]; then
        _pr_log_task_state "$_WT_CURRENT_BRANCH" "$gate_passed" "$state_rebase" "$state_pushed" "$state_pr" "$state_label"
        return 1
    fi

    # ── Step 1b: Ensure branch contains real source diff before push/PR ─────
    if [[ "$RALPH_PR_PUSH_CAPABLE" == "true" ]]; then
        (
            cd "$_WT_CURRENT_PATH" || exit 1
            _pr_require_committable_source_diff "$base_branch" "$_WT_CURRENT_BRANCH"
        )
        local diff_result=$?
        if [[ $diff_result -ne 0 ]]; then
            _pr_log_task_state "$_WT_CURRENT_BRANCH" "$gate_passed" "$state_rebase" "$state_pushed" "$state_pr" "$state_label"
            return 1
        fi
    fi

    # ── Step 1c: Rebase onto advanced base ───────────────────────────────────
    # If an earlier task merged into the base while this run was working, rebase
    # the branch onto the new base so it stays mergeable. The branch is checked
    # out in the worktree, so the rebase must run there. On conflict, stop rather
    # than push an unmergeable branch. If the rebase moved the tip, re-run the
    # quality gates against the new base.
    if [[ "$RALPH_PR_PUSH_CAPABLE" == "true" ]]; then
        local rebase_status
        rebase_status=$(
            cd "$_WT_CURRENT_PATH" || exit 2
            _pr_rebase_onto_base "$base_branch"
        )
        local rebase_rc=$?
        state_rebase="${rebase_status:-FAILED}"
        if [[ $rebase_rc -ne 0 ]]; then
            case "$rebase_status" in
                DIRTY)
                    log_status "ERROR" "Rebase of $_WT_CURRENT_BRANCH blocked by uncommitted tracked changes (see log above) — not a merge conflict" ;;
                CONFLICT)
                    log_status "ERROR" "Rebase of $_WT_CURRENT_BRANCH onto origin/$base_branch hit a real merge conflict — conflicted files logged above; resolve in $_WT_CURRENT_PATH and re-run" ;;
                *)
                    log_status "ERROR" "Rebase of $_WT_CURRENT_BRANCH onto origin/$base_branch failed — git output logged above" ;;
            esac
            _pr_log_task_state "$_WT_CURRENT_BRANCH" "$gate_passed" "$state_rebase" "$state_pushed" "$state_pr" "$state_label"
            return 1
        fi
        if [[ "$rebase_status" == "CHANGED" ]]; then
            log_status "INFO" "Rebased $_WT_CURRENT_BRANCH onto advanced origin/$base_branch — re-running quality gates"
            if declare -F worktree_run_quality_gates >/dev/null 2>&1; then
                if worktree_run_quality_gates; then
                    gate_passed="true"
                else
                    gate_passed="false"
                    log_status "WARN" "Quality gates failed after rebase onto origin/$base_branch"
                fi
            fi
        fi
    fi

    # ── Step 2: Push branch ──────────────────────────────────────────────────
    if [[ "$RALPH_PR_PUSH_CAPABLE" != "true" ]]; then
        log_status "WARN" "Push skipped — no git remote. Branch: $_WT_CURRENT_BRANCH"
    else
        (
            cd "$_WT_MAIN_DIR" || exit 1
            # Fix B: a stale same-named remote branch from a previous dispatch
            # causes a non-fast-forward rejection. For ralph-owned branches only
            # (ralph-*/...) we own the branch, so fetch its remote tip to give
            # --force-with-lease an accurate view, then force-with-lease. This
            # overwrites our own stale branch while preserving any open PR, and
            # refuses if someone else advanced it. The base branch is never
            # force-pushed (only the feature branch is ever pushed here).
            if [[ "$_WT_CURRENT_BRANCH" == ralph-*/* ]]; then
                git fetch origin "$_WT_CURRENT_BRANCH" >/dev/null 2>&1 || true
                if ! git push origin "$_WT_CURRENT_BRANCH" --set-upstream --force-with-lease; then
                    log_status "ERROR" "Push failed for $_WT_CURRENT_BRANCH — check credentials/remote"
                    exit 1
                fi
            else
                if ! git push origin "$_WT_CURRENT_BRANCH" --set-upstream; then
                    log_status "ERROR" "Push failed for $_WT_CURRENT_BRANCH — check credentials/remote"
                    exit 1
                fi
            fi
            log_status "SUCCESS" "Branch pushed: $_WT_CURRENT_BRANCH"
        )
        local push_result=$?
        if [[ $push_result -ne 0 ]]; then
            _pr_log_task_state "$_WT_CURRENT_BRANCH" "$gate_passed" "$state_rebase" "$state_pushed" "$state_pr" "$state_label"
            return 1
        fi
        state_pushed="true"
    fi

    # ── Step 3: Create PR ────────────────────────────────────────────────────
    # All gh calls MUST run from inside the repo that holds the branch
    # (_WT_MAIN_DIR, where the push happened). Run from ralph's ambient cwd and
    # gh resolves --head against the wrong repo → blank head sha. Use pushd/popd
    # (not a subshell) so a mocked gh in tests can still set caller-side vars.
    if [[ "$RALPH_PR_GH_CAPABLE" == "true" && "$RALPH_PR_PUSH_CAPABLE" == "true" ]]; then
        if ! pushd "$_WT_MAIN_DIR" >/dev/null 2>&1; then
            log_status "ERROR" "Cannot enter repo dir for PR: $_WT_MAIN_DIR"
            _pr_log_task_state "$_WT_CURRENT_BRANCH" "$gate_passed" "$state_rebase" "$state_pushed" "$state_pr" "$state_label"
            return 1
        fi

        local existing_pr
        if existing_pr=$(_pr_lookup_existing_pr "$_WT_CURRENT_BRANCH"); then
            log_status "INFO" "PR already exists for $_WT_CURRENT_BRANCH: $existing_pr. Skipping creation."
            state_pr="exists"
        else
            # Confirm the pushed branch is visible on origin before asking gh to
            # open a PR (absorbs remote propagation lag).
            _pr_confirm_remote_branch "$_WT_CURRENT_BRANCH" || true

            # Never call gh with zero commits — that is the "No commits between"
            # GraphQL failure. Skip cleanly. Empty count = base ref unknown =
            # proceed (let gh decide).
            local commits_ahead
            commits_ahead=$(_pr_commits_ahead "$base_branch" "$_WT_CURRENT_BRANCH")
            if [[ "$commits_ahead" == "0" ]]; then
                log_status "WARN" "No commits to PR for $_WT_CURRENT_BRANCH (origin/$base_branch..$_WT_CURRENT_BRANCH empty) — skipping PR creation"
                popd >/dev/null 2>&1 || true
                _pr_log_task_state "$_WT_CURRENT_BRANCH" "$gate_passed" "$state_rebase" "$state_pushed" "$state_pr" "$state_label"
                return 0
            fi

            local pr_title pr_body
            pr_title=$(pr_build_title "$task_id" "$task_name")
            pr_body=$(pr_build_description "$task_id" "$task_name" "$_WT_CURRENT_BRANCH" \
                      "$gate_passed" "$_WT_CURRENT_PATH/.ralph/.quality_gate_results" "$loop_count")

            local gh_args=(--base "$base_branch" --head "$_WT_CURRENT_BRANCH" \
                           --title "$pr_title" --body "$pr_body")
            [[ "${PR_DRAFT:-false}" == "true" ]] && gh_args+=(--draft)

            local pr_url
            if ! pr_url=$(_pr_gh_try pr create "${gh_args[@]}"); then
                # Surface gh's stderr verbatim and keep the pushed branch so it
                # can be PR'd by hand.
                log_status "ERROR" "PR creation failed for $_WT_CURRENT_BRANCH: $pr_url"
                log_status "ERROR" "Branch is pushed — open by hand: gh pr create --head $_WT_CURRENT_BRANCH --base $base_branch"
                popd >/dev/null 2>&1 || true
                state_pr="failed"
                _pr_log_task_state "$_WT_CURRENT_BRANCH" "$gate_passed" "$state_rebase" "$state_pushed" "$state_pr" "$state_label"
                return 1
            fi
            log_status "SUCCESS" "PR created: $pr_url"
            state_pr="created"
        fi

        # ── Step 4: Add failure label (still inside repo dir) ─────────────────
        if [[ "$gate_passed" == "false" ]]; then
            _pr_ensure_label "quality-gates-failed" "d93f0b" "Ralph: quality gates did not pass" || true
            local label_out
            state_label="applied"
            if ! label_out=$(gh pr edit "$_WT_CURRENT_BRANCH" --add-label "quality-gates-failed" 2>&1); then
                state_label="failed"
                log_status "WARN" "Could not add 'quality-gates-failed' label to PR: $label_out"
            fi
        fi

        popd >/dev/null 2>&1 || true
    else
        log_status "INFO" "gh not available — branch pushed: $_WT_CURRENT_BRANCH"
        _pr_print_compare_url "$_WT_CURRENT_BRANCH" "$base_branch"
    fi

    _pr_log_task_state "$_WT_CURRENT_BRANCH" "$gate_passed" "$state_rebase" "$state_pushed" "$state_pr" "$state_label"
    return 0
}

# ── worktree_fallback_branch_pr ───────────────────────────────────────────────
# Used when WORKTREE_ENABLED=false. Creates a temp branch, commits, pushes, opens PR.
# Args: $1=task_id  $2=task_name  $3=loop_count  $4=gate_passed("true"|"false")
# Returns: 0 on success or intentional skip; 1 on failure.
worktree_fallback_branch_pr() {
    local task_id="$1"
    local task_name="$2"
    local loop_count="$3"
    local gate_passed="${4:-true}"
    local engine="${RALPH_ENGINE:-ralph}"
    local FALLBACK_BRANCH
    FALLBACK_BRANCH="ralph-${engine}/${task_id:-run}-$(date +%s)"

    # Honour PR_ENABLED=false
    if [[ "${PR_ENABLED:-true}" == "false" ]]; then
        log_status "INFO" "PR_ENABLED=false — skipping fallback branch PR"
        return 0
    fi

    # ── Step 1: Stash uncommitted changes ────────────────────────────────────
    local stash_was_empty=false
    local stash_output
    stash_output=$(git stash 2>&1)
    local stash_exit=$?
    if echo "$stash_output" | grep -q "No local changes to save"; then
        stash_was_empty=true
    elif [[ $stash_exit -ne 0 ]]; then
        log_status "ERROR" "git stash failed (exit $stash_exit): $stash_output"
        return 1
    fi

    # ── Step 2: Create and checkout fallback branch ──────────────────────────
    local original_branch
    original_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    if ! git checkout -b "$FALLBACK_BRANCH" 2>/dev/null; then
        [[ "$stash_was_empty" == "false" ]] && git stash pop 2>/dev/null
        log_status "ERROR" "Failed to create fallback branch: $FALLBACK_BRANCH"
        return 1
    fi

    # ── Step 3: Pop stash ────────────────────────────────────────────────────
    if [[ "$stash_was_empty" == "false" ]]; then
        local pop_output
        if ! pop_output=$(git stash pop 2>&1); then
            log_status "ERROR" "git stash pop failed: $pop_output. Work is saved in stash."
            [[ -n "$original_branch" ]] && git checkout "$original_branch" 2>/dev/null
            return 1
        fi
    fi

    # ── Step 4: Commit ───────────────────────────────────────────────────────
    # Exclude .ralph/ so ralph internal state never becomes a standalone commit
    # or rides along in the PR (see Step 1 of worktree_commit_and_pr).
    if [[ -n "$(git status --porcelain -- . ':(exclude).ralph/**' 2>/dev/null)" ]]; then
        if ! git add -A -- . ':(exclude).ralph/**'; then
            log_status "ERROR" "git add failed on fallback branch $FALLBACK_BRANCH"
            return 1
        fi
        if ! git commit -m "ralph-${engine}: auto-commit run #${loop_count}" 2>/dev/null; then
            log_status "ERROR" "Commit failed on fallback branch $FALLBACK_BRANCH"
            return 1
        fi
    else
        log_status "WARN" "Nothing but ralph internal state to commit on fallback branch $FALLBACK_BRANCH"
    fi

    # Resolve base branch
    local base_branch="${PR_BASE_BRANCH:-}"
    if [[ -z "$base_branch" ]]; then
        base_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
                      | sed 's@^refs/remotes/origin/@@')
    fi
    [[ -z "$base_branch" ]] && base_branch="main"
    local state_rebase="SKIPPED" state_pushed="false" state_pr="skipped" state_label="n/a"

    # ── Step 4b: Ensure branch contains real source diff before push/PR ─────
    if [[ "$RALPH_PR_PUSH_CAPABLE" == "true" ]]; then
        if ! _pr_require_committable_source_diff "$base_branch" "$FALLBACK_BRANCH"; then
            [[ -n "$original_branch" ]] && git checkout "$original_branch" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    # ── Step 4c: Rebase onto advanced base ───────────────────────────────────
    # The fallback branch is checked out in the ambient repo (cwd), so rebase
    # here. On conflict, restore the original branch and stop.
    if [[ "$RALPH_PR_PUSH_CAPABLE" == "true" ]]; then
        local fb_rebase_status
        fb_rebase_status=$(_pr_rebase_onto_base "$base_branch")
        local fb_rebase_rc=$?
        if [[ $fb_rebase_rc -ne 0 ]]; then
            case "$fb_rebase_status" in
                DIRTY)
                    log_status "ERROR" "Rebase of $FALLBACK_BRANCH blocked by uncommitted tracked changes (see log above) — not a merge conflict" ;;
                CONFLICT)
                    log_status "ERROR" "Rebase of $FALLBACK_BRANCH onto origin/$base_branch hit a real merge conflict — conflicted files logged above; resolve and re-run" ;;
                *)
                    log_status "ERROR" "Rebase of $FALLBACK_BRANCH onto origin/$base_branch failed — git output logged above" ;;
            esac
            [[ -n "$original_branch" ]] && git checkout "$original_branch" >/dev/null 2>&1 || true
            return 1
        fi
        if [[ "$fb_rebase_status" == "CHANGED" && "$gate_passed" == "true" ]] \
            && declare -F worktree_run_quality_gates >/dev/null 2>&1 && [[ -n "${_WT_CURRENT_PATH:-}" ]]; then
            log_status "INFO" "Rebased $FALLBACK_BRANCH onto advanced origin/$base_branch — re-running quality gates"
            if ! worktree_run_quality_gates; then
                gate_passed="false"
                log_status "WARN" "Quality gates failed after rebase onto origin/$base_branch"
            fi
        fi
    fi

    # ── Step 5: Push ─────────────────────────────────────────────────────────
    if [[ "$RALPH_PR_PUSH_CAPABLE" != "true" ]]; then
        log_status "WARN" "Push skipped — no git remote. Branch: $FALLBACK_BRANCH"
    else
        # Fix B: force-with-lease for ralph-owned branches absorbs a stale
        # same-named remote branch without clobbering anyone else's work.
        local fb_push_rc=0
        if [[ "$FALLBACK_BRANCH" == ralph-*/* ]]; then
            git fetch origin "$FALLBACK_BRANCH" >/dev/null 2>&1 || true
            git push origin "$FALLBACK_BRANCH" --set-upstream --force-with-lease 2>/dev/null || fb_push_rc=$?
        else
            git push origin "$FALLBACK_BRANCH" --set-upstream 2>/dev/null || fb_push_rc=$?
        fi
        if [[ $fb_push_rc -ne 0 ]]; then
            log_status "ERROR" "Push failed for $FALLBACK_BRANCH"
            return 1
        fi
        log_status "SUCCESS" "Fallback branch pushed: $FALLBACK_BRANCH"
    fi

    # ── Steps 6–7: Create PR ─────────────────────────────────────────────────
    if [[ "$RALPH_PR_GH_CAPABLE" == "true" && "$RALPH_PR_PUSH_CAPABLE" == "true" ]]; then
        local existing_pr
        if existing_pr=$(_pr_lookup_existing_pr "$FALLBACK_BRANCH"); then
            log_status "INFO" "PR already exists for $FALLBACK_BRANCH: $existing_pr"
        else
            # Confirm the pushed branch is on origin (propagation lag) before gh.
            _pr_confirm_remote_branch "$FALLBACK_BRANCH" || true

            # Never call gh with zero commits (the "No commits between" failure).
            local commits_ahead
            commits_ahead=$(_pr_commits_ahead "$base_branch" "$FALLBACK_BRANCH")
            if [[ "$commits_ahead" == "0" ]]; then
                log_status "WARN" "No commits to PR for $FALLBACK_BRANCH (origin/$base_branch..$FALLBACK_BRANCH empty) — skipping PR creation"
                return 0
            fi

            local pr_title pr_body
            pr_title=$(pr_build_title "$task_id" "$task_name")
            pr_body=$(pr_build_description "$task_id" "$task_name" "$FALLBACK_BRANCH" \
                      "$gate_passed" "${RALPH_DIR}/.quality_gate_results" "$loop_count")
            local gh_args=(--base "$base_branch" --head "$FALLBACK_BRANCH" \
                           --title "$pr_title" --body "$pr_body")
            [[ "${PR_DRAFT:-false}" == "true" ]] && gh_args+=(--draft)
            local pr_url
            if ! pr_url=$(_pr_gh_try pr create "${gh_args[@]}"); then
                # Surface gh's stderr verbatim; keep the pushed branch for manual PR.
                log_status "ERROR" "Fallback PR creation failed for $FALLBACK_BRANCH: $pr_url"
                log_status "ERROR" "Branch is pushed — open by hand: gh pr create --head $FALLBACK_BRANCH --base $base_branch"
                return 1
            fi
            log_status "SUCCESS" "Fallback PR created: $pr_url"
        fi
    else
        log_status "INFO" "gh not available — fallback branch pushed: $FALLBACK_BRANCH"
        _pr_print_compare_url "$FALLBACK_BRANCH" "$base_branch"
    fi

    # ── Step 7: Add failure label ─────────────────────────────────────────────
    if [[ "$gate_passed" == "false" && "$RALPH_PR_GH_CAPABLE" == "true" ]]; then
        _pr_ensure_label "quality-gates-failed" "d93f0b" "Ralph: quality gates did not pass" || true
        local label_out
        state_label="applied"
        if ! label_out=$(gh pr edit "$FALLBACK_BRANCH" --add-label "quality-gates-failed" 2>&1); then
            state_label="failed"
            log_status "WARN" "Could not add 'quality-gates-failed' label to PR: $label_out"
        fi
    fi

    _pr_log_task_state "$FALLBACK_BRANCH" "$gate_passed" "$state_rebase" "$state_pushed" "$state_pr" "$state_label"
    return 0
}
