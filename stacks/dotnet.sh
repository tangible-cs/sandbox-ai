#!/usr/bin/env bash
# stacks/dotnet.sh — .NET SDK + quality/coverage tools
# Runs INSIDE container after base.sh
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing .NET stack..."

# .NET SDK (latest LTS) via Microsoft package repo
curl -fsSL "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb" -o /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
rm /tmp/packages-microsoft-prod.deb
apt-get update
apt-get install -y dotnet-sdk-8.0
apt-get clean && rm -rf /var/lib/apt/lists/*

# Coverage tool (installed as ubuntu)
su - ubuntu -c 'dotnet tool install --global dotnet-coverage'

# SonarScanner for quality analysis (installed as ubuntu)
su - ubuntu -c 'dotnet tool install --global dotnet-sonarscanner'

# Add dotnet tools to PATH
echo 'export PATH=$PATH:$HOME/.dotnet/tools' >> /home/ubuntu/.bashrc

# Formatting: built-in via `dotnet format`, no install needed
# Security analyzers: installed per-project via NuGet

echo ".NET stack complete"
