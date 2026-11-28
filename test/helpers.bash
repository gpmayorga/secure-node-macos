# Shared setup for the bats suites. Loaded with `load ../helpers`.

# shellcheck disable=SC2034  # read by the .bats files that load this
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SHIMS_DIR="$REPO_ROOT/bin"
FIXTURES_DIR="$REPO_ROOT/test/fixtures"

# A fresh project directory outside the repo, so the repo's own .npmrc and
# package files never leak into what the shims see.
make_project() {
    local fixture="${1:-}"
    PROJECT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/node-shims-test.XXXXXX")"
    if [[ -n "$fixture" ]]; then
        cp -R "$FIXTURES_DIR/$fixture/." "$PROJECT_DIR/"
    fi
    cd "$PROJECT_DIR" || return 1
}

# Containers write as root on Linux, so a plain rm can fail on CI runners.
# Leftovers in TMPDIR are harmless there; never fail a test over cleanup.
cleanup_project() {
    [[ -n "${PROJECT_DIR:-}" ]] || return 0
    cd /
    rm -rf "$PROJECT_DIR" 2>/dev/null || true
}
