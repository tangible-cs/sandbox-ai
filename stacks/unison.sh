#!/usr/bin/env bash
# stacks/unison.sh — Unison toolchain (UCM with built-in LSP + MCP)
# Runs INSIDE container after base.sh
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing Unison stack..."

# Unison Codebase Manager (UCM) via verified release tarball
install_unison_verified

# Verify installation
/usr/local/bin/ucm version

# UCM includes built-in:
#   - LSP server (auto-starts on port 5757 when UCM runs)
#   - MCP server (invoke via: ucm mcp)
# No additional tooling install needed.

# Set UNISON_MIGRATION=auto to skip interactive prompts during migrations (useful for scripting)
echo 'export UNISON_MIGRATION=auto' >> /home/ubuntu/.bashrc

echo "Unison stack complete"
