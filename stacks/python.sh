#!/usr/bin/env bash
# stacks/python.sh — Python quality/coverage/dependency tools
# Runs INSIDE container after base.sh
set -e
export DEBIAN_FRONTEND=noninteractive

echo "Installing Python stack..."

# uv — fast package installer and resolver
curl -LsSf https://astral.sh/uv/install.sh | sh

# Poetry — dependency management
curl -sSL https://install.python-poetry.org | python3 -

# Linting + formatting
pip3 install --break-system-packages ruff

# Type checking
pip3 install --break-system-packages mypy

# Security
pip3 install --break-system-packages bandit

# Coverage
pip3 install --break-system-packages coverage

echo "Python stack complete"
