#!/usr/bin/env bats
# Unit tests for the shim logic. A fake `docker` on PATH records the argv the
# shim would pass to `docker run`, so no daemon or image is needed.

load ../helpers

bats_require_minimum_version 1.5.0

setup() {
    STUB_DIR="$(mktemp -d)"
    DOCKER_ARGS_LOG="$STUB_DIR/docker-args"
    export DOCKER_ARGS_LOG

    cat > "$STUB_DIR/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
    [[ -z "${FAKE_DOCKER_DOWN:-}" ]]
    exit
fi
printf '%s\n' "$@" > "$DOCKER_ARGS_LOG"
EOF
    chmod +x "$STUB_DIR/docker"

    export HOME="$STUB_DIR/home"
    mkdir -p "$HOME"
    export PATH="$SHIMS_DIR:$STUB_DIR:/usr/bin:/bin"
    unset NODE_IMAGE NODE_SHIMS_MODE NODE_SHIMS_LOCAL NODE_SHIMS_DOCKER DOCKER_NODE_PORTS

    make_project
}

teardown() {
    cleanup_project
    rm -rf "$STUB_DIR"
}

# True when the recorded docker argv contains the exact sequence given.
docker_args_have() {
    local needle haystack
    needle="$(printf '%s\n' "$@")"
    haystack="$(cat "$DOCKER_ARGS_LOG")"
    [[ "$haystack" == *"$needle"* ]]
}

recorded_image() {
    # The image is the argument right before `sh -c <setup>`.
    grep -B1 -x 'sh' "$DOCKER_ARGS_LOG" | head -1
}

@test "image is chosen from .nvmrc, .node-version, engines, then NODE_IMAGE" {
    local default_major
    default_major="$(grep -o 'node:[0-9]*-alpine' "$SHIMS_DIR/common.sh" | head -1)"

    run node --version
    [ "$status" -eq 0 ]
    [ "$(recorded_image)" = "$default_major" ]

    echo '{"engines":{"node":">=20.1.0"}}' > package.json
    node --version
    [ "$(recorded_image)" = "node:20-alpine" ]

    echo 'v18.19.0' > .node-version
    node --version
    [ "$(recorded_image)" = "node:18-alpine" ]

    echo '22' > .nvmrc
    node --version
    [ "$(recorded_image)" = "node:22-alpine" ]

    NODE_IMAGE=node:24-bookworm node --version
    [ "$(recorded_image)" = "node:24-bookworm" ]
}

@test "every tool shim runs the same-named tool inside the container" {
    for tool in node npm npx yarn pnpm; do
        "$tool" --version
        [ "$(tail -2 "$DOCKER_ARGS_LOG")" = "$(printf '%s\n%s' "$tool" --version)" ]
    done
}

@test "project is mounted at its real path and at /work" {
    node index.js
    local physical
    physical="$(pwd -P)"
    docker_args_have -v "$physical:$physical"
    docker_args_have -v "$physical:/work"
    docker_args_have -w "$PROJECT_DIR"
}

@test "absolute path arguments outside the project are mounted, home and / are not" {
    local outside
    outside="$(mktemp -d)"
    touch "$outside/config.json"

    npx tool --config="$outside/config.json" / "$HOME"

    docker_args_have -v "$outside/config.json:$outside/config.json"
    run ! docker_args_have -v "/:/"
    run ! docker_args_have -v "$HOME:$HOME"
    rm -rf "$outside"
}

@test "dev server commands map ports, other commands do not" {
    npm run dev
    docker_args_have -p "5173:5173"
    docker_args_have -p "8787:8787"

    npm install
    run ! grep -qx -- '-p' "$DOCKER_ARGS_LOG"

    DOCKER_NODE_PORTS=4321 npm start
    docker_args_have -p "4321:4321"
    run ! docker_args_have -p "3000:3000"
}

@test "wrangler login maps the OAuth callback port" {
    npx wrangler login
    docker_args_have -p "8976:8976"

    WRANGLER_LOGIN_PORT=9797 npx wrangler login
    docker_args_have -p "9797:9797"
}

@test "NODE_SHIMS_DOCKER mounts the host docker socket" {
    [[ -S /var/run/docker.sock ]] || skip "no docker socket on this host"

    npm run build
    run ! grep -q 'docker.sock' "$DOCKER_ARGS_LOG"

    NODE_SHIMS_DOCKER=1 npm run build
    docker_args_have -v "/var/run/docker.sock:/var/run/docker.sock"
}

@test "op run parent forwards host env by name, never by value" {
    # A direct #!/bin/bash shebang (not env) keeps the process name "op",
    # which is what the shim inspects.
    cat > "$STUB_DIR/op" <<'EOF'
#!/bin/bash
# Mimics `op run [flags] -- cmd`: the command runs as a child of `op`.
[[ "$1" == run ]] || exit 2
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
shift
"$@"
EOF
    chmod +x "$STUB_DIR/op"

    MY_SECRET=hunter2 node app.js
    run ! docker_args_have -e MY_SECRET

    MY_SECRET=hunter2 op run --env-file=.env -- node app.js
    docker_args_have -e MY_SECRET
    run ! grep -q hunter2 "$DOCKER_ARGS_LOG"
    run ! docker_args_have -e PATH
    run ! docker_args_have -e HOME
}

@test "local override runs the host tool and never calls docker" {
    mkdir "$STUB_DIR/host"
    printf '#!/bin/sh\necho "host node $*"\n' > "$STUB_DIR/host/node"
    chmod +x "$STUB_DIR/host/node"

    PATH="$PATH:$STUB_DIR/host" NODE_SHIMS_MODE=local run node -v
    [ "$status" -eq 0 ]
    [ "$output" = "host node -v" ]
    [ ! -e "$DOCKER_ARGS_LOG" ]

    NODE_SHIMS_LOCAL=1 run node -v
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found outside the Docker shims"* ]]
}

@test "node falls back to host node only for scripts outside the project" {
    mkdir "$STUB_DIR/host" "$STUB_DIR/app"
    printf '#!/bin/sh\necho "host node $*"\n' > "$STUB_DIR/host/node"
    chmod +x "$STUB_DIR/host/node"
    touch "$STUB_DIR/app/esbuild.js" inside.js
    export PATH="$PATH:$STUB_DIR/host"

    run node "$STUB_DIR/app/esbuild.js"
    [ "$output" = "host node $STUB_DIR/app/esbuild.js" ]

    run node inside.js
    [ "$status" -eq 0 ]
    [ -e "$DOCKER_ARGS_LOG" ]
}

@test "shims fail clearly when the docker engine is down" {
    FAKE_DOCKER_DOWN=1 run node --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"Docker engine not running"* ]]
}
