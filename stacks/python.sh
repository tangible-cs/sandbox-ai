#!/usr/bin/env bash
# stacks/python.sh — Python quality/coverage/dependency tools
# Runs INSIDE container after base.sh
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing Python stack..."

# uv — fast package installer and resolver (installed as ubuntu)
su - ubuntu -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

# Poetry — dependency management (installed as ubuntu)
su - ubuntu -c 'curl -sSL https://install.python-poetry.org | python3 -'

# Quality tools: linting+formatting, type checking, security, coverage
pip3 install --break-system-packages ruff mypy bandit coverage
rm -rf /root/.cache/pip

echo "Python stack complete"
