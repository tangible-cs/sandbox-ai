#!/usr/bin/env bash
# stacks/node.sh — Node.js alt package managers + quality/coverage tools
# Runs INSIDE container after base.sh (installs Node.js + npm, then tools)
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing Node stack..."

# Node.js 22 LTS (via NodeSource) — moved here from base.sh
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
apt-get clean && rm -rf /var/lib/apt/lists/*

# Alt package managers
npm install -g pnpm yarn

# Bun runtime (installed as ubuntu — lives under /home/ubuntu/.bun)
su - ubuntu -c 'curl -fsSL https://bun.sh/install | bash'

# Coverage (uses V8 native coverage)
npm install -g c8

# Linting
npm install -g eslint

# Formatting
npm install -g prettier

echo "Node stack complete"
