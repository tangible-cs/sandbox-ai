#!/usr/bin/env bash
# stacks/base.sh — Core golden image: Docker, Node, Claude Code, Python 3, dev tools
# Usage: called by sandbox-setup, runs INSIDE the Incus container via incus exec
set -e
export DEBIAN_FRONTEND=noninteractive

echo "Installing base tools..."

apt-get update
apt-get install -y \
  curl git tmux openssh-server ripgrep jq htop wget unzip \
  build-essential ca-certificates gnupg lsb-release \
  python3 python3-pip python3-venv

# Docker (official repo)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Node.js 22 LTS (via NodeSource)
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# Claude Code
npm install -g @anthropic-ai/claude-code

# SSH config
mkdir -p /run/sshd
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
echo "root:sandbox" | chpasswd

# Enable services
systemctl enable docker
systemctl enable ssh

# Create workspace
mkdir -p /workspace

# Cleanup
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Base golden image setup complete"
