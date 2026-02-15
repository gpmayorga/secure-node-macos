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
- **yarn & pnpm via corepack** - Automatically uses the correct version via corepack
- **Version-aware** - Respects `packageManager` field in package.json
- **No manual setup** - Just run `yarn` or `pnpm` and they'll be ready
- **Persistent caches** - Package manager caches are mounted and persist between runs

### 📦 **Smart Version Detection**
- **`.nvmrc` support** - Automatically uses Node.js version specified in `.nvmrc`
- **`.node-version` support** - Also supports `.node-version` files
- **`package.json` engines** - Falls back to `engines.node` field if present
- **Latest LTS default** - Uses latest LTS version when no version is specified
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

Wrangler login runs a short-lived OAuth callback server on `localhost`. The shims now expose this automatically on port `8976`, but you can override it if necessary:
```bash
export WRANGLER_LOGIN_PORT=9797
```

### Custom Node.js Image
Override the default image with the `NODE_IMAGE` environment variable:
```bash
export NODE_IMAGE="node:18-alpine"
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
3. **Volume mounting** - Your project directory and caches are mounted
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