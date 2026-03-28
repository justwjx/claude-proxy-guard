#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="$HOME/.claude-proxy-guard.zsh"
CONFIG_FILE="$HOME/.claude-proxy-guard.conf"
CACHE_DIR="$HOME/.cache/claude-proxy-guard"
ZSHRC="$HOME/.zshrc"
MARKER="# Claude Proxy Guard"

echo "Uninstalling Claude Proxy Guard..."

if [[ -f "$TARGET_FILE" ]]; then
  rm "$TARGET_FILE"
  echo "Removed: $TARGET_FILE"
fi

if [[ -f "$CONFIG_FILE" ]]; then
  read -p "Remove config file ($CONFIG_FILE)? [y/N]: " choice
  if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    rm "$CONFIG_FILE"
    echo "Removed: $CONFIG_FILE"
  else
    echo "Kept: $CONFIG_FILE"
  fi
fi

if [[ -d "$CACHE_DIR" ]]; then
  rm -rf "$CACHE_DIR"
  echo "Removed: $CACHE_DIR"
fi

if [[ -f "$ZSHRC" ]] && grep -qF "$MARKER" "$ZSHRC"; then
  sed -i '' "/$MARKER/,+1d" "$ZSHRC"
  echo "Removed source line from $ZSHRC"
fi

echo ""
echo "Uninstall complete. Open a new terminal to apply changes."
