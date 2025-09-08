#!/usr/bin/env bash
# Common utilities and functions for Node.js shims
# This file provides shared functionality for all Node.js tool shims

set -Eeuo pipefail

# Check if running in Docker
is_docker() {
    [ -f /.dockerenv ] || [ -f /proc/1/cgroup ] && grep -q docker /proc/1/cgroup
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
        engines_node=$(node -p "JSON.parse(require('fs').readFileSync('package.json', 'utf8')).engines?.node" 2>/dev/null || echo "null")
        if [[ "$engines_node" != "null" && "$engines_node" != "undefined" ]]; then
            local ver
            ver=$(echo "$engines_node" | sed -E 's/[<>=!]+//g' | cut -d. -f1)
            [[ -n "$ver" ]] && tag="node:${ver}-alpine"
        fi
    fi
    
    echo "${NODE_IMAGE:-$tag}"
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
    ensure_docker
    local img; img="$(resolve_image)"
    local -a args=(run --rm -it
        -v "$PWD":/work -w /work
        -v "$HOME/.npm":/root/.npm
        -v "$HOME/.cache/pnpm":/root/.cache/pnpm
        -v "$HOME/.cache/yarn":/root/.cache/yarn
        -v "$HOME/.config/pnpm":/root/.config/pnpm
        -e INIT_CWD=/work
    )

    # Add git config if it exists
    [[ -f "$HOME/.gitconfig" ]] && args+=(-v "$HOME/.gitconfig":/etc/gitconfig:ro)

    # Map ports for development servers
    if should_map_ports "$*"; then
        IFS=',' read -ra ports <<< "${DOCKER_NODE_PORTS:-3000,5173,8080,4200,3001,4000,5000}"
        for p in "${ports[@]}"; do 
            args+=(-p "${p}:${p}")
        done
    fi

    exec docker "${args[@]}" "$img" "$@"
}
