#!/usr/bin/env bash
# stacks/base.sh — Core golden image: Docker, Claude Code, Python 3, dev tools
# Usage: called by sandbox-setup, runs INSIDE the Incus container via incus exec
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "Installing base tools..."

apt-get update
apt-get install -y \
  curl git tmux openssh-server ripgrep jq htop wget unzip \
  build-essential ca-certificates gnupg lsb-release \
  python3 python3-pip python3-venv bubblewrap

# Docker (official repo)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Create non-root user for running sessions (may already exist in Ubuntu images)
if ! id ubuntu &>/dev/null; then
  useradd -m -s /bin/bash -u 1000 ubuntu
fi
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu
chmod 440 /etc/sudoers.d/ubuntu

# Claude Code (installed as ubuntu — credentials live under /home/ubuntu)
su - ubuntu -c 'curl -fsSL https://claude.ai/install.sh | bash'
# Ensure claude is on PATH for non-interactive shells (incus exec)
ln -sf /home/ubuntu/.local/bin/claude /usr/local/bin/claude

# SSH config — key-based auth only (host key injected by sandbox-start)
mkdir -p /run/sshd /root/.ssh /home/ubuntu/.ssh
chmod 700 /root/.ssh /home/ubuntu/.ssh
chown ubuntu:ubuntu /home/ubuntu/.ssh
sed -i 's/#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
passwd -l root

# Docker group for ubuntu user
usermod -aG docker ubuntu

# Enable services
systemctl enable docker
systemctl enable ssh

# Create workspace (owned by ubuntu)
mkdir -p /workspace/project
chown -R ubuntu:ubuntu /workspace

# Cleanup
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Base golden image setup complete"
