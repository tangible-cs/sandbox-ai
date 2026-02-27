#!/usr/bin/env bash
# stacks/node.sh — Node.js alt package managers + quality/coverage tools
# Runs INSIDE container after base.sh (Node/npm already installed)
set -e
export DEBIAN_FRONTEND=noninteractive

echo "Installing Node stack..."

# Alt package managers
npm install -g pnpm yarn

# Bun runtime
curl -fsSL https://bun.sh/install | bash

# Coverage (uses V8 native coverage)
npm install -g c8

# Linting
npm install -g eslint

# Formatting
npm install -g prettier

echo "Node stack complete"
