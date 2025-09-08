#!/usr/bin/env bash
# Script to completely remove Node.js and related tools from macOS
# This script helps clean up any existing Node.js installations before using the Docker-based approach

set -Eeuo pipefail

# Check if running on macOS
if [ "$(uname -s)" != "Darwin" ]; then
    echo "❌ This script is designed for macOS only"
    exit 1
fi

echo ">>> This will REMOVE Node/NPM/Yarn/PNPM, NVM, and related caches from macOS."
echo ">>> This includes:"
echo "    • Node.js installations (Homebrew, nvm, etc.)"
echo "    • npm, yarn, pnpm global packages and caches"
echo "    • Node.js caches and configuration files"
echo "    • Shell configuration modifications"
echo
read -p "Type 'yes' to proceed: " ans
[[ "${ans}" == "yes" ]]

echo "🛑 Stopping running Node.js processes..."
pkill -f node || true

echo "📦 Uninstalling via Homebrew (if present)..."
if command -v brew >/dev/null 2>&1; then
    brew uninstall --ignore-dependencies node yarn pnpm corepack 2>/dev/null || true
fi

echo "🗑️  Removing NVM and all Node versions..."
# Source nvm if present and uninstall all versions
if [ -s "$HOME/.nvm/nvm.sh" ]; then
    . "$HOME/.nvm/nvm.sh"
    for v in $(nvm ls --no-colors | sed -n 's/.*v\([0-9.]*\).*/\1/p'); do
        nvm uninstall "$v" || true
    done
fi

echo "🧹 Removing system-wide installations..."
# Remove common global paths (Intel + Apple Silicon)
sudo rm -rf \
  /usr/local/lib/node_modules /usr/local/include/node /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/corepack \
  /opt/homebrew/lib/node_modules /opt/homebrew/include/node /opt/homebrew/bin/node /opt/homebrew/bin/npm /opt/homebrew/bin/corepack \
  2>/dev/null || true

echo "🗂️  Removing user caches and configs..."
# Per-user caches/config
rm -rf \
  "$HOME/.npm" "$HOME/.node-gyp" "$HOME/.cache/pnpm" "$HOME/.config/pnpm" \
  "$HOME/.yarn" "$HOME/.config/yarn" "$HOME/.nvm" \
  "$HOME/.npmrc" "$HOME/.yarnrc" "$HOME/.yarnrc.yml" "$HOME/.pnpmrc" \
  2>/dev/null || true

echo "🔧 Cleaning shell configuration files..."
# Scrub PATH lines from common shell configs
for f in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    if [ -f "$f" ]; then
        # Create backup
        cp "$f" "$f.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        # Remove Node.js related lines
        sed -i '' '/NVM_DIR/d;/nvm\.sh/d;/corepack/d;/\.nvm/d;/\.n\//d' "$f" 2>/dev/null || true
    fi
done

echo "✅ Done! Open a new shell to verify 'which node' returns nothing."
echo "💡 You can now use the Docker-based Node.js shims from this repository."
