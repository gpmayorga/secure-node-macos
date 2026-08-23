#!/usr/bin/env bash
# Common utilities and functions for Node.js shims
# This file provides shared functionality for all Node.js tool shims

set -Eeuo pipefail

# Get the shims directory to exclude it from PATH searches
NODE_SHIMS_DIR="${NODE_SHIMS_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"

# Check if running in Docker
is_docker() {
    [ -f /.dockerenv ] || [ -f /proc/1/cgroup ] && grep -q docker /proc/1/cgroup
}

# Check if local override is enabled
use_local_override() {
    [[ "${NODE_SHIMS_MODE:-}" == "local" ]] || is_truthy "${NODE_SHIMS_LOCAL:-}"
}

# Check if a value is truthy (1, true, yes, on)
is_truthy() {
    local val="${1:-}"
    [[ "$val" == "1" ]] || [[ "$val" == "true" ]] || [[ "$val" == "yes" ]] || [[ "$val" == "on" ]]
}

# Execute command using local installation (bypass Docker)
exec_local() {
    local tool="$1"
    shift
    
    # Build PATH without the shims directory
    local old_path="${PATH:-}"
    local new_path=""
    IFS=':' read -ra path_parts <<< "$old_path"
    for part in "${path_parts[@]}"; do
        # Normalize paths for comparison
        local normalized_part
        normalized_part="$(cd -P "$part" 2>/dev/null && pwd || echo "$part")"
        local normalized_shims
        normalized_shims="$(cd -P "$NODE_SHIMS_DIR" 2>/dev/null && pwd || echo "$NODE_SHIMS_DIR")"
        
        if [[ "$normalized_part" != "$normalized_shims" ]]; then
            [[ -n "$new_path" ]] && new_path="${new_path}:"
            new_path="${new_path}${part}"
        fi
    done
    
    # Search for the tool in the modified PATH
    local tool_path
    tool_path="$(PATH="$new_path" command -v "$tool" 2>/dev/null || true)"
    
    if [[ -z "$tool_path" ]]; then
        echo "❌ Local override requested but '$tool' was not found outside the Docker shims." >&2
        echo "   Either install $tool locally or remove NODE_SHIMS_MODE/NODE_SHIMS_LOCAL." >&2
        exit 1
    fi
    
    # Execute the local tool
    exec "$tool_path" "$@"
}

# Ensure Docker is available and running
ensure_docker() {
    command -v docker >/dev/null 2>&1 || { echo "❌ Docker is required"; exit 1; }
    docker info >/dev/null 2>&1 || { echo "❌ Docker engine not running"; exit 1; }
}

# Resolve Node.js image tag from various sources
resolve_image() {
    local tag="node:20-alpine"
    
    # Check .nvmrc file
    if [[ -f .nvmrc ]]; then
        local ver
        ver=$(grep -Eo '[0-9]+' .nvmrc | head -1)
        [[ -n "$ver" ]] && tag="node:${ver}-alpine"
    # Check .node-version file
    elif [[ -f .node-version ]]; then
        local ver
        ver=$(grep -Eo '[0-9]+' .node-version | head -1)
        [[ -n "$ver" ]] && tag="node:${ver}-alpine"
    # Check package.json engines field
    elif [[ -f package.json ]]; then
        local engines_node
        engines_node=$(grep -o '"node"[[:space:]]*:[[:space:]]*"[^"]*"' package.json 2>/dev/null | head -1 | sed 's/.*"node"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
        if [[ -n "$engines_node" && "$engines_node" != "null" && "$engines_node" != "undefined" ]]; then
            local ver
            ver=$(echo "$engines_node" | sed -E 's/[<>=!]+//g' | cut -d. -f1)
            [[ -n "$ver" ]] && tag="node:${ver}-alpine"
        fi
    fi
    
    echo "${NODE_IMAGE:-$tag}"
}

# Check if Docker socket should be mounted (for npm scripts that run docker)
use_docker_socket() {
    [[ "${NODE_SHIMS_DOCKER:-}" == "1" ]] || is_truthy "${NODE_SHIMS_DOCKER:-}"
}

# Populate __SHIM_PROJECT_MOUNTS so the project is visible at its real host
# path. Remapping $PWD -> /work alone makes `node /Users/.../script.js` 404
# inside the container even when the file is under $PWD. /work stays as an
# alias for anything that still assumes that layout.
prepare_project_mounts() {
    local logical physical
    logical="$(pwd)"
    physical="$(pwd -P)"
    __SHIM_PROJECT_MOUNTS=(
        -v "$physical":"$physical"
        -v "$physical":/work
        -w "$logical"
        -e "INIT_CWD=$logical"
    )
    if [[ "$logical" != "$physical" ]]; then
        __SHIM_PROJECT_MOUNTS+=(-v "$physical":"$logical")
    fi
    __SHIM_WORKDIR_PHYSICAL="$physical"
}

# Bind extra absolute argv paths that exist on the host but sit outside $PWD.
# Mount the path itself (file or directory), never $HOME or /. Callers that
# pass --config=/tmp/foo.json then keep working without widening isolation
# to the whole home directory.
append_extra_host_mounts() {
    local work_dir="$1"
    shift
    local arg path resolved seen=""
    for arg in "$@"; do
        path=""
        case "$arg" in
            --*=/*) path="${arg#*=}" ;;
            /*) path="$arg" ;;
            *) continue ;;
        esac
        [[ -e "$path" ]] || continue
        if [[ -d "$path" ]]; then
            resolved="$(cd "$path" && pwd -P)"
        else
            resolved="$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
        fi
        if [[ "$resolved" == "$work_dir" || "$resolved" == "$work_dir/"* ]]; then
            continue
        fi
        if [[ "$resolved" == "/" || "$resolved" == "$HOME" ]]; then
            continue
        fi
        case "$work_dir" in
            "$resolved"/*) continue ;;
        esac
        case ":$seen:" in
            *":$resolved:"*) continue ;;
        esac
        seen="${seen:+$seen:}$resolved"
        __SHIM_PROJECT_MOUNTS+=(-v "$resolved":"$resolved")
        # macOS /tmp -> /private/tmp: callers still pass the logical path.
        if [[ "$path" != "$resolved" ]]; then
            __SHIM_PROJECT_MOUNTS+=(-v "$resolved":"$path")
        fi
        if is_truthy "${NODE_SHIMS_DEBUG:-}"; then
            echo "node-shims: mounting extra host path: $path -> $resolved" >&2
        fi
    done
}

# node is sometimes invoked to run a host script outside $PWD (e.g. Cursor's
# esbuild-wasm service: node /Applications/Cursor.app/.../esbuild-wasm/bin/esbuild).
# Those paths are not the project mount, and the binary is often macOS-native
# (Alpine cannot exec it). Fall back to a real host node instead of failing.
needs_host_node() {
    local tool="$1"
    shift
    [[ "$tool" == "node" ]] || return 1

    local arg script_path="" work_dir
    work_dir="$(pwd -P)"

    for arg in "$@"; do
        case "$arg" in
            -*) continue ;;
            *)
                if [[ "$arg" == /* ]]; then
                    script_path="$arg"
                elif [[ -f "$arg" ]]; then
                    script_path="$(cd "$(dirname "$arg")" && pwd -P)/$(basename "$arg")"
                else
                    return 1
                fi

                if [[ ! -f "$script_path" ]]; then
                    return 1
                fi

                # Compare physical paths: on macOS pwd and pwd -P differ
                # (/var vs /private/var), which would treat in-tree scripts
                # as off-tree and skip Docker for ordinary project files.
                local script_dir
                script_dir="$(cd "$(dirname "$script_path")" && pwd -P)"
                if [[ "$script_dir" == "$work_dir" || "$script_dir" == "$work_dir/"* ]]; then
                    return 1
                fi

                if is_truthy "${NODE_SHIMS_DEBUG:-}"; then
                    echo "node-shims: using host node for script outside \$PWD: $script_path" >&2
                fi
                return 0
                ;;
        esac
    done
    return 1
}

# Check if command should map ports (for dev servers)
should_map_ports() {
    local cmd="$*"
    if [[ "$cmd" =~ (dev|start|serve|vite|nuxt|next|webpack|rollup) ]]; then
        return 0
    fi
    return 1
}

# Execute command in Docker container
docker_exec() {
    local tool="$1"
    shift

    # Check if local override is enabled
    if use_local_override; then
        exec_local "$tool" "$@"
    fi

    if needs_host_node "$tool" "$@"; then
        exec_local "$tool" "$@"
    fi

    ensure_docker
    local img; img="$(resolve_image)"
    prepare_project_mounts
    append_extra_host_mounts "$__SHIM_WORKDIR_PHYSICAL" "$@"
    local -a args=(run --rm
        "${__SHIM_PROJECT_MOUNTS[@]}"
        -v "$HOME/.npm":/root/.npm
        -v "$HOME/.npmrc":/root/.npmrc
        -v "$HOME/.cache/pnpm":/root/.cache/pnpm
        -v "$HOME/.cache/yarn":/root/.cache/yarn
        -v "$HOME/.config/pnpm":/root/.config/pnpm
        -e COREPACK_ENABLE_STRICT=0
        -e COREPACK_ENABLE_NETWORK=1
    )
    
    # Ensure host .npmrc exists so npm login persists across runs
    if [[ ! -f "$HOME/.npmrc" ]]; then
        : > "$HOME/.npmrc" || true
        chmod 600 "$HOME/.npmrc" 2>/dev/null || true
    fi
    
    # Add interactive mode only if we have a TTY and it's not a simple version check
    if [[ -t 0 && -t 1 && ! "$*" =~ (--version|--help|-v|-h) ]]; then
        args+=(-it)
    fi

    # Add git config if it exists
    [[ -f "$HOME/.gitconfig" ]] && args+=(-v "$HOME/.gitconfig":/etc/gitconfig:ro)

    # Mount Docker socket so npm scripts can run docker (e.g. docker build, docker run)
    if use_docker_socket; then
        local docker_sock=""
        if [[ -S /var/run/docker.sock ]]; then
            docker_sock=/var/run/docker.sock
        elif [[ -S "${HOME:-}/.docker/run/docker.sock" ]]; then
            docker_sock="${HOME}/.docker/run/docker.sock"
        fi
        if [[ -n "$docker_sock" ]]; then
            args+=(-v "$docker_sock":/var/run/docker.sock -e NODE_SHIMS_DOCKER=1)
        else
            echo "❌ Docker socket not found (check /var/run/docker.sock or ~/.docker/run/docker.sock). Is Docker Desktop running?" >&2
            exit 1
        fi
    fi

    # Map ports for development servers
    if should_map_ports "$*"; then
        IFS=',' read -ra ports <<< "${DOCKER_NODE_PORTS:-3000,5173,8080,4200,3001,4000,5000,8787}"
        for p in "${ports[@]}"; do 
            args+=(-p "${p}:${p}")
        done
    fi

    # Wrangler login launches an OAuth callback server on localhost.
    # Ensure that port is bridged so the host browser can talk to the container.
    if [[ "$*" =~ wrangler[[:space:]]+login ]]; then
        local login_port="${WRANGLER_LOGIN_PORT:-8976}"
        args+=(-p "${login_port}:${login_port}")
    fi

    # Enable corepack; if Docker socket is mounted, install docker-cli so npm scripts can run docker
    local setup="corepack enable >/dev/null 2>&1 || true; corepack install >/dev/null 2>&1 || true"
    if use_docker_socket; then
        setup="$setup; apk add --no-cache docker-cli >/dev/null 2>&1 || true"
    fi
    exec docker "${args[@]}" "$img" sh -c "$setup; exec \"\$@\"" -- "$tool" "$@"
}
