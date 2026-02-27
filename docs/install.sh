#!/usr/bin/env bash
# install.sh — Symlink all sandbox-* scripts into ~/.local/bin
set -euo pipefail

DEST="${1:-$HOME/.local/bin}"
mkdir -p "$DEST"

SCRIPT_DIR="$(cd "$(dirname "$0")/scripts" && pwd)"

for script in "$SCRIPT_DIR"/sandbox-*; do
  name="$(basename "$script")"
  ln -sf "$script" "$DEST/$name"
  echo "  Linked $name → $DEST/$name"
done

echo ""
echo "Ensure $DEST is in your PATH:"
echo "  export PATH=\"\$PATH:$DEST\""
echo ""
echo "Then run: sandbox-setup"
