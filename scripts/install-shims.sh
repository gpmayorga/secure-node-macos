#!/usr/bin/env bash
# Script to install Node.js shims to system PATH
# This script adds the bin/ directory to the user's PATH for easy access to Node.js tools

set -Eeuo pipefail

# Check if we're on macOS
if [ "$(uname -s)" != "Darwin" ]; then
    echo "❌ This script is designed for macOS only"
    exit 1
fi

# Check if Docker is installed and running
if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker is not installed"
    echo "💡 Please install Docker Desktop for Mac: https://www.docker.com/products/docker-desktop"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker daemon is not running"
    echo "💡 Please start Docker Desktop"
    exit 1
fi

echo "🚀 Installing Node.js shims..."

# Get repository root
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Check if already on PATH
case ":$PATH:" in
  *":$repo_root/bin:"*) 
    echo "✅ bin/ already on PATH"
    ;;
  *) 
    # Determine shell config file
    shell_rc="${HOME}/.zshrc"
    [ -n "${BASH_VERSION:-}" ] && shell_rc="${HOME}/.bashrc"
    
    # Create backup
    [ -f "$shell_rc" ] && cp "$shell_rc" "$shell_rc.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Add to PATH
    echo "" >> "$shell_rc"
    echo "# Node.js shims - Docker-based Node.js tools" >> "$shell_rc"
    echo "# Added by node-in-docker-macos-hardening" >> "$shell_rc"
    echo "export PATH=\"$repo_root/bin:\$PATH\"" >> "$shell_rc"
    echo "✅ Added $repo_root/bin to PATH in $shell_rc"
    ;;
esac

# Create cache directories
echo "📁 Creating cache directories..."
mkdir -p "$HOME/.npm" "$HOME/.cache/pnpm" "$HOME/.cache/yarn" "$HOME/.config/pnpm"

# Test Docker connectivity
echo "🐳 Testing Docker connectivity..."
if docker run --rm node:lts node --version >/dev/null 2>&1; then
    echo "✅ Docker connectivity test passed"
else
    echo "⚠️  Docker connectivity test failed - please check your internet connection"
fi

echo ""
echo "🎉 Shims installed successfully!"
echo "💡 Restart your shell or run: source ~/.zshrc"
echo ""
echo "Available commands:"
echo "  • node, npm, npx, yarn, pnpm"
echo "  • All run in Docker containers with your project mounted"
echo "  • Automatically use Node.js version from package.json engines field"
