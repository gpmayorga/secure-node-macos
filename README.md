# Node in Docker (macOS Hardening)

This project removes host Node/npm from macOS and replaces `node`, `npm`, `npx`, `yarn`, and `pnpm`
with Docker-backed shims. The goal is to reduce the risk of supply-chain attacks impacting your host,
especially for web3 work.

## Why This Matters

**Recent Supply Chain Attack (September 2025)**: [18 popular npm packages were compromised](https://www.aikido.dev/blog/npm-debug-and-chalk-packages-compromised), including `debug`, `chalk`, and `ansi-styles` with over 2 billion weekly downloads.

**Your Protection**: By running Node.js tools in isolated Docker containers, even if malicious packages are installed, they cannot:
- Access your host system files
- Modify your macOS environment
- Persist malicious code outside the container
- Access sensitive data on your machine

This approach provides **defense in depth** against supply chain attacks that traditional npm installations cannot offer.

⚠️ **Destructive**: `scripts/nuke-node-macos.sh` removes NVM/Homebrew Node installs and caches.
Use at your own risk.

## Features

### 🔒 **Security Hardening**
- **Isolated execution** - All Node.js tools run in Docker containers
- **Safe defaults** - `.npmrc` configured with `ignore-scripts=true` and other defaults
- **No host contamination** - Zero Node.js installation on your macOS system
- **Supply chain protection** - Malicious packages cannot access your host system

### 🚀 **Automatic Package Manager Installation**
- **yarn & pnpm via corepack** - Automatically uses the correct version via corepack (on Node 25+ images, which no longer bundle corepack, a pinned copy is installed once into `~/.cache/node-shims/corepack`)
- **Version-aware** - Respects `packageManager` field in package.json
- **No manual setup** - Just run `yarn` or `pnpm` and they'll be ready
- **Persistent caches** - Package manager caches are mounted and persist between runs

### 📦 **Smart Version Detection**
- **`.nvmrc` support** - Automatically uses Node.js version specified in `.nvmrc`
- **`.node-version` support** - Also supports `.node-version` files
- **`package.json` engines** - Falls back to `engines.node` field if present
- **Latest LTS default** - Uses the latest LTS version (currently Node 26) when no version is specified
- **Auto-updating** - GitHub Action updates default version every 3 months

### 🛠 **Development-Friendly**
- **Port mapping** - Automatically maps common dev server ports (3000, 5173, 8080, etc.)
- **Git integration** - Mounts your `.gitconfig` for seamless git operations
- **Interactive mode** - Full TTY support for interactive commands
- **Cache persistence** - npm/yarn/pnpm caches persist between container runs

## Quick Start

### 1) Remove host Node/npm (optional but recommended)
```bash
./scripts/nuke-node-macos.sh
```
This script will:
- Remove all existing Node.js installations (Homebrew, nvm, etc.)
- Clean up caches and configuration files
- Show exactly what it's doing with verbose output

### 2) Install Docker-backed shims
```bash
./scripts/install-shims.sh
```
This script will:
- Add the `bin/` directory to your PATH
- Create necessary cache directories
- Test Docker connectivity
- Provide clear setup instructions

### 3) Restart your shell
```bash
source ~/.zshrc  # or ~/.bashrc
```

## Usage

### Basic Commands
```bash
node --version    # Uses latest LTS by default
npm install       # Works exactly like before
yarn add lodash   # Auto-installs yarn on first use
pnpm add express  # Auto-installs pnpm on first use
npx create-react-app my-app  # No global install needed
```

### Global Package Management
```bash
# Recommended: Use npx (no global installs needed)
npx wrangler --version
npx typescript --version
npx eslint --init
npx create-react-app my-app
```

### Version Management
Create a `.nvmrc` file in your project root:
```bash
echo "18" > .nvmrc
node --version  # Now uses Node.js 18
```

Or use `.node-version`:
```bash
echo "20" > .node-version
node --version  # Now uses Node.js 20
```

Or specify in `package.json`:
```json
{
  "engines": {
    "node": ">=18.0.0"
  }
}
```

### Development Servers
Ports are automatically mapped for common development servers:
```bash
npm run dev      # Port 3000, 5173, 8080, 4200, etc. automatically mapped
yarn start       # Your dev server will be accessible on localhost
```

## Configuration

### Custom Ports
Set the `DOCKER_NODE_PORTS` environment variable to customize port mapping:
```bash
export DOCKER_NODE_PORTS="3000,4000,5000,8000"
```

### Wrangler (Cloudflare Workers)
Wrangler works inside the container. The shims turn on extra wrangler handling when the command invokes `wrangler` (`npx wrangler deploy`, `pnpm wrangler dev`) or the current directory is a wrangler project (has `wrangler.toml` / `wrangler.json(c)`, or `wrangler` in `package.json`).

What the shims do for wrangler:

| Issue | What the shim does |
|---|---|
| `wrangler login` token lost after each run (`--rm`) | Mounts `~/.config/node-shims/wrangler` as wrangler's config dir, so logins persist, with only the auth profile the call uses (credentialed calls only, see below) |
| API token auth | Forwards any `CLOUDFLARE_*` and `WRANGLER_*` env vars that are set (by name, values never on argv; credentialed calls only) |
| OAuth callback unreachable from the browser | Publishes `127.0.0.1:8976` and `[::1]:8976` for `wrangler login` and every `wrangler auth` command, and adds `--callback-host=0.0.0.0 --callback-port=8976 --browser=false` to `wrangler login` and `wrangler auth create` |
| `wrangler dev` unreachable on `localhost:8787` | Adds `--ip=0.0.0.0` to `wrangler dev` / `wrangler pages dev` |
| `workerd` (used by `wrangler dev`) has no Alpine/musl build | Uses `node:<version>-bookworm` instead of `-alpine` for wrangler projects |

Current wrangler 4 needs Node 22 or newer. The default image (Node 26) is fine; only projects that pin an older version in `.nvmrc`, `.node-version` or `engines` need to raise it.

**Which calls get Cloudflare credentials.** The config mount and the `CLOUDFLARE_*` / `WRANGLER_*` env vars go only to calls that run wrangler. `npm install`, `npm ls`, `node script.js` and other calls in a wrangler project get neither, so dependency install scripts cannot read your token.

| Call | Credentials |
|---|---|
| `npx wrangler deploy`, `pnpm exec wrangler secret list`, `npx wrangler login`, `wrangler whoami`, `wrangler dev --remote` | yes |
| `npm run deploy` / `pnpm deploy-prod` where the root `package.json` script calls wrangler | yes |
| `wrangler dev` / `wrangler pages dev` (local), `wrangler types`, `wrangler build`, `wrangler deploy --dry-run`, `wrangler versions upload --dry-run`, `wrangler pages functions build`, `--help`, `--version` | no |
| `npm install`, `npm i -D wrangler`, `pnpm add wrangler`, any call that does not run wrangler | no |

The list of commands that get no credentials is short on purpose: it holds only commands that work while logged out. Every other wrangler command gets credentials, so a command missing from the list still works.

`wrangler dev` gets credentials anyway when the wrangler config has remote bindings (`remote = true`) or bindings that always call Cloudflare (Workers AI, Vectorize, Browser Rendering, mTLS, dispatch namespaces, Images, Media, VPC services), when `--remote` is set, or when `--config` points somewhere else.

The shim cannot see the script for `pnpm --filter <pkg> run deploy` (or `--dir`, `--workspace`, `-r`), since it lives in another package's `package.json`, so those calls get no credentials. Set `NODE_SHIMS_WRANGLER_AUTH=1` for them. `op run --env-file=.env -- <cmd>` still forwards every variable from the env file, whatever the command, because you asked for it explicitly.

**Recommended: scoped API token instead of `wrangler login`.** `wrangler login` stores a broad OAuth refresh token on disk. A scoped [API token](https://dash.cloudflare.com/profile/api-tokens) kept in 1Password gives any compromised dependency less to steal:
```bash
# .env (1Password references, safe to commit)
CLOUDFLARE_API_TOKEN=op://Dev/cloudflare-workers/token
CLOUDFLARE_ACCOUNT_ID=op://Dev/cloudflare-workers/account-id
```
```bash
op run --env-file=.env -- npx wrangler deploy
```
To skip the config mount entirely when you only use tokens:
```bash
export NODE_SHIMS_WRANGLER_CONFIG_DIR=none
```

**Using `wrangler login`:** run `npx wrangler login` and open the printed URL in your browser. Wrangler's OAuth page always redirects to `http://localhost:8976`, so that host port must be free. Alternatively, `npx wrangler login --device` uses the device code flow and needs no callback port (recent wrangler 4 versions).

**Auth profiles.** Wrangler keeps one credentials file per profile in `config/<name>.toml` and folder bindings in `profiles/directory-bindings.json`. The shim mounts only the profile a call uses, so a dev command never sees the prod token. It picks the profile the same way wrangler does: `--profile <name>`, else the profile bound to the folder or its nearest parent, else `default`. Before mounting a profile it asks `mount wrangler profile "<name>" credentials into the container? [y/N]`. Without a terminal it refuses unless `NODE_SHIMS_WRANGLER_YES=1` is set.

| Command | What the container gets |
|---|---|
| `wrangler deploy`, `whoami`, `secret put`, ... | The resolved profile file only (nothing if it does not exist; nothing if `CLOUDFLARE_API_TOKEN` is set) |
| `wrangler auth create <name>` | `<name>.toml` only (created empty first) |
| `wrangler login` | `default.toml` only; the shim warns that this is the global fallback profile |
| `wrangler auth list`, `wrangler auth activate <name>` | Empty stand-in files, so profile names exist but no tokens |
| `wrangler auth deactivate` | No profile |
| `wrangler logout`, `wrangler auth delete <name>` | All profiles (they delete files), after the prompt |

To avoid deploying with the wrong account by accident, keep no `default` profile: create named profiles, bind dev folders, and pass prod explicitly.

```bash
npx wrangler auth create centlabs-dev
npx wrangler auth create centrifuge-prod
cd ~/code/my-dev-worker && npx wrangler auth activate centlabs-dev
npx wrangler deploy --profile centrifuge-prod   # prod only when asked for
```

**`npm run dev` scripts:** the shim can only add `--ip` when `wrangler` appears in the command line. If wrangler is started from a package.json script, set the listen address in `wrangler.toml` instead:
```toml
[dev]
ip = "0.0.0.0"
```

Settings:

| Variable | Default | Purpose |
|---|---|---|
| `NODE_SHIMS_WRANGLER` | `auto` | `1` forces wrangler handling on (e.g. monorepo root), `0` turns it off |
| `NODE_SHIMS_WRANGLER_AUTH` | `auto` | `1` always passes credentials (e.g. `pnpm --filter <pkg> run deploy`), `0` never does |
| `NODE_SHIMS_WRANGLER_CONFIG_DIR` | `~/.config/node-shims/wrangler` | Host dir for wrangler's config/OAuth token, or `none` |
| `NODE_SHIMS_WRANGLER_YES` | unset | `1` mounts the profile without asking (needed when there is no terminal) |
| `NODE_SHIMS_WRANGLER_FLAGS` | on | `0` stops the shim from adding `--callback-host`, `--ip` and similar flags (wrangler 3 does not know `--callback-host`) |
| `WRANGLER_LOGIN_PORT` | `8976` | Login callback port |

If you previously ran `npm install` in a wrangler project with the Alpine image, or with Node on macOS, delete `node_modules` and reinstall through the shims. Packages with native builds (`workerd`, Rollup) were installed for Alpine or macOS, and wrangler fails with "You installed workerd on another platform".

### Docker from npm scripts
To allow **npm scripts** (e.g. `npm run build` that runs `docker build`) to use Docker, mount the host Docker socket and enable the Docker CLI inside the Node container:

```bash
export NODE_SHIMS_DOCKER=1
npm run build   # your script can now run docker build, docker run, etc.
```

This mounts `/var/run/docker.sock` into the container and installs the `docker` CLI there, so containers started from npm scripts run on your host Docker daemon. To test:

```bash
./scripts/test-docker-in-npm.sh
```

### Custom Node.js Image
Override the default image with the `NODE_IMAGE` environment variable:
```bash
export NODE_IMAGE="node:24-alpine"
```

### Corepack Version
Node 25 and newer images do not include corepack. For those, the shims install `corepack@0.36.0` once into `~/.cache/node-shims/corepack` and reuse it. To pin a different version:
```bash
export NODE_SHIMS_COREPACK_VERSION=0.36.0
```

### npm Configuration
The included `.npmrc` provides safe defaults:
```
ignore-scripts=true
strict-ssl=true
save-exact=true
```

## AI Coding Agents
AI agents assume a normal host Node install. Without context they may "fix" a failing command by installing Node with Homebrew or nvm, or by switching to `NODE_SHIMS_MODE=local`, which undoes the isolation.

`skills/node-docker-shims/SKILL.md` is a [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills) that explains how the shims work: what the container can see, env vars, ports, native packages, install scripts, wrangler credentials, and which settings an agent must not change without asking. `install-shims.sh` sets it up; to run that step on its own:
```bash
./scripts/install-agent-skill.sh          # asks before editing ~/.claude/CLAUDE.md
./scripts/install-agent-skill.sh --yes    # no prompt
```
It does two things:
- Symlinks the skill into `~/.claude/skills/node-docker-shims`, so `git pull` keeps it current.
- Adds one line to `~/.claude/CLAUDE.md` (loaded in every session) telling agents that Node runs in Docker and to load the skill before running JavaScript tooling. Skills only load when their description matches the task, so this line makes sure agents never start from the wrong assumption.

Other agents (Cursor, Codex, ...) can use the same file: point their rules file (`AGENTS.md`, `.cursor/rules`) at it.

## How It Works

1. **Shims intercept commands** - `node`, `npm`, `yarn`, `pnpm` commands are caught by shims
2. **Docker containers** - Commands run in isolated Docker containers
3. **Volume mounting** - Your project is mounted at its real host path (and as `/work`) so `node /Users/…/script.js` works; caches are mounted separately
   - Inside a workspace package (a parent has `pnpm-workspace.yaml`, or a `package.json` with `"workspaces"`), the workspace root is mounted instead, since pnpm links and npm/yarn hoist dependencies into the root `node_modules`. `$HOME` and `/` are never mounted. `NODE_SHIMS_WORKSPACE=0` mounts only the current directory.
4. **Version detection** - Smart detection of Node.js version from various sources
5. **Automatic setup** - Package managers install automatically when needed

## Maintenance

The project includes automated maintenance:
- **GitHub Action** updates the default Node.js version every 3 months
- **ShellCheck** ensures script quality and safety
- **Automatic testing** verifies new versions work correctly

## Troubleshooting

### Docker not running
```bash
# Start Docker Desktop
open -a Docker
```

### Port conflicts
```bash
# Customize ports if needed
export DOCKER_NODE_PORTS="3001,4001,5001"
```

### Absolute paths 404 inside Docker
The project is bind-mounted at the same path as on the host, so absolute paths *under `$PWD`* resolve. Extra existing file arguments outside `$PWD` are mounted at the same path. Scripts that live outside the project and are macOS-native (e.g. Cursor's bundled `esbuild`) fall back to a host `node`. To force that for a whole session:

```bash
export NODE_SHIMS_MODE=local
```

### "node_modules was installed for ..." warning
Packages with native binaries (esbuild, Rollup, workerd, SWC, ...) only load on the platform that installed them: macOS vs Linux, and Alpine (`musl`) vs Debian (`glibc`) images. Install commands (`npm install`/`ci`/`add`, `pnpm install`/`add`, `yarn`, ...) record the platform in `node_modules/.node-shims-platform`. Later runs compare it with the platform about to execute, in the container or with `NODE_SHIMS_MODE=local`, and print a warning on a mismatch instead of failing later with an obscure native-module error.

Typical causes: switching a project between `NODE_SHIMS_MODE=local` and the container, or between an Alpine and a Debian image (wrangler projects use Debian). The fix is a clean reinstall in the mode you run the project in:
```bash
rm -rf node_modules && npm install
```
To silence the warning:
```bash
export NODE_SHIMS_NO_PLATFORM_WARNING=1
```

### `op run` environment is dropped
`docker run` does not inherit the host environment. When the shim’s **direct parent** is `op run` (1Password CLI), exported host vars are forwarded with `-e NAME` so a FIFO `.env` that `op` already resolved reaches the container. `PATH` / `HOME` / `TMPDIR` and similar are not forwarded (they would break the image).

This does nothing if `op` is not installed, and nothing for `npm` / `node` started from a shell. `op run --env-file=.env -- npm install` *will* forward, because that is what wrapping the command in `op run` means. Host tools the image lacks (`gcloud`) still need `NODE_SHIMS_MODE=local`. `NODE_SHIMS_DEBUG=1` logs how many vars were forwarded.
