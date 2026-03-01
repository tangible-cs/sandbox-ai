#!/usr/bin/env bash
# stacks/unison.sh — Unison toolchain (UCM with built-in LSP + MCP)
# Runs INSIDE container after base.sh
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing Unison stack..."

# Unison Codebase Manager (UCM) via official Debian/Ubuntu apt repo
curl -fsSL https://debian.unison-lang.org/public.gpg \
  | gpg --dearmor -o /etc/apt/trusted.gpg.d/unison-computing.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/unison-computing.gpg] https://debian.unison-lang.org/ trixie main" \
  > /etc/apt/sources.list.d/unison-computing.list
apt-get update
apt-get install -y unisonweb
apt-get clean && rm -rf /var/lib/apt/lists/*

# Verify installation
/usr/bin/ucm version

# UCM includes built-in:
#   - LSP server (auto-starts on port 5757 when UCM runs)
#   - MCP server (invoke via: ucm mcp)
# No additional tooling install needed.

# Set UNISON_MIGRATION=auto to skip interactive prompts during migrations (useful for scripting)
echo 'export UNISON_MIGRATION=auto' >> /home/ubuntu/.bashrc

echo "Unison stack complete"
