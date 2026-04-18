#!/usr/bin/env bash
# stacks/python.sh — Python quality/coverage/dependency tools
# Runs INSIDE container after base.sh
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing Python stack..."

# uv — fast package installer and resolver
install_uv_verified

# Poetry — dependency management via verified source tarball
tmp_poetry_dir=$(mktemp -d)
download_verified_asset \
  "https://files.pythonhosted.org/packages/source/p/poetry/poetry-${POETRY_VERSION}.tar.gz" \
  sha256 \
  "${POETRY_SDIST_SHA256}" \
  "${tmp_poetry_dir}/poetry.tar.gz"
pip3 install --break-system-packages "${tmp_poetry_dir}/poetry.tar.gz"
rm -rf "${tmp_poetry_dir}"

# Quality tools: linting+formatting, type checking, security, coverage
pip3 install --break-system-packages \
  "ruff==${RUFF_VERSION}" \
  "mypy==${MYPY_VERSION}" \
  "bandit==${BANDIT_VERSION}" \
  "coverage==${COVERAGE_VERSION}"
rm -rf /root/.cache/pip

echo "Python stack complete"
