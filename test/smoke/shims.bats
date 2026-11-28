#!/usr/bin/env bats
# End-to-end checks against a real Docker engine: every command the README
# documents as working, run through the shims on a hello-world project.
# Needs network access to Docker Hub and the npm registry. Exact-output
# checks use --separate-stderr: the first run of an image prints Docker's
# pull progress on stderr.

load ../helpers

bats_require_minimum_version 1.5.0

# Pinned so a registry release cannot turn the suite red on its own.
YARN_VERSION=4.18.1
PNPM_VERSION=11.28.10
WRANGLER_VERSION=4.156.0

setup() {
    export PATH="$SHIMS_DIR:$PATH"
    unset NODE_IMAGE NODE_SHIMS_MODE NODE_SHIMS_LOCAL NODE_SHIMS_DOCKER
    mkdir -p "$HOME/.npm" "$HOME/.cache/pnpm" "$HOME/.cache/yarn" "$HOME/.config/pnpm"
}

teardown() {
    cleanup_project
}

set_package_manager() {
    # perl, not sed: BSD and GNU sed disagree on -i and on \n in replacements.
    PM="$1" perl -0pi -e 's/"private": true,/"private": true,\n  "packageManager": "$ENV{PM}",/' package.json
}

@test "node runs on the default LTS image" {
    make_project hello
    local default_major
    default_major="$(grep -o 'node:[0-9]*-alpine' "$SHIMS_DIR/common.sh" | head -1 | tr -dc '0-9')"

    run --separate-stderr node --version
    [ "$status" -eq 0 ]
    [[ "$output" == "v${default_major}."* ]]
}

@test "node honours .nvmrc" {
    make_project hello
    echo 22 > .nvmrc

    run --separate-stderr node --version
    [ "$status" -eq 0 ]
    [[ "$output" == v22.* ]]
}

@test "node runs a project script by relative and absolute path" {
    make_project hello
    npm install --no-audit --no-fund

    run node index.js
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hello, world!"* ]]

    run node "$PROJECT_DIR/index.js"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hello, world!"* ]]
}

@test "npm installs, tests and starts the app" {
    make_project hello

    run npm install --no-audit --no-fund
    [ "$status" -eq 0 ]
    [ -f package-lock.json ]
    [ -d node_modules/picocolors ]

    run npm test
    [ "$status" -eq 0 ]

    run npm start
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hello, world!"* ]]
}

@test "yarn from packageManager installs, tests and starts the app" {
    make_project hello
    set_package_manager "yarn@$YARN_VERSION"

    run --separate-stderr yarn --version
    [ "$status" -eq 0 ]
    [ "$output" = "$YARN_VERSION" ]

    run yarn install
    [ "$status" -eq 0 ]
    [ -f yarn.lock ]

    run yarn test
    [ "$status" -eq 0 ]

    run yarn start
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hello, world!"* ]]
}

@test "a yarn install in Docker still runs with NODE_SHIMS_LOCAL" {
    PATH="${PATH#"$SHIMS_DIR:"}" command -v node >/dev/null ||
        skip "no host node outside the shims"
    make_project hello
    set_package_manager "yarn@$YARN_VERSION"
    yarn install

    # .pnp.cjs records where the cache lives; the host node must find it too.
    NODE_SHIMS_LOCAL=1 run node --require ./.pnp.cjs index.js
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hello, world!"* ]]
}

@test "pnpm from packageManager installs, tests and starts the app" {
    make_project hello
    set_package_manager "pnpm@$PNPM_VERSION"

    run --separate-stderr pnpm --version
    [ "$status" -eq 0 ]
    [ "$output" = "$PNPM_VERSION" ]

    run pnpm install
    [ "$status" -eq 0 ]
    [ -f pnpm-lock.yaml ]

    run pnpm test
    [ "$status" -eq 0 ]

    run pnpm start
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hello, world!"* ]]
}

@test "pnpm shares one store between NODE_SHIMS_LOCAL and Docker" {
    local host_path="${PATH#"$SHIMS_DIR:"}"
    PATH="$host_path" command -v npm >/dev/null || skip "no host npm outside the shims"
    # Fresh HOME: on Linux, earlier tests' containers leave root-owned files
    # in the shared caches that a non-root host npm/pnpm cannot write to.
    # (Docker Desktop on macOS maps ownership to the user, so this is CI only.)
    HOME="$(mktemp -d "${TMPDIR:-/tmp}/node-shims-home.XXXXXX")"
    export HOME
    make_project hello
    set_package_manager "pnpm@$PNPM_VERSION"

    local host_pnpm
    host_pnpm="$(mktemp -d)"
    PATH="$host_path" npm install --prefix "$host_pnpm" --no-audit --no-fund "pnpm@$PNPM_VERSION"
    PATH="$PATH:$host_pnpm/node_modules/.bin" NODE_SHIMS_LOCAL=1 pnpm install
    rm -rf "$host_pnpm"

    # Without node_modules the install must come from the store; --offline
    # proves the container reads the one the host filled.
    rm -rf node_modules
    run pnpm install --offline --frozen-lockfile
    [ "$status" -eq 0 ]
    [ ! -e .pnpm-store ]

    run pnpm start
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hello, world!"* ]]
}

@test "npx wrangler builds a worker without logging in" {
    make_project hello-worker

    run --separate-stderr npx --yes "wrangler@$WRANGLER_VERSION" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"$WRANGLER_VERSION"* ]]

    run npx --yes "wrangler@$WRANGLER_VERSION" deploy --dry-run --outdir dist
    [ "$status" -eq 0 ]
    grep -q 'Hello, world!' dist/index.js
}

@test "npm scripts can run docker with NODE_SHIMS_DOCKER=1" {
    make_project docker-in-npm

    NODE_SHIMS_DOCKER=1 run npm run docker:test
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hello from Docker!"* ]]
}

@test "env injected by op run reaches the container" {
    make_project
    local stub
    stub="$(mktemp -d)"
    # A direct #!/bin/bash shebang (not env) keeps the process name "op".
    cat > "$stub/op" <<'EOF'
#!/bin/bash
[[ "$1" == run ]] || exit 2
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
shift
"$@"
EOF
    chmod +x "$stub/op"

    MY_SECRET=from-op run "$stub/op" run -- node -e 'console.log(process.env.MY_SECRET)'
    rm -rf "$stub"
    [ "$status" -eq 0 ]
    [ "$output" = "from-op" ]
}
