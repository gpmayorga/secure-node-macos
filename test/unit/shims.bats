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
if [[ -n "${FAKE_DOCKER_DOWN:-}" ]]; then
    echo "Cannot connect to the Docker daemon. Is the docker daemon running?" >&2
    exit 1
fi
printf '%s\n' "$@" > "$DOCKER_ARGS_LOG"
EOF
    chmod +x "$STUB_DIR/docker"

    export HOME="$STUB_DIR/home"
    mkdir -p "$HOME"
    export PATH="$SHIMS_DIR:$STUB_DIR:/usr/bin:/bin"
    unset NODE_IMAGE NODE_SHIMS_MODE NODE_SHIMS_LOCAL NODE_SHIMS_DOCKER DOCKER_NODE_PORTS NODE_SHELL_NO_PORTS
    unset NODE_SHIMS_NO_PLATFORM_WARNING NODE_SHIMS_WORKSPACE
    # Host Cloudflare/wrangler settings must never leak into a test.
    local name
    while IFS= read -r name; do
        case "$name" in
            CLOUDFLARE_*|WRANGLER_*|NODE_SHIMS_WRANGLER*) unset "$name" ;;
        esac
    done < <(compgen -e)
    WRANGLER_STORE="$HOME/.config/node-shims/wrangler"

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
    for tool in node npm npx yarn pnpm corepack; do
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

@test "wrangler login needs confirmation and publishes the callback port on loopback" {
    require_detachable_tty
    run without_tty npx wrangler login
    [ "$status" -ne 0 ]
    [ ! -e "$DOCKER_ARGS_LOG" ]

    export NODE_SHIMS_WRANGLER_YES=1
    npx wrangler login
    docker_args_have -p "127.0.0.1:8976:8976"
    run ! grep -qx -- '8976:8976' "$DOCKER_ARGS_LOG"

    WRANGLER_LOGIN_PORT=9797 npx wrangler login
    docker_args_have -p "127.0.0.1:9797:9797"
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

@test "a stopped docker engine surfaces as a failing call" {
    FAKE_DOCKER_DOWN=1 run node --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cannot connect to the Docker daemon"* ]]
}

@test "corepack is set up only for calls that may need yarn or pnpm" {
    corepack_in_setup() { grep -A1 -x -- '-c' "$DOCKER_ARGS_LOG" | tail -1 | grep -q corepack; }

    node --version
    run ! corepack_in_setup

    yarn --version
    corepack_in_setup

    echo '{"packageManager":"pnpm@11.28.10"}' > package.json
    node --version
    corepack_in_setup

    rm package.json
    NODE_SHIMS_COREPACK=1 node --version
    corepack_in_setup
}

@test "corepack shim always sets up corepack, including the pinned copy for Node 25+" {
    setup_script() { grep -A1 -x -- '-c' "$DOCKER_ARGS_LOG" | tail -1; }

    corepack --version
    [ "$(tail -2 "$DOCKER_ARGS_LOG")" = "$(printf '%s\n%s' corepack --version)" ]
    # Images without corepack get the pinned copy on PATH before the call.
    setup_script | grep -q '/opt/node-shims-corepack/bin'
    setup_script | grep -q "corepack@0.36.0"
    docker_args_have -v "$HOME/.cache/node-shims/corepack:/opt/node-shims-corepack"

    NODE_SHIMS_COREPACK_VERSION=0.31.0 corepack pnpm --version
    setup_script | grep -q "corepack@0.31.0"
    [ "$(tail -3 "$DOCKER_ARGS_LOG")" = "$(printf '%s\n%s\n%s' corepack pnpm --version)" ]
}

@test "corepack local override runs the host corepack" {
    mkdir "$STUB_DIR/host"
    printf '#!/bin/sh\necho "host corepack $*"\n' > "$STUB_DIR/host/corepack"
    chmod +x "$STUB_DIR/host/corepack"

    # The shim comes first on PATH, so it wins over the host copy at the end.
    PATH="$PATH:$STUB_DIR/host" run corepack --version
    [ "$status" -eq 0 ]
    [ -e "$DOCKER_ARGS_LOG" ]
    rm "$DOCKER_ARGS_LOG"

    PATH="$PATH:$STUB_DIR/host" NODE_SHIMS_MODE=local run corepack --version
    [ "$status" -eq 0 ]
    [ "$output" = "host corepack --version" ]
    [ ! -e "$DOCKER_ARGS_LOG" ]
}

@test "corepack dev-server calls map ports" {
    corepack pnpm dev
    docker_args_have -p "5173:5173"

    corepack --version
    run ! grep -qx -- '-p' "$DOCKER_ARGS_LOG"
}

@test "pnpm store is mounted at the host default path, npm never sees store-dir" {
    printf '#!/bin/sh\necho Darwin\n' > "$STUB_DIR/uname"
    chmod +x "$STUB_DIR/uname"
    local store="$HOME/Library/pnpm/store"

    pnpm install
    docker_args_have -v "$store:$store"
    docker_args_have -e "pnpm_config_store_dir=$store"
    docker_args_have -e "npm_config_store_dir=$store"

    npm install
    docker_args_have -v "$store:$store"
    run ! grep -q '^npm_config_store_dir=' "$DOCKER_ARGS_LOG"

    PNPM_HOME="$HOME/pnpm-home" pnpm install
    docker_args_have -e "pnpm_config_store_dir=$HOME/pnpm-home/store"
}

@test "node-shell mounts the corepack dir and bootstraps it like docker_exec" {
    node-shell
    docker_args_have -v "$HOME/.cache/node-shims/corepack:/opt/node-shims-corepack"
    docker_args_have -v "$HOME/.yarn/berry:$HOME/.yarn/berry"
    docker_args_have -e "YARN_GLOBAL_FOLDER=$HOME/.yarn/berry"
    docker_args_have -e "pnpm_config_store_dir=$HOME/.local/share/pnpm/store"
    [ -d "$HOME/.cache/node-shims/corepack" ]

    local shell_setup
    shell_setup="$(tail -1 "$DOCKER_ARGS_LOG")"
    [[ "$shell_setup" == *"corepack@0.36.0"* ]]
    [[ "$shell_setup" == *"; exec sh" ]]

    # The tool shims run the exact same bootstrap before a tool that needs it.
    yarn --version
    local exec_setup
    exec_setup="$(grep -A1 -x -- '-c' "$DOCKER_ARGS_LOG" | tail -1)"
    [ "${shell_setup%; exec sh}" = "${exec_setup%; exec \"\$@\"}" ]
}

@test "node-shell maps the same default dev ports as the tool shims" {
    node-shell
    docker_args_have -p "5173:5173"
    docker_args_have -p "8787:8787"
}

@test "node-shell honours DOCKER_NODE_PORTS and NODE_SHELL_NO_PORTS" {
    DOCKER_NODE_PORTS="4321" node-shell
    docker_args_have -p "4321:4321"
    run ! docker_args_have -p "3000:3000"

    NODE_SHELL_NO_PORTS=1 node-shell
    run ! grep -qx -- '-p' "$DOCKER_ARGS_LOG"
}

# --- Wrangler credential scoping -------------------------------------------

WRANGLER_DEST=/root/.config/.wrangler

make_wrangler_project() {
    printf 'name = "w"\nmain = "src/index.js"\n' > wrangler.toml
    cat > package.json <<'JSON'
{
  "scripts": {
    "deploy": "wrangler deploy",
    "deploy-prod": "wrangler deploy --env production",
    "dev": "wrangler dev",
    "build": "node build.js"
  },
  "devDependencies": {
    "wrangler": "^4.0.0"
  }
}
JSON
}

# A stored wrangler auth profile with a dummy token that must never reach argv.
add_profile() {
    mkdir -p "$WRANGLER_STORE/config"
    printf 'oauth_token = "dummy-%s-oauth-token"\n' "$1" > "$WRANGLER_STORE/config/$1.toml"
}

# Run a shim command line (one string, word-split) and require that docker ran.
run_shim() {
    local -a cmd
    read -ra cmd <<< "$1"
    rm -f "$DOCKER_ARGS_LOG"
    "${cmd[@]}" 2>/dev/null
    [ -e "$DOCKER_ARGS_LOG" ] || { echo "docker did not run for: $1" >&2; return 1; }
}

profile_mounted() {
    docker_args_have -v "$WRANGLER_STORE/config/$1.toml:$WRANGLER_DEST/config/$1.toml"
}

# True when the recorded argv carries no Cloudflare env, config mount or token.
no_wrangler_credentials() {
    ! grep -Eq 'CLOUDFLARE_|WRANGLER_|\.wrangler|dummy-' "$DOCKER_ARGS_LOG"
}

# Without a controlling terminal, even when bats itself runs in one.
without_tty() {
    if command -v setsid >/dev/null 2>&1; then
        setsid -w "$@"
    else
        "$@"
    fi
}

# The wrangler prompt reads /dev/tty. Without setsid (macOS) a test run
# from a terminal would block on it, so the no-terminal checks skip there.
require_detachable_tty() {
    command -v setsid >/dev/null 2>&1 && return 0
    if { : </dev/tty; } 2>/dev/null; then
        skip "needs setsid to run without a terminal"
    fi
}

@test "wrangler calls that need the API get the config mount and env by name only" {
    make_wrangler_project
    add_profile default
    export NODE_SHIMS_WRANGLER_YES=1
    export CLOUDFLARE_ACCOUNT_ID=dummy-account-id WRANGLER_SEND_METRICS=dummy-metrics
    local calls=(
        "npx wrangler deploy"
        "npx -y wrangler@4 whoami"
        "pnpm exec wrangler secret list"
        "yarn dlx wrangler deploy"
        "node node_modules/.bin/wrangler deploy"
        "npx wrangler dev --remote"
        "npm run deploy"
        "pnpm deploy-prod"
    )
    local call
    for call in "${calls[@]}"; do
        run_shim "$call"
        docker_args_have -e CLOUDFLARE_ACCOUNT_ID || { echo "no env: $call"; return 1; }
        docker_args_have -e WRANGLER_SEND_METRICS
        docker_args_have -v "$WRANGLER_STORE:$WRANGLER_DEST"
        profile_mounted default || { echo "no profile: $call"; return 1; }
        run ! grep -q 'dummy-' "$DOCKER_ARGS_LOG"
    done
}

@test "calls in a wrangler project that do not need the API get no credentials" {
    make_wrangler_project
    add_profile default
    export NODE_SHIMS_WRANGLER_YES=1
    export CLOUDFLARE_API_TOKEN=dummy-api-token CLOUDFLARE_ACCOUNT_ID=dummy-account-id
    local calls=(
        "npm install"
        "npm i -D wrangler"
        "pnpm add wrangler"
        "yarn"
        "npm ls"
        "npm run build"
        "npm run dev"
        "node script.js"
        "npx wrangler"
        "npx wrangler --version"
        "npx wrangler deploy --help"
        "npx wrangler deploy --dry-run"
        "npx wrangler versions upload --dry-run"
        "npx wrangler dev"
        "npx wrangler pages dev ./public"
        "npx wrangler types"
        "npx wrangler build"
        "npx wrangler pages functions build"
        "pnpm --filter api run deploy"
    )
    local call
    for call in "${calls[@]}"; do
        run_shim "$call"
        no_wrangler_credentials || { echo "credentials leaked to: $call"; return 1; }
    done
}

@test "wrangler scripts are found in a minified package.json" {
    printf 'name = "w"\n' > wrangler.toml
    # One line, a nested object before "scripts", and a script with braces.
    printf '%s\n' '{"name":"w","config":{"a":{"b":1}},"scripts":{"lint":"node -e \"if(1){}\"","build":"node build.js","deploy":"wrangler deploy --env prod"},"devDependencies":{"wrangler":"^4.0.0"}}' > package.json
    add_profile default
    export NODE_SHIMS_WRANGLER_YES=1 CLOUDFLARE_ACCOUNT_ID=dummy-account-id

    run_shim "pnpm run deploy"
    docker_args_have -e CLOUDFLARE_ACCOUNT_ID
    profile_mounted default

    run_shim "npm run build"
    no_wrangler_credentials
    run_shim "npm run lint"
    no_wrangler_credentials
}

@test "pnpm and yarn built-ins never get credentials, even when a script has the same name" {
    # Built-ins win over scripts of the same name, and several of them
    # install dependencies, so their lifecycle scripts must not see a token.
    printf 'name = "w"\n' > wrangler.toml
    cat > package.json <<'JSON'
{
  "scripts": {
    "deploy": "wrangler deploy",
    "install": "wrangler deploy",
    "add": "wrangler deploy",
    "update": "wrangler deploy",
    "up": "wrangler deploy",
    "rebuild": "wrangler deploy",
    "dedupe": "wrangler deploy",
    "import": "wrangler deploy",
    "link": "wrangler deploy",
    "remove": "wrangler deploy",
    "pack": "wrangler deploy",
    "publish": "wrangler deploy",
    "exec": "wrangler deploy",
    "dlx": "wrangler deploy"
  }
}
JSON
    add_profile default
    export NODE_SHIMS_WRANGLER_YES=1
    export CLOUDFLARE_API_TOKEN=dummy-api-token CLOUDFLARE_ACCOUNT_ID=dummy-account-id
    local calls=(
        "pnpm deploy ../out"
        "pnpm --prod deploy ../out"
        "pnpm install"
        "pnpm add left-pad"
        "pnpm update"
        "pnpm up"
        "pnpm rebuild"
        "pnpm dedupe"
        "pnpm import"
        "pnpm link ../lib"
        "pnpm remove left-pad"
        "pnpm pack"
        "pnpm publish"
        "yarn install"
        "yarn add left-pad"
        "yarn up"
        "yarn rebuild"
        "yarn dedupe"
        "yarn link ../lib"
        "yarn remove left-pad"
        "yarn pack"
    )
    local call
    for call in "${calls[@]}"; do
        run_shim "$call"
        no_wrangler_credentials || { echo "credentials leaked to: $call"; return 1; }
    done

    # `run` still reaches the script, so it still gets them.
    run_shim "pnpm run deploy"
    docker_args_have -e CLOUDFLARE_API_TOKEN
}

@test "wrangler dev gets credentials when the config or flags need Cloudflare" {
    export NODE_SHIMS_WRANGLER_YES=1 CLOUDFLARE_ACCOUNT_ID=dummy-account-id
    local configs=(
        'wrangler.toml:[[kv_namespaces]]\nbinding = "KV"\nid = "x"\nremote = true\n'
        'wrangler.toml:[ai]\nbinding = "AI"\n'
        'wrangler.toml:[[vectorize]]\nbinding = "V"\nindex_name = "i"\n'
        'wrangler.jsonc:{ "ai": { "binding": "AI" } }\n'
    )
    local entry
    for entry in "${configs[@]}"; do
        rm -f wrangler.toml wrangler.jsonc
        # shellcheck disable=SC2059  # the table holds printf formats
        printf "${entry#*:}" > "${entry%%:*}"
        run_shim "npx wrangler dev"
        docker_args_have -e CLOUDFLARE_ACCOUNT_ID || { echo "no credentials for: $entry"; return 1; }
    done

    rm -f wrangler.jsonc
    make_wrangler_project
    run_shim "npx wrangler dev --config other.toml"
    docker_args_have -e CLOUDFLARE_ACCOUNT_ID
}

@test "an API token in the environment is forwarded by name and no profile is mounted" {
    make_wrangler_project
    add_profile default
    CLOUDFLARE_API_TOKEN=dummy-api-token npx wrangler deploy

    docker_args_have -e CLOUDFLARE_API_TOKEN
    run ! grep -q 'dummy-' "$DOCKER_ARGS_LOG"
    run ! grep -q '/config/default.toml' "$DOCKER_ARGS_LOG"
}

@test "only the resolved wrangler profile is mounted, other profiles never are" {
    make_wrangler_project
    add_profile default
    add_profile dev
    add_profile prod
    export NODE_SHIMS_WRANGLER_YES=1

    npx wrangler deploy
    docker_args_have --mount "type=tmpfs,destination=$WRANGLER_DEST/config"
    profile_mounted default
    run ! grep -Eq '/(dev|prod)\.toml' "$DOCKER_ARGS_LOG"

    npx wrangler deploy --profile prod
    profile_mounted prod
    run ! grep -Eq '/(default|dev)\.toml' "$DOCKER_ARGS_LOG"

    npx wrangler deploy --profile=dev
    profile_mounted dev
    run ! grep -Eq '/(default|prod)\.toml' "$DOCKER_ARGS_LOG"
}

@test "a directory binding on a parent folder picks that profile" {
    make_wrangler_project
    add_profile default
    add_profile dev
    add_profile prod
    mkdir -p "$WRANGLER_STORE/profiles"
    printf '{\n  "%s": "dev"\n}\n' "$(dirname "$PROJECT_DIR")" \
        > "$WRANGLER_STORE/profiles/directory-bindings.json"

    NODE_SHIMS_WRANGLER_YES=1 npx wrangler deploy
    profile_mounted dev
    run ! grep -Eq '/(default|prod)\.toml' "$DOCKER_ARGS_LOG"
}

@test "a missing profile mounts nothing and an invalid profile name is refused" {
    make_wrangler_project
    add_profile prod

    # No profile file to protect, so no prompt is needed either.
    run without_tty npx wrangler deploy --profile staging
    [ "$status" -eq 0 ]
    run ! grep -q '\.toml' "$DOCKER_ARGS_LOG"

    rm -f "$DOCKER_ARGS_LOG"
    NODE_SHIMS_WRANGLER_YES=1 run npx wrangler deploy --profile ../config/prod
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid wrangler profile name"* ]]
    [ ! -e "$DOCKER_ARGS_LOG" ]
}

@test "mounting a profile without a terminal is refused unless NODE_SHIMS_WRANGLER_YES=1" {
    make_wrangler_project
    add_profile default

    require_detachable_tty
    run without_tty npx wrangler deploy
    [ "$status" -ne 0 ]
    [[ "$output" == *"NODE_SHIMS_WRANGLER_YES=1"* ]]
    [ ! -e "$DOCKER_ARGS_LOG" ]

    NODE_SHIMS_WRANGLER_YES=1 run without_tty npx wrangler deploy
    [ "$status" -eq 0 ]
    profile_mounted default
}

@test "wrangler auth list sees profile names through empty stand-ins, never tokens" {
    make_wrangler_project
    add_profile dev
    add_profile prod

    run without_tty npx wrangler auth list
    [ "$status" -eq 0 ]
    docker_args_have -v "$WRANGLER_STORE/.empty:$WRANGLER_DEST/config/dev.toml:ro"
    docker_args_have -v "$WRANGLER_STORE/.empty:$WRANGLER_DEST/config/prod.toml:ro"
    run ! grep -q "$WRANGLER_STORE/config/" "$DOCKER_ARGS_LOG"
    [ ! -s "$WRANGLER_STORE/.empty" ]
}

@test "NODE_SHIMS_WRANGLER_AUTH and NODE_SHIMS_WRANGLER override the credential gate" {
    make_wrangler_project
    add_profile default
    export NODE_SHIMS_WRANGLER_YES=1 CLOUDFLARE_ACCOUNT_ID=dummy-account-id

    NODE_SHIMS_WRANGLER_AUTH=0 npx wrangler deploy
    no_wrangler_credentials

    NODE_SHIMS_WRANGLER=0 npx wrangler deploy
    no_wrangler_credentials

    NODE_SHIMS_WRANGLER_AUTH=1 pnpm --filter api run deploy
    docker_args_have -e CLOUDFLARE_ACCOUNT_ID
    profile_mounted default
}

@test "NODE_SHIMS_WRANGLER_CONFIG_DIR=none forwards env but mounts no config" {
    make_wrangler_project
    add_profile default
    CLOUDFLARE_ACCOUNT_ID=dummy-account-id NODE_SHIMS_WRANGLER_CONFIG_DIR=none \
        npx wrangler deploy

    docker_args_have -e CLOUDFLARE_ACCOUNT_ID
    run ! grep -q '\.wrangler' "$DOCKER_ARGS_LOG"
}

@test "wrangler login mounts only the default profile and adds callback flags" {
    make_wrangler_project
    add_profile prod
    export NODE_SHIMS_WRANGLER_YES=1

    npx wrangler login
    profile_mounted default
    run ! grep -q 'prod\.toml' "$DOCKER_ARGS_LOG"
    [ -f "$WRANGLER_STORE/config/default.toml" ]
    local flag
    for flag in --callback-host=0.0.0.0 --callback-port=8976 --browser=false; do
        grep -qx -- "$flag" "$DOCKER_ARGS_LOG"
    done

    npx wrangler login --device
    run ! grep -q -- '--callback-' "$DOCKER_ARGS_LOG"
    run ! grep -q '8976' "$DOCKER_ARGS_LOG"
}

@test "wrangler projects and wrangler calls use the bookworm image unless NODE_IMAGE is set" {
    local default_major
    default_major="$(grep -o 'node:[0-9]*-alpine' "$SHIMS_DIR/common.sh" | head -1)"

    npx wrangler --version
    [ "$(recorded_image)" = "${default_major%-alpine}-bookworm" ]

    make_wrangler_project
    npm install
    [ "$(recorded_image)" = "${default_major%-alpine}-bookworm" ]

    echo '22' > .nvmrc
    npm install
    [ "$(recorded_image)" = "node:22-bookworm" ]

    NODE_IMAGE=node:22-alpine npm install
    [ "$(recorded_image)" = "node:22-alpine" ]
}

@test "wrangler dev in argv gets --ip=0.0.0.0 unless the user or FLAGS=0 says otherwise" {
    make_wrangler_project
    local call
    for call in "npx wrangler dev" "npx wrangler pages dev ./public"; do
        run_shim "$call"
        grep -qx -- '--ip=0.0.0.0' "$DOCKER_ARGS_LOG"
    done

    npx wrangler dev --ip 127.0.0.1
    run ! grep -qx -- '--ip=0.0.0.0' "$DOCKER_ARGS_LOG"

    NODE_SHIMS_WRANGLER_FLAGS=0 npx wrangler dev
    run ! grep -qx -- '--ip=0.0.0.0' "$DOCKER_ARGS_LOG"

    # From a package.json script the shim cannot add flags (README: set [dev] ip).
    npm run dev
    run ! grep -qx -- '--ip=0.0.0.0' "$DOCKER_ARGS_LOG"
}

# --- node_modules platform marker ------------------------------------------

MARKER=node_modules/.node-shims-platform

# Pin the host to Linux aarch64 so platform strings are predictable.
fake_arm64_linux() {
    printf '#!/bin/sh\ncase "$1" in -m) echo aarch64 ;; *) echo Linux ;; esac\n' > "$STUB_DIR/uname"
    chmod +x "$STUB_DIR/uname"
}

@test "install commands record the container platform in node_modules" {
    fake_arm64_linux
    mkdir node_modules
    local call
    for call in "npm install" "npm ci" "pnpm add left-pad" "yarn add left-pad" \
        "corepack pnpm install" "corepack pnpm@11.28.10 add left-pad" "corepack yarn" \
        "corepack use pnpm@11.28.10"; do
        rm -f "$MARKER"
        run_shim "$call"
        [ "$(cat "$MARKER")" = "linux-arm64-musl" ] || { echo "no marker for: $call"; return 1; }
    done

    make_wrangler_project
    npm install
    [ "$(cat "$MARKER")" = "linux-arm64-glibc" ]
}

@test "non-install commands neither record nor rewrite the platform marker" {
    fake_arm64_linux
    mkdir node_modules
    node --version
    [ ! -e "$MARKER" ]
    corepack pnpm --version
    corepack enable
    corepack --version
    [ ! -e "$MARKER" ]

    echo darwin-arm64 > "$MARKER"
    local call
    for call in "node index.js" "yarn --version" "yarn -v" "yarn --help" \
        "npm install --help" "pnpm add -h" "npm i --version"; do
        run_shim "$call"
        [ "$(cat "$MARKER")" = "darwin-arm64" ] || { echo "marker rewritten by: $call"; return 1; }
    done
}

@test "bare yarn is still an install and records the platform" {
    fake_arm64_linux
    mkdir node_modules
    local call
    for call in "yarn" "yarn --frozen-lockfile"; do
        rm -f "$MARKER"
        run_shim "$call"
        [ "$(cat "$MARKER")" = "linux-arm64-musl" ] || { echo "no marker for: $call"; return 1; }
    done
}

@test "a run warns when node_modules was installed for another platform, and still runs" {
    fake_arm64_linux
    mkdir node_modules
    echo darwin-arm64 > "$MARKER"

    run node index.js
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed for darwin-arm64"* ]]
    [[ "$output" == *"this run is linux-arm64-musl"* ]]
    [ -e "$DOCKER_ARGS_LOG" ]
}

@test "alpine-installed node_modules warn in a wrangler project (bookworm)" {
    fake_arm64_linux
    make_wrangler_project
    mkdir node_modules
    echo linux-arm64-musl > "$MARKER"

    run npx wrangler --version
    [[ "$output" == *"this run is linux-arm64-glibc"* ]]
}

@test "no platform warning when the marker matches, is missing, or is silenced" {
    fake_arm64_linux
    mkdir node_modules

    run node index.js
    [[ "$output" != *"installed for"* ]]

    echo linux-arm64-musl > "$MARKER"
    run node index.js
    [[ "$output" != *"installed for"* ]]

    echo darwin-arm64 > "$MARKER"
    NODE_SHIMS_NO_PLATFORM_WARNING=1 run node index.js
    [[ "$output" != *"installed for"* ]]
}

@test "local mode checks and records the host platform" {
    fake_arm64_linux
    mkdir "$STUB_DIR/host" node_modules
    local t
    for t in node npm; do
        printf '#!/bin/sh\necho "host %s $*"\n' "$t" > "$STUB_DIR/host/$t"
        chmod +x "$STUB_DIR/host/$t"
    done
    export PATH="$PATH:$STUB_DIR/host" NODE_SHIMS_MODE=local
    echo linux-arm64-musl > "$MARKER"

    run node -v
    [[ "$output" == *"this run is linux-arm64."* ]]
    [[ "$output" == *"host node -v"* ]]

    run npm install
    [ "$status" -eq 0 ]
    [ "$(cat "$MARKER")" = "linux-arm64" ]
    [ ! -e "$DOCKER_ARGS_LOG" ]
}

@test "host node fallback for scripts outside the project skips the platform check" {
    fake_arm64_linux
    mkdir "$STUB_DIR/host" "$STUB_DIR/app" node_modules
    printf '#!/bin/sh\necho "host node $*"\n' > "$STUB_DIR/host/node"
    chmod +x "$STUB_DIR/host/node"
    touch "$STUB_DIR/app/esbuild.js"
    echo darwin-arm64 > "$MARKER"

    PATH="$PATH:$STUB_DIR/host" run node "$STUB_DIR/app/esbuild.js"
    [ "$output" = "host node $STUB_DIR/app/esbuild.js" ]
}
