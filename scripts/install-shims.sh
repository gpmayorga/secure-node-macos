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

# Put bin/ on PATH through the shell rc file. Safe to run again, and from
# another clone or worktree: an existing shims PATH line is repointed at this
# repo instead of adding a second one.
case "$SHELL" in
  */zsh) shell_rc="${HOME}/.zshrc" ;;
  */bash) shell_rc="${HOME}/.bashrc" ;;
  *) shell_rc="${HOME}/.zshrc" ;; # Default to zsh on macOS
esac
path_line="export PATH=\"$repo_root/bin:\$PATH\""

# Rewrite $1 to stdout with every shims PATH line pointing at this repo. A
# shims line is `export PATH="<dir>/bin:$PATH"` that follows the installer's
# marker comment, or whose <dir>/bin holds the shims. The first match is
# replaced; later ones are commented out so the file never has two.
repoint_shims_path() {
    local line dir prev="" found=0
    local re='^[[:space:]]*export PATH="(.*/bin):\$PATH"[[:space:]]*$'
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $re ]]; then
            dir="${BASH_REMATCH[1]}"
            if [[ "$prev" == "# Added by node-in-docker-macos-hardening"* \
               || "$prev" == "# Added by secure-node-macos"* \
               || ( -f "$dir/common.sh" && -f "$dir/node" ) ]]; then
                if (( found == 0 )); then
                    printf '%s\n' "$path_line"
                else
                    printf '# %s  # replaced by secure-node-macos install-shims.sh\n' "$line"
                fi
                found=$((found + 1))
                prev="$line"
                continue
            fi
        fi
        printf '%s\n' "$line"
        prev="$line"
    done < "$1"
    (( found > 0 ))
}

backup_rc() {
    cp "$shell_rc" "$shell_rc.backup.$(date +%Y%m%d_%H%M%S)"
}

new_rc="$(mktemp)"
trap 'rm -f "$new_rc"' EXIT
if [[ -f "$shell_rc" ]] && grep -qxF "$path_line" "$shell_rc"; then
    echo "✅ $repo_root/bin already on PATH in $shell_rc"
elif [[ -f "$shell_rc" ]] && repoint_shims_path "$shell_rc" > "$new_rc"; then
    backup_rc
    # cat, not mv: keeps the file's permissions and any symlink to it
    cat "$new_rc" > "$shell_rc"
    echo "✅ Repointed the shims PATH line in $shell_rc to $repo_root/bin"
else
    case ":$PATH:" in
      *":$repo_root/bin:"*)
        echo "✅ $repo_root/bin already on PATH (not set in $shell_rc)"
        ;;
      *)
        [[ -f "$shell_rc" ]] && backup_rc
        {
            echo ""
            echo "# Node.js shims - Docker-based Node.js tools"
            echo "# Added by secure-node-macos install-shims.sh"
            echo "$path_line"
        } >> "$shell_rc"
        echo "✅ Added $repo_root/bin to PATH in $shell_rc"
        ;;
    esac
fi

# Create cache directories
echo "📁 Creating cache directories..."
mkdir -p "$HOME/.npm" "$HOME/.cache/pnpm" "$HOME/.cache/yarn" "$HOME/.yarn/berry" "$HOME/.config/pnpm"

# Test Docker connectivity
echo "🐳 Testing Docker connectivity..."
echo "   Note: You may see a macOS security dialog asking for permission to access data from other apps."
echo "   This is normal because Docker needs to access system resources to run containers."
echo "   Click 'Allow' to continue - this is required for the Node.js shims to work properly."
echo ""
if docker run --rm node:lts node --version >/dev/null 2>&1; then
    echo "✅ Docker connectivity test passed"
else
    echo "⚠️  Docker connectivity test failed - please check your internet connection"
fi

# Teach AI coding agents (Claude Code) how the shims work
echo "🤖 Setting up the agent skill..."
"$repo_root/scripts/install-agent-skill.sh" || echo "⚠️  Agent skill setup failed; run scripts/install-agent-skill.sh later"

echo ""
echo "🎉 Shims installed successfully!"
echo "💡 Restart your shell or run: source ~/.zshrc"
echo ""
echo "Available commands:"
echo "  • node, npm, npx, yarn, pnpm, corepack"
echo "  • All run in Docker containers with your project mounted"
echo "  • Automatically use Node.js version from package.json engines field"
