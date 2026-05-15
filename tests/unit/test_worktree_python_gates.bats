#!/usr/bin/env bats
# Unit tests for Python/uv-aware quality-gate detection and dependency install
# in lib/worktree_manager.sh.
#
# Bug being fixed: _detect_quality_gates emitted bare `pytest` for any project
# with a pyproject.toml, even when pytest was only installed inside a uv-managed
# venv (i.e. only reachable via `uv run pytest`). Combined with
# _worktree_install_deps bailing out for any project without package.json, this
# meant every Python project's gate would fail with "pytest: command not found".

load '../helpers/test_helper'

WORKTREE_MANAGER="${BATS_TEST_DIRNAME}/../../lib/worktree_manager.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    source "$WORKTREE_MANAGER"

    # Quiet the install timeout
    WORKTREE_INSTALL_TIMEOUT=5
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
    unset WORKTREE_GATE_SUBDIRS
}

# =============================================================================
# _resolve_python_install — pure resolution, no execution side effects
# =============================================================================

@test "_resolve_python_install: no Python files → tool empty" {
    _resolve_python_install "$TEST_DIR"
    assert_equal "$_DEPS_INSTALL_TOOL" ""
    assert_equal "$_DEPS_INSTALL_CMD" ""
}

@test "_resolve_python_install: uv.lock present → uv sync" {
    touch "$TEST_DIR/pyproject.toml" "$TEST_DIR/uv.lock"
    _resolve_python_install "$TEST_DIR"
    assert_equal "$_DEPS_INSTALL_TOOL" "uv"
    assert_equal "$_DEPS_INSTALL_CMD" "uv sync"
}

@test "_resolve_python_install: [tool.uv] in pyproject.toml → uv sync" {
    printf '[tool.uv]\nmanaged = true\n' > "$TEST_DIR/pyproject.toml"
    _resolve_python_install "$TEST_DIR"
    assert_equal "$_DEPS_INSTALL_TOOL" "uv"
    assert_equal "$_DEPS_INSTALL_CMD" "uv sync"
}

@test "_resolve_python_install: [dependency-groups] in pyproject.toml → uv sync" {
    # Exact M-1 bug repro: terminal_vibe_check uses [dependency-groups]
    printf '[project]\nname = "x"\n\n[dependency-groups]\ndev = ["pytest"]\n' \
        > "$TEST_DIR/pyproject.toml"
    _resolve_python_install "$TEST_DIR"
    assert_equal "$_DEPS_INSTALL_TOOL" "uv"
    assert_equal "$_DEPS_INSTALL_CMD" "uv sync"
}

@test "_resolve_python_install: poetry.lock present → poetry install" {
    touch "$TEST_DIR/pyproject.toml" "$TEST_DIR/poetry.lock"
    _resolve_python_install "$TEST_DIR"
    assert_equal "$_DEPS_INSTALL_TOOL" "poetry"
    [[ "$_DEPS_INSTALL_CMD" == "poetry install"* ]]
}

@test "_resolve_python_install: [tool.poetry] in pyproject.toml → poetry install" {
    printf '[tool.poetry]\nname = "x"\n' > "$TEST_DIR/pyproject.toml"
    _resolve_python_install "$TEST_DIR"
    assert_equal "$_DEPS_INSTALL_TOOL" "poetry"
    [[ "$_DEPS_INSTALL_CMD" == "poetry install"* ]]
}

@test "_resolve_python_install: Pipfile.lock → pipenv" {
    touch "$TEST_DIR/Pipfile" "$TEST_DIR/Pipfile.lock"
    _resolve_python_install "$TEST_DIR"
    assert_equal "$_DEPS_INSTALL_TOOL" "pipenv"
    [[ "$_DEPS_INSTALL_CMD" == "pipenv install"* ]]
}

@test "_resolve_python_install: requirements-dev.txt preferred over requirements.txt" {
    touch "$TEST_DIR/requirements.txt" "$TEST_DIR/requirements-dev.txt"
    _resolve_python_install "$TEST_DIR"
    assert_equal "$_DEPS_INSTALL_TOOL" "pip"
    assert_equal "$_DEPS_INSTALL_CMD" "pip install -r requirements-dev.txt"
}

@test "_resolve_python_install: requirements.txt only → pip install -r" {
    touch "$TEST_DIR/requirements.txt"
    _resolve_python_install "$TEST_DIR"
    assert_equal "$_DEPS_INSTALL_TOOL" "pip"
    assert_equal "$_DEPS_INSTALL_CMD" "pip install -r requirements.txt"
}

@test "_resolve_python_install: plain pyproject.toml → pip install -e" {
    printf '[project]\nname = "x"\n' > "$TEST_DIR/pyproject.toml"
    _resolve_python_install "$TEST_DIR"
    assert_equal "$_DEPS_INSTALL_TOOL" "pip"
    [[ "$_DEPS_INSTALL_CMD" == *"pip install -e"* ]]
}

@test "_resolve_python_install: existing populated .venv → skip" {
    touch "$TEST_DIR/pyproject.toml" "$TEST_DIR/uv.lock"
    mkdir -p "$TEST_DIR/.venv/bin"
    touch "$TEST_DIR/.venv/bin/python"
    _resolve_python_install "$TEST_DIR"
    assert_equal "$_DEPS_INSTALL_TOOL" ""
    assert_equal "$_DEPS_INSTALL_CMD" ""
}

# =============================================================================
# _detect_gates_for_dir — per-directory gate detection
# =============================================================================

@test "_detect_gates_for_dir: uv project → uv run pytest" {
    touch "$TEST_DIR/pyproject.toml" "$TEST_DIR/uv.lock"
    run _detect_gates_for_dir "$TEST_DIR"
    assert_success
    [[ "$output" == *"uv run pytest"* ]]
    [[ "$output" != *";pytest"* ]]  # no bare pytest
}

@test "_detect_gates_for_dir: [dependency-groups] → uv run pytest (M-1 repro)" {
    printf '[project]\nname = "x"\n\n[dependency-groups]\ndev = ["pytest"]\n' \
        > "$TEST_DIR/pyproject.toml"
    run _detect_gates_for_dir "$TEST_DIR"
    assert_success
    [[ "$output" == *"uv run pytest"* ]]
}

@test "_detect_gates_for_dir: poetry project → poetry run pytest" {
    printf '[tool.poetry]\nname = "x"\n' > "$TEST_DIR/pyproject.toml"
    run _detect_gates_for_dir "$TEST_DIR"
    assert_success
    [[ "$output" == *"poetry run pytest"* ]]
}

@test "_detect_gates_for_dir: plain pyproject.toml → bare pytest" {
    printf '[project]\nname = "x"\n' > "$TEST_DIR/pyproject.toml"
    run _detect_gates_for_dir "$TEST_DIR"
    assert_success
    [[ "$output" == *"pytest"* ]]
    [[ "$output" != *"uv run"* ]]
    [[ "$output" != *"poetry run"* ]]
}

@test "_detect_gates_for_dir: ruff in uv project → uv run ruff" {
    printf '[project]\nname = "x"\n[tool.ruff]\nline-length = 100\n' \
        > "$TEST_DIR/pyproject.toml"
    touch "$TEST_DIR/uv.lock"
    run _detect_gates_for_dir "$TEST_DIR"
    assert_success
    [[ "$output" == *"uv run ruff check"* ]]
}

@test "_detect_gates_for_dir: no Python files → no pytest gate" {
    run _detect_gates_for_dir "$TEST_DIR"
    assert_success
    [[ "$output" != *"pytest"* ]]
}

@test "_detect_gates_for_dir: js + python coexist → both emitted" {
    echo '{"scripts":{"build":"vite build"}}' > "$TEST_DIR/package.json"
    touch "$TEST_DIR/pyproject.toml" "$TEST_DIR/uv.lock"
    run _detect_gates_for_dir "$TEST_DIR"
    assert_success
    [[ "$output" == *"npm run build"* ]]
    [[ "$output" == *"uv run pytest"* ]]
}

# =============================================================================
# _detect_quality_gates — top-level w/ WORKTREE_GATE_SUBDIRS
# =============================================================================

@test "_detect_quality_gates: subdir gates not included without env var" {
    # Repo with no root package.json but frontend/package.json
    mkdir -p "$TEST_DIR/frontend"
    echo '{"scripts":{"build":"vite build"}}' > "$TEST_DIR/frontend/package.json"
    unset WORKTREE_GATE_SUBDIRS
    run _detect_quality_gates "$TEST_DIR"
    assert_success
    [[ "$output" != *"npm run build"* ]]
}

@test "_detect_quality_gates: subdir gates included with WORKTREE_GATE_SUBDIRS=frontend" {
    mkdir -p "$TEST_DIR/frontend"
    echo '{"scripts":{"build":"vite build"}}' > "$TEST_DIR/frontend/package.json"
    WORKTREE_GATE_SUBDIRS="frontend" run _detect_quality_gates "$TEST_DIR"
    assert_success
    [[ "$output" == *"cd frontend && npm run build"* ]]
}

@test "_detect_quality_gates: multiple subdirs supported" {
    mkdir -p "$TEST_DIR/frontend" "$TEST_DIR/backend"
    echo '{"scripts":{"build":"vite build"}}' > "$TEST_DIR/frontend/package.json"
    touch "$TEST_DIR/backend/pyproject.toml" "$TEST_DIR/backend/uv.lock"
    WORKTREE_GATE_SUBDIRS="frontend backend" run _detect_quality_gates "$TEST_DIR"
    assert_success
    [[ "$output" == *"cd frontend && npm run build"* ]]
    [[ "$output" == *"cd backend && uv run pytest"* ]]
}

@test "_detect_quality_gates: missing subdir is silently ignored" {
    mkdir -p "$TEST_DIR/frontend"
    echo '{"scripts":{"build":"vite build"}}' > "$TEST_DIR/frontend/package.json"
    WORKTREE_GATE_SUBDIRS="frontend nonexistent" run _detect_quality_gates "$TEST_DIR"
    assert_success
    [[ "$output" == *"cd frontend && npm run build"* ]]
    [[ "$output" != *"nonexistent"* ]]
}

@test "_detect_quality_gates: root + subdir gates combined" {
    # Root is a Python project, subdir is JS — the M-1 repo's layout
    touch "$TEST_DIR/pyproject.toml" "$TEST_DIR/uv.lock"
    mkdir -p "$TEST_DIR/frontend"
    echo '{"scripts":{"build":"vite build"}}' > "$TEST_DIR/frontend/package.json"
    WORKTREE_GATE_SUBDIRS="frontend" run _detect_quality_gates "$TEST_DIR"
    assert_success
    [[ "$output" == *"uv run pytest"* ]]
    [[ "$output" == *"cd frontend && npm run build"* ]]
}
