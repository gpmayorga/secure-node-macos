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
    
    # Execute the local tool. Explicit local mode also gets the
    # node_modules platform check; the host-node fallback for scripts
    # outside $PWD does not use the project's packages, so it skips it.
    if [[ "${__SHIM_PLATFORM_GUARD:-0}" == 1 ]]; then
        __SHIM_TOOL_ARGV=("$@")
        run_with_platform_marker "$tool" "$(host_platform)" "$tool_path" "$@"
    fi
    exec "$tool_path" "$@"
}

# Ensure Docker is available and running
ensure_docker() {
    command -v docker >/dev/null 2>&1 || { echo "❌ Docker is required"; exit 1; }
    docker info >/dev/null 2>&1 || { echo "❌ Docker engine not running"; exit 1; }
}

# Resolve Node.js image tag from various sources
resolve_image() {
    local tag="node:26-alpine"
    
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
    local logical physical root logical_root
    logical="$(pwd)"
    physical="$(pwd -P)"
    # Inside a workspace package, mount the workspace root: pnpm links
    # node_modules/<dep> to <root>/node_modules/.pnpm, and npm/yarn hoist
    # deps to <root>/node_modules, so the package dir alone is not enough.
    root="$(find_workspace_root "$physical" || true)"
    [[ -n "$root" ]] || root="$physical"
    # Same root on the logical path (macOS /tmp -> /private/tmp), when the
    # logical cwd ends with the same path below the root.
    logical_root="$root"
    if [[ "$logical" != "$physical" ]]; then
        local rel="${physical#"$root"}"
        if [[ -z "$rel" ]]; then
            logical_root="$logical"
        elif [[ "$logical" == *"$rel" ]]; then
            logical_root="${logical%"$rel"}"
        fi
    fi
    __SHIM_PROJECT_MOUNTS=(
        -v "$root":"$root"
        -v "$physical":/work
        -w "$logical"
        -e "INIT_CWD=$logical"
    )
    if [[ "$logical_root" != "$root" ]]; then
        __SHIM_PROJECT_MOUNTS+=(-v "$root":"$logical_root")
    fi
    if [[ "$root" != "$physical" ]] && is_truthy "${NODE_SHIMS_DEBUG:-}"; then
        echo "node-shims: mounting workspace root: $root" >&2
    fi
    __SHIM_WORKDIR_PHYSICAL="$physical"
    __SHIM_MOUNT_ROOT_PHYSICAL="$root"
}

# Print the nearest parent of $1 (physical path) that is a JS workspace
# root: has pnpm-workspace.yaml, or a package.json with "workspaces".
# Stops below $HOME and /, so neither is ever mounted. NODE_SHIMS_WORKSPACE=0
# turns this off.
find_workspace_root() {
    local dir="$1" home_physical
    if [[ -n "${NODE_SHIMS_WORKSPACE:-}" ]] && ! is_truthy "$NODE_SHIMS_WORKSPACE"; then
        return 1
    fi
    home_physical="$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"
    while [[ -n "$dir" && "$dir" != "/" && "$dir" != "$home_physical" ]]; do
        if [[ -f "$dir/pnpm-workspace.yaml" ]] \
            || { [[ -f "$dir/package.json" ]] && grep -q '"workspaces"[[:space:]]*:' "$dir/package.json"; }; then
            printf '%s\n' "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
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

# True only when this shim is the direct child of `op run`. `op` does not
# need to be installed: any other parent (zsh, npm, Cursor, …) is a no-op.
# `op item` / `op read` do not match — only the `run` verb, which is what
# injects a 1Password env-file into this process.
parent_is_op_run() {
    local pid comm args
    pid="${PPID:-}"
    [[ -n "$pid" && "$pid" != "0" ]] || return 1
    comm="$(ps -p "$pid" -o comm= 2>/dev/null | awk '{print $1}')"
    comm="${comm##*/}"
    [[ "$comm" == "op" ]] || return 1
    args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    [[ "$args" == 'op run'* || "$args" == *' run '* ]]
}

# `op run --env-file=.env -- node …` resolves a (possibly FIFO) env file on
# the host and puts those vars in this process. Docker does not inherit them
# unless we pass `-e NAME` (value taken from the current environment, so
# secrets stay off argv). Never read or mount the FIFO.
# No-op when the parent is not `op run`.
append_op_run_env() {
    __SHIM_OP_ENV=()
    parent_is_op_run || return 0

    local name count=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        case "$name" in
            PATH|HOME|HOSTNAME|PWD|OLDPWD|SHLVL|_|TERM|TMPDIR|TMP|TEMP|USER|LOGNAME|SHELL|USERNAME)
                continue ;;
            SSH_*|DOCKER_*|NODE_SHIMS_*|NVM_*|BASH_*|ZSH_*|XPC_*|__*)
                continue ;;
            COMMAND_MODE|SECURITYSESSIONID|LaunchInstanceID|HOMEBREW_*|INFOPATH|MANPATH)
                continue ;;
        esac
        __SHIM_OP_ENV+=(-e "$name")
        count=$((count + 1))
    done < <(compgen -e)

    if is_truthy "${NODE_SHIMS_DEBUG:-}"; then
        echo "node-shims: parent is op run; forwarding $count host env var(s)" >&2
    fi
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

# ---------------------------------------------------------------------------
# Wrangler (Cloudflare Workers CLI) support
#
# Wrangler needs four things the generic container does not give it:
#   1. a persistent config dir, or `wrangler login` is lost with --rm
#   2. CLOUDFLARE_* / WRANGLER_* env vars (API token auth, no login needed)
#   3. listeners bound to 0.0.0.0, or Docker port publishing cannot reach them
#   4. a glibc image, because workerd (used by `wrangler dev`) has no musl build
# All of it is scoped to wrangler projects/commands so other projects never
# see the Cloudflare credentials.
# ---------------------------------------------------------------------------

# True if an argv token is the wrangler executable (npx wrangler, wrangler@4,
# node_modules/.bin/wrangler, ...).
is_wrangler_token() {
    case "$1" in
        wrangler|wrangler@*|*/wrangler|*/wrangler.js) return 0 ;;
    esac
    return 1
}

argv_invokes_wrangler() {
    local arg
    for arg in "$@"; do
        is_wrangler_token "$arg" && return 0
    done
    return 1
}

# True if the current directory is a wrangler project. Covers `npm run deploy`
# style invocations where "wrangler" never appears in argv.
project_uses_wrangler() {
    local f
    for f in wrangler.toml wrangler.json wrangler.jsonc; do
        if [[ -f "$f" ]]; then
            return 0
        fi
    done
    [[ -f package.json ]] && grep -q '"wrangler"[[:space:]]*:' package.json
}

# NODE_SHIMS_WRANGLER: auto (default) | 1 to force on | 0 to force off
use_wrangler_support() {
    local mode="${NODE_SHIMS_WRANGLER:-auto}"
    if [[ "$mode" != "auto" ]]; then
        is_truthy "$mode"
        return
    fi
    argv_invokes_wrangler "$@" || project_uses_wrangler
}

# Print the non-flag words of an argv, e.g. "pages dev" or "login".
nonflag_words() {
    local arg out=""
    for arg in "$@"; do
        case "$arg" in
            -*) continue ;;
        esac
        out="${out:+$out }$arg"
    done
    printf '%s' "$out"
}

# Package-manager flags whose next argv token is a value, not a command.
is_value_flag() {
    case "$1" in
        --filter|-F|--dir|-C|--workspace|--package|-p|--prefix|--cwd) return 0 ;;
    esac
    return 1
}

# Strict check: wrangler is the program this call runs, not just a word in
# argv. `npx wrangler`, `pnpm exec wrangler`, `yarn dlx wrangler@4` and
# `node node_modules/.bin/wrangler` match; `npm i -D wrangler` does not.
# Sets __SHIM_WRANGLER_WORDS to the argv after the wrangler token.
wrangler_words_from_argv() {
    local -a a=("$@")
    local n=${#a[@]} i=0 pass
    for pass in command executor; do
        while (( i < n )); do
            if is_value_flag "${a[i]}"; then
                i=$((i + 2))
                continue
            fi
            case "${a[i]}" in
                -*) i=$((i + 1)); continue ;;
            esac
            break
        done
        (( i < n )) || return 1
        if [[ "$pass" == command ]]; then
            case "${a[i]}" in
                exec|x|dlx) i=$((i + 1)); continue ;;
            esac
        fi
        break
    done
    is_wrangler_token "${a[i]}" || return 1
    __SHIM_WRANGLER_WORDS=(${a[@]+"${a[@]:i+1}"})
    __SHIM_WRANGLER_FROM_ARGV=1
}

# Print the body of package.json script $1. Best effort with sed: a
# minified package.json or a body with `}` before the script prints nothing,
# and the caller then treats the call as not running wrangler.
package_script_body() {
    local name_re
    name_re="$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
    sed -n '/"scripts"[[:space:]]*:/,/}/p' package.json 2>/dev/null \
        | grep -E "^[[:space:]]*\"${name_re}\"[[:space:]]*:" \
        | head -1 \
        | sed -E 's/^[^:]*:[[:space:]]*"(.*)"[[:space:]]*,?[[:space:]]*$/\1/'
}

# `npm run deploy` / `pnpm dev` / `yarn deploy`: wrangler is not in argv,
# so read the script body instead. Sets __SHIM_WRANGLER_WORDS like the argv
# check and __SHIM_WRANGLER_MULTI=1 if the script runs wrangler more than once.
# Scripts in a workspace package (`pnpm --filter x run deploy`) are not
# visible from here; NODE_SHIMS_WRANGLER_AUTH=1 covers those.
wrangler_words_from_script() {
    local tool="$1"
    shift
    case "$tool" in
        npm|pnpm|yarn) ;;
        *) return 1 ;;
    esac
    [[ -f package.json ]] || return 1

    local -a a=("$@")
    local n=${#a[@]} i=0 name=""
    while (( i < n )); do
        # --filter/--dir/--workspace run another package's script; its
        # package.json is not the one in $PWD, so do not guess.
        if is_value_flag "${a[i]}"; then
            return 1
        fi
        case "${a[i]}" in
            --filter=*|--dir=*|--workspace=*|--prefix=*|--cwd=*|-r|--recursive) return 1 ;;
            -*) i=$((i + 1)); continue ;;
        esac
        break
    done
    (( i < n )) || return 1
    case "${a[i]}" in
        run|run-script)
            i=$((i + 1))
            while (( i < n )) && [[ "${a[i]}" == -* ]]; do i=$((i + 1)); done
            (( i < n )) || return 1
            name="${a[i]}"
            ;;
        start|test|stop|restart) name="${a[i]}" ;;
        *)
            # pnpm and yarn run a script given by bare name; npm does not.
            [[ "$tool" == npm ]] && return 1
            name="${a[i]}"
            ;;
    esac

    local body
    body="$(package_script_body "$name")"
    [[ -n "$body" ]] || return 1

    local -a words
    read -ra words <<< "$body"
    local j found=-1 count=0
    for (( j = 0; j < ${#words[@]}; j++ )); do
        if is_wrangler_token "${words[j]}"; then
            (( found < 0 )) && found=$j
            count=$((count + 1))
        fi
    done
    (( found >= 0 )) || return 1
    __SHIM_WRANGLER_WORDS=(${words[@]+"${words[@]:found+1}"})
    (( count > 1 )) && __SHIM_WRANGLER_MULTI=1
    return 0
}

# True if the wrangler config may need the Cloudflare API even in local
# `wrangler dev`: remote bindings, or binding types that always proxy to
# Cloudflare (Workers AI, Vectorize, Browser Rendering, ...). Over-matching
# is fine: it only means dev gets credentials.
wrangler_config_needs_remote() {
    local keys='remote|ai|vectorize|browser|mtls_certificates|dispatch_namespaces|images|media|vpc_services'
    local f
    for f in wrangler.toml wrangler.json wrangler.jsonc; do
        [[ -f "$f" ]] || continue
        grep -Eq "(^|[^A-Za-z0-9_])\"?(${keys})\"?[[:space:]]*[=:]" "$f" && return 0
        grep -Eq "^[[:space:]]*\[\[?([A-Za-z0-9_.-]+\.)?(${keys})\]" "$f" && return 0
    done
    return 1
}

# Wrangler commands that run without touching the Cloudflare API, so they
# get no credentials. Kept short on purpose: only commands verified to work
# while logged out. Anything not listed gets credentials, so a missing entry
# costs exposure, never a broken command. Args: argv after the wrangler token.
wrangler_is_local_only() {
    if has_flag --help "$@" || has_flag -h "$@" || has_flag --version "$@" || has_flag -v "$@"; then
        return 0
    fi
    local sub
    sub="$(nonflag_words "$@")"
    case "$sub" in
        "") return 0 ;;  # bare `wrangler` prints help
        types|types\ *|build|build\ *|pages\ functions\ build|pages\ functions\ build\ *)
            return 0 ;;
        deploy|deploy\ *|versions\ upload|versions\ upload\ *)
            has_flag --dry-run "$@" && return 0 ;;
        dev|dev\ *|pages\ dev|pages\ dev\ *)
            if has_flag --remote "$@" || has_flag -r "$@" \
                || has_flag --config "$@" || has_flag -c "$@" \
                || wrangler_config_needs_remote; then
                return 1
            fi
            return 0 ;;
    esac
    return 1
}

# NODE_SHIMS_WRANGLER_AUTH: auto (default) | 1 always | 0 never
wrangler_wants_credentials() {
    local mode="${NODE_SHIMS_WRANGLER_AUTH:-auto}"
    if [[ "$mode" != "auto" ]]; then
        is_truthy "$mode"
        return
    fi
    (( __SHIM_WRANGLER_RUNS )) || return 1
    (( __SHIM_WRANGLER_MULTI )) && return 0
    ! wrangler_is_local_only ${__SHIM_WRANGLER_WORDS[@]+"${__SHIM_WRANGLER_WORDS[@]}"}
}

# True if the flag (e.g. --ip) is present as `--ip`, `--ip=x`, or `--no-ip`.
has_flag() {
    local flag="$1" arg
    shift
    for arg in "$@"; do
        case "$arg" in
            "$flag"|"$flag"=*|"--no-${flag#--}") return 0 ;;
        esac
    done
    return 1
}

# Print the value of --profile / --profile=<name> in the wrangler words.
wrangler_profile_flag() {
    local prev="" w
    for w in "$@"; do
        if [[ "$prev" == "--profile" ]]; then
            printf '%s\n' "$w"
            return 0
        fi
        case "$w" in
            --profile=*) printf '%s\n' "${w#--profile=}"; return 0 ;;
        esac
        prev="$w"
    done
    return 1
}

# Print the profile bound to a directory (or its nearest bound parent) in
# wrangler's profiles/directory-bindings.json, the same rule wrangler uses.
wrangler_profile_for_dir() {
    local bindings="$1" dir="$2"
    [[ -f "$bindings" ]] || return 1
    awk -v dir="$dir" '
        match($0, /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*"[^"]+"/) {
            line = substr($0, RSTART, RLENGTH)
            sub(/^[[:space:]]*"/, "", line)
            sub(/"$/, "", line)
            n = split(line, parts, /"[[:space:]]*:[[:space:]]*"/)
            if (n != 2) next
            if ((dir == parts[1] || index(dir, parts[1] "/") == 1) && length(parts[1]) > best) {
                best = length(parts[1]); found = parts[2]
            }
        }
        END { if (found == "") exit 1; print found }' "$bindings"
}

# Ask before Cloudflare credentials go into the container. Reads /dev/tty so
# it works under `npm run`; without a terminal it refuses unless
# NODE_SHIMS_WRANGLER_YES=1.
wrangler_confirm_mount() {
    local what="$1" reply=""
    is_truthy "${NODE_SHIMS_WRANGLER_YES:-}" && return 0
    if ! { : </dev/tty; } 2>/dev/null; then
        echo "node-shims: refusing to mount $what into the container without confirmation (no terminal)." >&2
        echo "node-shims: set NODE_SHIMS_WRANGLER_YES=1 to allow it." >&2
        exit 1
    fi
    printf 'node-shims: mount %s into the container? [y/N] ' "$what" >/dev/tty
    read -r reply </dev/tty || true
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
    esac
    echo "node-shims: aborted, no credentials mounted." >&2
    exit 1
}

# Mount wrangler's config dir with only the credentials this call needs.
# The store keeps wrangler's own layout ($dir/config/<profile>.toml); the
# container sees $dir with config/ replaced by an empty tmpfs plus the one
# profile file that applies. Other profiles (e.g. prod) never enter it.
#   profile: --profile, else the directory binding, else `default`
#   wrangler login            -> default profile (created if missing)
#   wrangler auth create <p>  -> <p> (created if missing)
#   wrangler auth activate/list -> empty stand-in files, no tokens
#   wrangler logout / auth delete -> the whole store (they delete files)
prepare_wrangler_config_mount() {
    local config_dir="$1" debug="$2"
    local dest=/root/.config/.wrangler
    local name_re='^[A-Za-z0-9_-]+$'

    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir"
        chmod 700 "$config_dir" 2>/dev/null || true
    fi
    mkdir -p "$config_dir/config"
    chmod 700 "$config_dir/config" 2>/dev/null || true
    __SHIM_WRANGLER_DOCKER_ARGS+=(-v "$config_dir":"$dest")
    (( debug )) && echo "node-shims: wrangler config dir: $config_dir" >&2

    local -a words=(${__SHIM_WRANGLER_WORDS[@]+"${__SHIM_WRANGLER_WORDS[@]}"})
    local sub
    sub="$(nonflag_words ${words[@]+"${words[@]}"})"

    case "$sub" in
        logout|logout\ *|auth\ delete|auth\ delete\ *)
            wrangler_confirm_mount "ALL wrangler profiles in $config_dir/config (\`wrangler ${sub}\` deletes credential files)"
            (( debug )) && echo "node-shims: wrangler profiles: all" >&2
            return 0 ;;
    esac

    # From here on, config/ in the container starts empty.
    __SHIM_WRANGLER_DOCKER_ARGS+=(--mount "type=tmpfs,destination=$dest/config")

    local profile="" create=0 stand_in=0 f
    case "$sub" in
        auth\ list|auth\ list\ *)
            for f in "$config_dir"/config/*.toml; do
                [[ -f "$f" ]] || continue
                f="$(basename "$f")"
                __SHIM_WRANGLER_DOCKER_ARGS+=(-v "$config_dir/.empty":"$dest/config/$f:ro")
            done
            : > "$config_dir/.empty"
            (( debug )) && echo "node-shims: wrangler profiles: names only" >&2
            return 0 ;;
        auth\ activate\ *)
            profile="${sub#auth activate }"; profile="${profile%% *}"; stand_in=1 ;;
        auth\ create\ *)
            profile="${sub#auth create }"; profile="${profile%% *}"; create=1 ;;
        login|login\ *)
            profile=default; create=1
            echo "node-shims: note: \`wrangler login\` writes the default profile, which applies in every directory without a binding. Use \`wrangler auth create <name>\` for a named profile." >&2 ;;
        auth|auth\ deactivate|auth\ deactivate\ *|auth\ keyring|auth\ keyring\ *)
            (( debug )) && echo "node-shims: wrangler profiles: none needed" >&2
            return 0 ;;
    esac

    if [[ -z "$profile" ]]; then
        # An API token in the environment wins over any profile.
        if [[ -n "${CLOUDFLARE_API_TOKEN:-}" || -n "${CLOUDFLARE_API_KEY:-}" ]]; then
            (( debug )) && echo "node-shims: wrangler profiles: none (API token in environment)" >&2
            return 0
        fi
        profile="$(wrangler_profile_flag ${words[@]+"${words[@]}"} || true)"
        if [[ -z "$profile" ]]; then
            local bindings="$config_dir/profiles/directory-bindings.json"
            profile="$(wrangler_profile_for_dir "$bindings" "$(pwd)" \
                || wrangler_profile_for_dir "$bindings" "$(pwd -P)" || true)"
        fi
        [[ -n "$profile" ]] || profile=default
    fi

    if [[ ! "$profile" =~ $name_re ]]; then
        echo "node-shims: invalid wrangler profile name: $profile" >&2
        exit 1
    fi

    local file="$config_dir/config/$profile.toml"
    if (( stand_in )); then
        if [[ -f "$file" ]]; then
            : > "$config_dir/.empty"
            __SHIM_WRANGLER_DOCKER_ARGS+=(-v "$config_dir/.empty":"$dest/config/$profile.toml:ro")
        fi
        (( debug )) && echo "node-shims: wrangler profile: $profile (name only)" >&2
        return 0
    fi

    if [[ ! -f "$file" ]] && (( ! create )); then
        (( debug )) && echo "node-shims: wrangler profile: $profile (not found, nothing mounted)" >&2
        return 0
    fi
    wrangler_confirm_mount "wrangler profile \"$profile\" credentials"
    # Docker turns a missing bind source into a directory; create the file.
    [[ -f "$file" ]] || ( umask 077; : > "$file" )
    chmod 600 "$file" 2>/dev/null || true
    __SHIM_WRANGLER_DOCKER_ARGS+=(-v "$file":"$dest/config/$profile.toml")
    (( debug )) && echo "node-shims: wrangler profile: $profile" >&2
    return 0
}

# Populates:
#   __SHIM_WRANGLER_DOCKER_ARGS  extra `docker run` args (mounts, env, ports)
#   __SHIM_TOOL_ARGS             argv for the tool, with container flags added
prepare_wrangler() {
    local tool="$1"
    shift
    __SHIM_WRANGLER_DOCKER_ARGS=()
    __SHIM_TOOL_ARGS=("$@")
    __SHIM_WRANGLER_WORDS=()
    __SHIM_WRANGLER_RUNS=0
    __SHIM_WRANGLER_FROM_ARGV=0
    __SHIM_WRANGLER_MULTI=0
    use_wrangler_support "$@" || return 0

    local debug=0
    is_truthy "${NODE_SHIMS_DEBUG:-}" && debug=1

    if wrangler_words_from_argv "$@" || wrangler_words_from_script "$tool" "$@"; then
        __SHIM_WRANGLER_RUNS=1
    fi

    # 1+2. Credentials go only to calls that run wrangler for something that
    #      needs the Cloudflare API, never to `npm install` and the dependency
    #      scripts it runs.
    if wrangler_wants_credentials; then
        (( debug )) && echo "node-shims: wrangler credentials: passed" >&2

        # Persistent config dir (OAuth tokens from `wrangler login` and
        # `wrangler auth create`), mounted with only the profile that applies.
        # Wrangler resolves it to $XDG_CONFIG_HOME/.wrangler = /root/.config/.wrangler
        local config_dir="${NODE_SHIMS_WRANGLER_CONFIG_DIR:-$HOME/.config/node-shims/wrangler}"
        if [[ "$config_dir" != "none" ]]; then
            prepare_wrangler_config_mount "$config_dir" "$debug"
        fi

        # Forward Cloudflare/wrangler env vars by name (values stay off argv).
        local name
        while IFS= read -r name; do
            case "$name" in
                WRANGLER_LOGIN_PORT) continue ;;
                CLOUDFLARE_*|WRANGLER_*)
                    __SHIM_WRANGLER_DOCKER_ARGS+=(-e "$name")
                    (( debug )) && echo "node-shims: forwarding $name" >&2
                    ;;
            esac
        done < <(compgen -e)
    elif (( debug )); then
        echo "node-shims: wrangler credentials: withheld (not a wrangler call that needs the Cloudflare API)" >&2
    fi

    # 3. Make wrangler's listeners reachable through Docker port publishing.
    #    Only possible when wrangler is in argv; `npm run dev` needs
    #    `[dev] ip = "0.0.0.0"` in wrangler.toml instead (see README).
    (( __SHIM_WRANGLER_FROM_ARGV )) || return 0
    local inject=1
    if [[ -n "${NODE_SHIMS_WRANGLER_FLAGS:-}" ]] && ! is_truthy "$NODE_SHIMS_WRANGLER_FLAGS"; then
        inject=0
    fi

    local sub
    sub="$(nonflag_words ${__SHIM_WRANGLER_WORDS[@]+"${__SHIM_WRANGLER_WORDS[@]}"})"
    case "$sub" in
        login|login\ *|auth|auth\ *)
            # --device needs no callback server at all.
            has_flag --device "$@" && return 0
            # The OAuth page always redirects to http://localhost:8976 on the
            # host browser; publish it on loopback only. Every `auth`
            # subcommand gets the port in case it starts an OAuth flow, but
            # only login and `auth create` accept the callback flags.
            local login_port="${WRANGLER_LOGIN_PORT:-8976}"
            # Both loopbacks: Firefox (and others) resolve localhost to ::1 first.
            __SHIM_WRANGLER_DOCKER_ARGS+=(-p "127.0.0.1:${login_port}:${login_port}" -p "[::1]:${login_port}:${login_port}")
            case "$sub" in
                login|login\ *|auth\ create|auth\ create\ *) ;;
                *) return 0 ;;
            esac
            if (( inject )); then
                has_flag --callback-host "$@" || __SHIM_TOOL_ARGS+=(--callback-host=0.0.0.0)
                has_flag --callback-port "$@" || __SHIM_TOOL_ARGS+=("--callback-port=${login_port}")
                # No browser in the container: print the URL instead of failing to open it.
                has_flag --browser "$@" || __SHIM_TOOL_ARGS+=(--browser=false)
            fi
            ;;
        dev|dev\ *|pages\ dev|pages\ dev\ *)
            if (( inject )) && ! has_flag --ip "$@"; then
                __SHIM_TOOL_ARGS+=(--ip=0.0.0.0)
            fi
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# node_modules platform marker
#
# Native packages (esbuild, rollup, workerd, swc, ...) only load on the
# platform that installed them: macOS vs Linux, and musl (alpine) vs glibc
# (debian). Install commands record that platform in
# node_modules/.node-shims-platform, and later runs warn when it differs from
# the platform about to execute, instead of failing with an obscure
# native-binary error.
# ---------------------------------------------------------------------------
NODE_SHIMS_PLATFORM_MARKER="node_modules/.node-shims-platform"

normalized_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo arm64 ;;
        x86_64|amd64) echo x64 ;;
        *) uname -m ;;
    esac
}

# Platform a container from this image runs, e.g. linux-arm64-musl
container_platform() {
    local libc=glibc
    [[ "$1" == *alpine* ]] && libc=musl
    echo "linux-$(normalized_arch)-${libc}"
}

# Platform of a host (local mode) run, e.g. darwin-arm64
host_platform() {
    echo "$(uname -s | tr '[:upper:]' '[:lower:]')-$(normalized_arch)"
}

# True if the command installs or changes node_modules.
is_install_command() {
    local tool="$1" sub="" arg
    shift
    for arg in "$@"; do
        case "$arg" in
            -*) continue ;;
        esac
        sub="$arg"
        break
    done
    case "$tool" in
        npm)
            case "$sub" in
                install|i|in|add|ci|clean-install|ic|install-clean|update|up|upgrade|uninstall|un|remove|rm|r|dedupe|ddp|rebuild|rb) return 0 ;;
            esac ;;
        pnpm)
            case "$sub" in
                install|i|add|update|up|upgrade|remove|rm|uninstall|un|rebuild|rb|import) return 0 ;;
            esac ;;
        yarn)
            case "$sub" in
                ""|install|add|upgrade|up|remove) return 0 ;;
            esac ;;
    esac
    return 1
}

warn_platform_mismatch() {
    local target="$1" recorded
    is_truthy "${NODE_SHIMS_NO_PLATFORM_WARNING:-}" && return 0
    [[ -f "$NODE_SHIMS_PLATFORM_MARKER" ]] || return 0
    recorded="$(head -n 1 "$NODE_SHIMS_PLATFORM_MARKER" 2>/dev/null || true)"
    [[ -n "$recorded" && "$recorded" != "$target" ]] || return 0
    echo "⚠️  node-shims: node_modules was installed for $recorded, but this run is $target." >&2
    echo "   Native packages (esbuild, rollup, workerd, swc, ...) may fail to load." >&2
    echo "   Fix: rm -rf node_modules, then reinstall the same way you run the project." >&2
}

record_platform() {
    [[ -d node_modules ]] || return 0
    printf '%s\n' "$1" > "$NODE_SHIMS_PLATFORM_MARKER" 2>/dev/null || true
}

# Run "$@" (the full command). Install commands run as a child so the marker
# can be written afterwards; everything else is exec'd so signals reach the
# process directly, as before.
run_with_platform_marker() {
    local tool="$1" platform="$2"
    shift 2
    warn_platform_mismatch "$platform"
    if is_install_command "$tool" "${__SHIM_TOOL_ARGV[@]+"${__SHIM_TOOL_ARGV[@]}"}"; then
        local rc=0
        "$@" || rc=$?
        record_platform "$platform"
        exit "$rc"
    fi
    exec "$@"
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
        __SHIM_PLATFORM_GUARD=1
        exec_local "$tool" "$@"
    fi

    if needs_host_node "$tool" "$@"; then
        exec_local "$tool" "$@"
    fi

    ensure_docker
    local img; img="$(resolve_image)"
    prepare_project_mounts
    append_extra_host_mounts "$__SHIM_MOUNT_ROOT_PHYSICAL" "$@"
    append_op_run_env
    prepare_wrangler "$tool" "$@"
    # workerd (wrangler dev) is glibc-only; use the Debian variant of the same
    # Node version for wrangler projects unless the user pinned NODE_IMAGE.
    if use_wrangler_support "$@" && [[ -z "${NODE_IMAGE:-}" && "$img" == *-alpine ]]; then
        img="${img%-alpine}-bookworm"
    fi
    # Node 25+ images no longer bundle corepack. A pinned copy is installed
    # once into this host dir and reused (it is plain JS, any Node works).
    local corepack_dir="$HOME/.cache/node-shims/corepack"
    mkdir -p "$corepack_dir"
    # ${arr[@]+...} keeps empty arrays safe under `set -u` on macOS bash 3.2.
    local -a args=(run --rm
        "${__SHIM_PROJECT_MOUNTS[@]}"
        ${__SHIM_OP_ENV[@]+"${__SHIM_OP_ENV[@]}"}
        ${__SHIM_WRANGLER_DOCKER_ARGS[@]+"${__SHIM_WRANGLER_DOCKER_ARGS[@]}"}
        -v "$HOME/.npm":/root/.npm
        -v "$HOME/.npmrc":/root/.npmrc
        -v "$HOME/.cache/pnpm":/root/.cache/pnpm
        -v "$HOME/.cache/yarn":/root/.cache/yarn
        -v "$HOME/.config/pnpm":/root/.config/pnpm
        -v "$corepack_dir":/opt/node-shims-corepack
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

    # Enable corepack (installing the pinned copy first on images without it);
    # if Docker socket is mounted, install docker-cli so npm scripts can run docker
    local corepack_version="${NODE_SHIMS_COREPACK_VERSION:-0.36.0}"
    [[ "$corepack_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || corepack_version=0.36.0
    local setup="if ! command -v corepack >/dev/null 2>&1; then export PATH=/opt/node-shims-corepack/bin:\$PATH; [ \"\$(cat /opt/node-shims-corepack/.version 2>/dev/null)\" = '$corepack_version' ] || { npm install -g --prefix /opt/node-shims-corepack --no-audit --no-fund 'corepack@$corepack_version' >/dev/null 2>&1 && echo '$corepack_version' > /opt/node-shims-corepack/.version; } || true; fi"
    setup="$setup; corepack enable >/dev/null 2>&1 || true; corepack install >/dev/null 2>&1 || true"
    if use_docker_socket; then
        setup="$setup; if command -v apk >/dev/null 2>&1; then apk add --no-cache docker-cli >/dev/null 2>&1 || true; elif command -v apt-get >/dev/null 2>&1; then (apt-get update -qq && apt-get install -y -qq --no-install-recommends docker.io) >/dev/null 2>&1 || true; fi"
    fi
    __SHIM_TOOL_ARGV=("$@")
    run_with_platform_marker "$tool" "$(container_platform "$img")" \
        docker "${args[@]}" "$img" sh -c "$setup; exec \"\$@\"" -- "$tool" ${__SHIM_TOOL_ARGS[@]+"${__SHIM_TOOL_ARGS[@]}"}
}
