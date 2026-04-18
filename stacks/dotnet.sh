#!/usr/bin/env bash
# stacks/dotnet.sh — .NET SDK + quality/coverage tools
# Runs INSIDE container after base.sh
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing .NET stack..."

# .NET SDK (pinned tarball with official release hash)
install_dotnet_sdk_verified

# Coverage tool (installed as ubuntu)
su - ubuntu -c "dotnet tool install --global dotnet-coverage --version ${DOTNET_COVERAGE_VERSION}"

# SonarScanner for quality analysis (installed as ubuntu)
su - ubuntu -c "dotnet tool install --global dotnet-sonarscanner --version ${DOTNET_SONARSCANNER_VERSION}"

# Add dotnet tools to PATH
append_bashrc_line_once 'export PATH=$PATH:$HOME/.dotnet/tools'

# Formatting: built-in via `dotnet format`, no install needed
# Security analyzers: installed per-project via NuGet

echo ".NET stack complete"
