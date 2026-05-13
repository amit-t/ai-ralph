#!/usr/bin/env bats
# Unit tests for lib/task_sources.sh
# Tests beads integration, GitHub integration, PRD extraction, and task normalization

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to task_sources.sh
TASK_SOURCES="${BATS_TEST_DIRNAME}/../../lib/task_sources.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Source the library
    source "$TASK_SOURCES"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# BEADS DETECTION (3 tests)
# =============================================================================

@test "check_beads_available returns false when no .beads directory" {
    run check_beads_available
    assert_failure
}

@test "check_beads_available returns false when bd command not found" {
    mkdir -p .beads
    # bd command likely won't exist in test environment
    if command -v bd &>/dev/null; then
        skip "bd command is available"
    fi
    run check_beads_available
    assert_failure
}

@test "get_beads_count returns 0 when beads unavailable" {
    run get_beads_count
    assert_output "0"
}

# =============================================================================
# GITHUB DETECTION (3 tests)
# =============================================================================

@test "check_github_available returns false when no gh command" {
    # gh command may not exist in test environment
    if ! command -v gh &>/dev/null; then
        run check_github_available
        assert_failure
    else
        skip "gh command is available"
    fi
}

@test "check_github_available returns false when not in git repo" {
    run check_github_available
    assert_failure
}

@test "get_github_issue_count returns 0 when GitHub unavailable" {
    run get_github_issue_count
    assert_output "0"
}

# =============================================================================
# PRD EXTRACTION (6 tests)
# =============================================================================

@test "extract_prd_tasks extracts checkbox items" {
    cat > prd.md << 'EOF'
# Requirements

- [ ] Implement user authentication
- [x] Set up database
- [ ] Add API endpoints
EOF

    run extract_prd_tasks "prd.md"

    assert_success
    [[ "$output" =~ "Implement user authentication" ]]
    [[ "$output" =~ "Add API endpoints" ]]
}

@test "extract_prd_tasks extracts numbered list items" {
    cat > prd.md << 'EOF'
# Requirements

1. Implement user authentication
2. Set up database
3. Add API endpoints
EOF

    run extract_prd_tasks "prd.md"

    assert_success
    [[ "$output" =~ "Implement user authentication" ]]
}

@test "extract_prd_tasks returns empty for file without tasks" {
    cat > prd.md << 'EOF'
# Empty Document

This document has no tasks.
EOF

    run extract_prd_tasks "prd.md"

    assert_success
}

@test "extract_prd_tasks returns error for missing file" {
    run extract_prd_tasks "nonexistent.md"
    assert_failure
}

@test "extract_prd_tasks normalizes checked items to unchecked" {
    cat > prd.md << 'EOF'
- [x] Completed task
- [X] Another completed
EOF

    run extract_prd_tasks "prd.md"

    assert_success
    [[ "$output" =~ "[ ]" ]]
    [[ ! "$output" =~ "[x]" ]]
    [[ ! "$output" =~ "[X]" ]]
}

@test "extract_prd_tasks limits output to 30 tasks" {
    # Create PRD with 40 tasks
    {
        echo "# Tasks"
        for i in {1..40}; do
            echo "- [ ] Task $i"
        done
    } > prd.md

    run extract_prd_tasks "prd.md"

    # Count the number of task lines
    task_count=$(echo "$output" | grep -c '^\- \[' || echo "0")
    [[ "$task_count" -le 30 ]]
}

# =============================================================================
# TASK NORMALIZATION (5 tests)
# =============================================================================

@test "normalize_tasks converts bullet points to checkboxes" {
    input="- First task
* Second task"

    run normalize_tasks "$input"

    assert_success
    [[ "$output" =~ "- [ ] First task" ]]
    [[ "$output" =~ "- [ ] Second task" ]]
}

@test "normalize_tasks converts numbered items to checkboxes" {
    input="1. First task
2. Second task"

    run normalize_tasks "$input"

    assert_success
    [[ "$output" =~ "- [ ]" ]]
}

@test "normalize_tasks preserves existing checkboxes" {
    input="- [ ] Already a task"

    run normalize_tasks "$input"

    assert_success
    [[ "$output" =~ "- [ ] Already a task" ]]
}

@test "normalize_tasks handles plain text lines" {
    input="Plain text task"

    run normalize_tasks "$input"

    assert_success
    [[ "$output" =~ "- [ ] Plain text task" ]]
}

@test "normalize_tasks handles empty input" {
    run normalize_tasks ""
    assert_success
}

# =============================================================================
# TASK PRIORITIZATION (3 tests)
# =============================================================================

@test "prioritize_tasks puts critical tasks in High Priority" {
    input="- [ ] Critical bug fix
- [ ] Normal task"

    output=$(prioritize_tasks "$input" || true)

    [[ "$output" =~ "## High Priority" ]]
    # Critical should be before Medium
    high_section="${output%%## Medium*}"
    [[ "$high_section" =~ "Critical bug fix" ]]
}

@test "prioritize_tasks puts optional tasks in Low Priority" {
    input="- [ ] Nice to have feature
- [ ] Normal task"

    run prioritize_tasks "$input"

    assert_success
    [[ "$output" =~ "## Low Priority" ]]
    low_section="${output##*## Low Priority}"
    [[ "$low_section" =~ "Nice to have" ]]
}

@test "prioritize_tasks puts regular tasks in Medium Priority" {
    input="- [ ] Regular task"

    output=$(prioritize_tasks "$input" || true)

    [[ "$output" =~ "## Medium Priority" ]]
}

# =============================================================================
# COMBINED IMPORT (3 tests)
# =============================================================================

@test "import_tasks_from_sources handles prd source" {
    mkdir -p docs
    cat > docs/prd.md << 'EOF'
# Requirements
- [ ] Test task
EOF

    run import_tasks_from_sources "prd" "docs/prd.md" ""

    assert_success
    [[ "$output" =~ "Test task" ]]
}

@test "import_tasks_from_sources handles empty sources" {
    run import_tasks_from_sources "" "" ""

    assert_failure
}

@test "import_tasks_from_sources handles none source" {
    run import_tasks_from_sources "none" "" ""

    # 'none' doesn't import anything, so fails
    assert_failure
}

# =============================================================================
# pick_task_by_id (bold-id resolution, regression for E5/`**E5.**`)
# =============================================================================

# Helper: write a fix_plan.md with task lines to a path. First arg is the path,
# remaining args are appended verbatim as task lines.
_write_fix_plan() {
    local path="$1"; shift
    mkdir -p "$(dirname "$path")"
    : > "$path"
    local line
    for line in "$@"; do
        printf '%s\n' "$line" >> "$path"
    done
}

@test "pick_task_by_id matches plain bold **E5**" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **E1** First task" \
        "- [ ] **E5** Subset filter"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_success
    [[ "$output" == E5\|2\|* ]]
}

@test "pick_task_by_id matches **E5.** with trailing period" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **E1.** First" \
        "- [ ] **E5.** Subset filter"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_success
    [[ "$output" == E5\|2\|* ]]
}

@test "pick_task_by_id matches **E5:** with colon" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **E5:** Subset filter"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_success
}

@test "pick_task_by_id matches **E5)** with paren" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **E5)** Subset filter"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_success
}

@test "pick_task_by_id is case-insensitive (e5 finds **E5.**)" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **E5.** Subset filter"
    run pick_task_by_id .ralph/fix_plan.md e5
    assert_success
}

@test "pick_task_by_id matches non-bold ID followed by period" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] E5. Subset filter"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_success
}

@test "pick_task_by_id does not partial-match E5 inside E50" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **E50.** Bigger task"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_failure
    [[ "$output" == *"not found"* ]]
}

@test "pick_task_by_id rejects already-completed task" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [x] **E5.** Already done"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_failure
    [[ "$output" == *"already completed"* ]]
}

@test "pick_task_by_id marks unclaimed task in-progress on hit" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **E5.** Subset filter"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_success
    run grep -F -e '- [~] **E5.**' .ralph/fix_plan.md
    assert_success
}

@test "pick_task_by_id leaves in-progress task as-is" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [~] **E5.** Subset filter"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_success
    run grep -F -e '- [~] **E5.**' .ralph/fix_plan.md
    assert_success
}

@test "pick_task_by_id returns error when fix_plan.md missing" {
    run pick_task_by_id .ralph/missing.md E5
    assert_failure
}

@test "pick_task_by_id returns error when ID not present" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **E1.** First"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_failure
    [[ "$output" == *"not found"* ]]
}

@test "pick_task_by_id ignores non-task lines (e.g. headings) containing the ID" {
    _write_fix_plan .ralph/fix_plan.md \
        "## E5 design" \
        "Some prose mentioning **E5.**" \
        "- [ ] **E5.** The actual task"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_success
    [[ "$output" == E5\|3\|* ]]
}

@test "pick_task_by_id extracts bead_id when present" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] [bd-42] **E5.** Subset filter"
    run pick_task_by_id .ralph/fix_plan.md E5
    assert_success
    [[ "$output" == E5\|1\|bd-42 ]]
}

@test "pick_task_by_id handles dotted IDs like v1.0" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **v1.0** Release task"
    run pick_task_by_id .ralph/fix_plan.md v1.0
    assert_success
}

# =============================================================================
# pick_task_by_id: slug-form resolution (continuous-mode worker tabs)
# =============================================================================
# pick_next_task_for_pool slugifies the title for lines without a bead_id,
# capped at 50 chars. Worker tabs are spawned with `--task <slug>` and must
# be able to round-trip that slug back to the source line.

@test "pick_task_by_id resolves slug from pick_next_task_for_pool" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **M2.** Unify desktop vs mobile branding"
    # Slug produced by pick_next_task_for_pool's slugifier on that title:
    run pick_task_by_id .ralph/fix_plan.md m2-unify-desktop-vs-mobile-branding
    assert_success
    # task_id in the descriptor must be the slug (lowercase), so it round-trips.
    [[ "$output" == m2-unify-desktop-vs-mobile-branding\|1\|* ]]
}

@test "pick_task_by_id resolves slug when line is already [~] (re-entry case)" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [~] **M2.** Unify desktop vs mobile branding"
    run pick_task_by_id .ralph/fix_plan.md m2-unify-desktop-vs-mobile-branding
    assert_success
}

@test "pick_task_by_id slug match respects 50-char cap" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **L9.** A really long title that runs well past fifty characters and keeps going"
    # head -c 50 of the slug "l9-a-really-long-title-that-runs-well-past-fifty-characters-and-keeps-going":
    local slug
    slug=$(printf '%s' "L9. A really long title that runs well past fifty characters and keeps going" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' \
        | head -c 50)
    run pick_task_by_id .ralph/fix_plan.md "$slug"
    assert_success
}

@test "pick_task_by_id slug match does not match unrelated lines" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **M1.** Tone down login decoration" \
        "- [ ] **M2.** Unify desktop vs mobile branding"
    run pick_task_by_id .ralph/fix_plan.md m2-unify-desktop-vs-mobile-branding
    assert_success
    # Must pick line 2 (M2), not line 1 (M1).
    [[ "$output" == *"|2|"* ]]
}

@test "pick_task_by_id slug match falls behind bold-id match in precedence" {
    # If both a bold ID and a slug could match different lines, the bold-id
    # match (first hit when scanning) should win. Here the slug `e1-first`
    # would match line 1, and so would `E1` via bold-id — both pick line 1.
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **E1.** First task" \
        "- [ ] **E2.** Second task"
    run pick_task_by_id .ralph/fix_plan.md E1
    assert_success
    [[ "$output" == E1\|1\|* ]]
}

@test "pick_task_by_id slug match marks line in-progress on hit" {
    _write_fix_plan .ralph/fix_plan.md \
        "- [ ] **M2.** Unify desktop vs mobile branding"
    run pick_task_by_id .ralph/fix_plan.md m2-unify-desktop-vs-mobile-branding
    assert_success
    run grep -F -e '- [~] **M2.**' .ralph/fix_plan.md
    assert_success
}
