#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_FILE="$SCRIPT_DIR/claude-proxy-guard.zsh"
TARGET_FILE="$HOME/.claude-proxy-guard.zsh"
ZSHRC="$HOME/.zshrc"
SOURCE_LINE='[[ -f ~/.claude-proxy-guard.zsh ]] && source ~/.claude-proxy-guard.zsh'
MARKER="# Claude Proxy Guard"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Error: This tool is designed for macOS only."
  exit 1
fi

for cmd in curl pgrep zsh; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: Required command '$cmd' not found."
    exit 1
  fi
done

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "Error: claude-proxy-guard.zsh not found in $SCRIPT_DIR"
  exit 1
fi

cp "$SOURCE_FILE" "$TARGET_FILE"
chmod 644 "$TARGET_FILE"
echo "Installed: $TARGET_FILE"

if ! grep -qF "$MARKER" "$ZSHRC" 2>/dev/null; then
  echo "" >> "$ZSHRC"
  echo "$MARKER" >> "$ZSHRC"
  echo "$SOURCE_LINE" >> "$ZSHRC"
  echo "Added source line to $ZSHRC"
else
  echo "Source line already in $ZSHRC (skipped)"
fi

mkdir -p "$HOME/.cache/claude-proxy-guard"
chmod 700 "$HOME/.cache/claude-proxy-guard"

echo ""
echo "Installation complete!"
echo "Open a new terminal or run: source ~/.zshrc"
echo "Then run: claude --guard-status"
