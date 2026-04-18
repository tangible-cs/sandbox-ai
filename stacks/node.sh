#!/usr/bin/env bash
# stacks/node.sh — Node.js ecosystem tools for containers that already include Node.js
# Runs INSIDE container after base.sh
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing Node stack..."

# Alt package managers
npm_install_global_verified "pnpm" "${PNPM_VERSION}" "${PNPM_NPM_INTEGRITY}"
npm_install_global_verified "yarn" "${YARN_VERSION}" "${YARN_NPM_INTEGRITY}"

# Bun runtime (installed as ubuntu — lives under /home/ubuntu/.bun)
install_bun_verified

# Coverage (uses V8 native coverage)
npm_install_global_verified "c8" "${C8_VERSION}" "${C8_NPM_INTEGRITY}"

# Linting
npm_install_global_verified "eslint" "${ESLINT_VERSION}" "${ESLINT_NPM_INTEGRITY}"

# Formatting
npm_install_global_verified "prettier" "${PRETTIER_VERSION}" "${PRETTIER_NPM_INTEGRITY}"

echo "Node stack complete"
