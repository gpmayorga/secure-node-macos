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
Wrangler works inside the container. The shims turn on extra wrangler handling when the command invokes `wrangler` (`npx wrangler deploy`, `pnpm wrangler dev`) or the current directory is a wrangler project (has `wrangler.toml` / `wrangler.json(c)`, or `wrangler` in `package.json`). Other projects never get the Cloudflare credentials.

What the shims do for wrangler:

| Issue | What the shim does |
|---|---|
| `wrangler login` token lost after each run (`--rm`) | Mounts `~/.config/node-shims/wrangler` as wrangler's config dir, so the login persists |
| API token auth | Forwards any `CLOUDFLARE_*` and `WRANGLER_*` env vars that are set (by name, values never on argv) |
| OAuth callback unreachable from the browser | Publishes `127.0.0.1:8976` and adds `--callback-host=0.0.0.0 --callback-port=8976 --browser=false` to `wrangler login` |
| `wrangler dev` unreachable on `localhost:8787` | Adds `--ip=0.0.0.0` to `wrangler dev` / `wrangler pages dev` |
| `workerd` (used by `wrangler dev`) has no Alpine/musl build | Uses `node:<version>-bookworm` instead of `-alpine` for wrangler projects |

Current wrangler 4 needs Node 22 or newer. The default image (Node 26) is fine; only projects that pin an older version in `.nvmrc`, `.node-version` or `engines` need to raise it.

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

**`npm run dev` scripts:** the shim can only add `--ip` when `wrangler` appears in the command line. If wrangler is started from a package.json script, set the listen address in `wrangler.toml` instead:
```toml
[dev]
ip = "0.0.0.0"
```

Settings:

| Variable | Default | Purpose |
|---|---|---|
| `NODE_SHIMS_WRANGLER` | `auto` | `1` forces wrangler handling on (e.g. monorepo root), `0` turns it off |
| `NODE_SHIMS_WRANGLER_CONFIG_DIR` | `~/.config/node-shims/wrangler` | Host dir for wrangler's config/OAuth token, or `none` |
| `NODE_SHIMS_WRANGLER_FLAGS` | on | `0` stops the shim from adding `--callback-host`, `--ip` and similar flags (wrangler 3 does not know `--callback-host`) |
| `WRANGLER_LOGIN_PORT` | `8976` | Login callback port |

If you previously ran `npm install` in a wrangler project with the Alpine image, delete `node_modules` and reinstall, since packages with musl/glibc variants (e.g. Rollup) were installed for Alpine.

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

## How It Works

1. **Shims intercept commands** - `node`, `npm`, `yarn`, `pnpm` commands are caught by shims
2. **Docker containers** - Commands run in isolated Docker containers
3. **Volume mounting** - Your project is mounted at its real host path (and as `/work`) so `node /Users/…/script.js` works; caches are mounted separately
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

### `op run` environment is dropped
`docker run` does not inherit the host environment. When the shim’s **direct parent** is `op run` (1Password CLI), exported host vars are forwarded with `-e NAME` so a FIFO `.env` that `op` already resolved reaches the container. `PATH` / `HOME` / `TMPDIR` and similar are not forwarded (they would break the image).

This does nothing if `op` is not installed, and nothing for `npm` / `node` started from a shell. `op run --env-file=.env -- npm install` *will* forward, because that is what wrapping the command in `op run` means. Host tools the image lacks (`gcloud`) still need `NODE_SHIMS_MODE=local`. `NODE_SHIMS_DEBUG=1` logs how many vars were forwarded.
