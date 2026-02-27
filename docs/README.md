# Sandboxed Claude Code with OrbStack + Incus

A complete setup for running Claude Code agents in YOLO mode (`--dangerously-skip-permissions`) inside isolated Incus system containers, nested inside an OrbStack Linux machine on macOS.

## Architecture

```
macOS (your laptop — SAFE, never touched by agents)
│
└── OrbStack machine "sandbox" (lightweight Linux VM, shared kernel)
    │   Ports on 0.0.0.0 auto-forward to macOS localhost
    │
    └── Incus (btrfs storage, incusbr0 bridge)
        │
        ├── Golden image: Ubuntu 24.04 + Docker + Claude Code + dev tools
        │   (snapshot "ready" — used as CoW clone source)
        │
        ├── agent-proj-alpha  ← clone of golden
        │   ├── /workspace/proj-alpha (bind mount or git clone)
        │   ├── Docker daemon (testcontainers, compose)
        │   ├── SSH on port 22 → proxied to sandbox:2201 → macOS localhost:2201
        │   └── App on port 8080 → proxied to sandbox:8001 → macOS localhost:8001
        │
        ├── agent-proj-beta   ← clone of golden
        │   ├── /workspace/proj-beta
        │   ├── Docker daemon
        │   ├── SSH → sandbox:2202 → macOS localhost:2202
        │   └── App → sandbox:8002 → macOS localhost:8002
        │
        ├── agent-proj-gamma  ← clone of golden
        │   ├── /workspace/proj-gamma
        │   └── ...ports 2203, 8003...
        │
        └── agent-proj-alpha-wt-hotfix  ← clone of golden (worktree of proj-alpha)
            ├── /workspace/proj-alpha-hotfix (git worktree)
            └── ...ports 2204, 8004...
```

### Port forwarding chain

```
Incus container (app listens on 0.0.0.0:8080)
  ↓ incus proxy device: listen=tcp:0.0.0.0:8001 connect=tcp:127.0.0.1:8080
OrbStack machine (now listening on 0.0.0.0:8001)
  ↓ OrbStack auto-forward (detects services on 0.0.0.0)
macOS localhost:8001
```

This works for **any protocol**: HTTP, WebSocket, gRPC, raw TCP, SSH. No restrictions.

## Prerequisites

- **macOS** with Apple Silicon or Intel
- **OrbStack** installed (`brew install orbstack` or download from orbstack.dev)
- **Claude Code API key** (ANTHROPIC_API_KEY)
- At least **16GB RAM** recommended (each container uses ~2-4GB under load)

## Setup

### Step 1: Create the OrbStack machine

```bash
orb create ubuntu:noble sandbox
```

### Step 2: Install Incus inside the machine

```bash
orb run -m sandbox bash << 'SETUP'
set -e

# Add Zabbly repo for latest Incus
curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg
cat > /etc/apt/sources.list.d/zabbly-incus.list << EOF
deb [signed-by=/etc/apt/keyrings/zabbly.gpg] https://pkgs.zabbly.com/incus/stable $(. /etc/os-release && echo $VERSION_CODENAME) main
EOF

apt-get update
apt-get install -y incus btrfs-progs

# Initialize Incus with btrfs backend (best CoW support)
cat << INIT | incus admin init --preseed
config: {}
networks:
  - config:
      ipv4.address: 10.100.0.1/24
      ipv4.nat: "true"
      ipv6.address: none
    description: ""
    name: incusbr0
    type: bridge
storage_pools:
  - config: {}
    description: ""
    name: default
    driver: btrfs
profiles:
  - config: {}
    description: ""
    devices:
      eth0:
        name: eth0
        network: incusbr0
        type: nic
      root:
        path: /
        pool: default
        type: disk
    name: default
INIT

echo "Incus initialized successfully"
incus version
SETUP
```

### Step 3: Build the golden image

```bash
orb run -m sandbox bash << 'GOLDEN'
set -e

# Launch base container with Docker nesting enabled
incus launch images:ubuntu/24.04 golden \
  -c security.nesting=true \
  -c security.syscalls.intercept.mknod=true \
  -c security.syscalls.intercept.setxattr=true

# Wait for container to be ready
sleep 5
incus exec golden -- cloud-init status --wait 2>/dev/null || true

# Install everything we need inside the golden image
incus exec golden -- bash << 'INNER'
set -e
export DEBIAN_FRONTEND=noninteractive

# Core tools
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

# Node.js (via NodeSource for latest LTS)
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# Claude Code
npm install -g @anthropic-ai/claude-code

# Rust (common requirement)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# Configure SSH
mkdir -p /run/sshd
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
echo "root:sandbox" | chpasswd

# Configure Docker to start on boot
systemctl enable docker
systemctl enable ssh

# Create workspace directory
mkdir -p /workspace

# Clean up
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Golden image setup complete"
INNER

# Stop and snapshot
incus stop golden
incus snapshot create golden ready
echo "Golden snapshot 'ready' created"
GOLDEN
```

### Step 4: Install the management scripts on macOS

Save these scripts somewhere in your PATH (e.g., `~/.local/bin/`):

## Management scripts

### `sandbox-create` — Create a new agent container

```bash
#!/usr/bin/env bash
# sandbox-create <name> <slot> [git-repo-url] [branch]
#
# Creates a new Incus container from the golden image.
# slot: integer (1-99) that determines port allocation:
#   SSH:  2200 + slot  (e.g., slot 1 → 2201)
#   App:  8000 + slot  (e.g., slot 1 → 8001)
#   Alt:  9000 + slot  (e.g., slot 1 → 9001)
#
# Examples:
#   sandbox-create proj-alpha 1 git@github.com:me/alpha.git
#   sandbox-create proj-beta 2 git@github.com:me/beta.git main
#   sandbox-create proj-alpha-hotfix 4 git@github.com:me/alpha.git hotfix/auth

set -euo pipefail

NAME="${1:?Usage: sandbox-create <name> <slot> [git-repo-url] [branch]}"
SLOT="${2:?Slot number required (1-99)}"
REPO="${3:-}"
BRANCH="${4:-}"

SSH_PORT=$((2200 + SLOT))
APP_PORT=$((8000 + SLOT))
ALT_PORT=$((9000 + SLOT))

CONTAINER="agent-${NAME}"

echo "Creating container '${CONTAINER}' (slot ${SLOT})..."
echo "  SSH:  localhost:${SSH_PORT}"
echo "  App:  localhost:${APP_PORT}"
echo "  Alt:  localhost:${ALT_PORT}"

orb run -m sandbox bash << EOF
set -e

# Clone from golden snapshot (instant with btrfs CoW)
incus copy golden/ready ${CONTAINER}

# Configure resource limits
incus config set ${CONTAINER} limits.cpu=4
incus config set ${CONTAINER} limits.memory=8GiB

# Add proxy devices for port forwarding
incus config device add ${CONTAINER} ssh-proxy proxy \
  listen=tcp:0.0.0.0:${SSH_PORT} connect=tcp:127.0.0.1:22

incus config device add ${CONTAINER} app-proxy proxy \
  listen=tcp:0.0.0.0:${APP_PORT} connect=tcp:127.0.0.1:8080

incus config device add ${CONTAINER} alt-proxy proxy \
  listen=tcp:0.0.0.0:${ALT_PORT} connect=tcp:127.0.0.1:9090

# Start the container
incus start ${CONTAINER}

# Wait for networking
sleep 3

# Clone repo if provided
if [ -n "${REPO}" ]; then
  echo "Cloning ${REPO}..."
  if [ -n "${BRANCH}" ]; then
    incus exec ${CONTAINER} -- git clone --branch "${BRANCH}" "${REPO}" /workspace/project
  else
    incus exec ${CONTAINER} -- git clone "${REPO}" /workspace/project
  fi
fi

echo "Container ${CONTAINER} is running"
EOF

echo ""
echo "=== Container '${CONTAINER}' ready ==="
echo ""
echo "Connect:"
echo "  SSH:          ssh -o StrictHostKeyChecking=no -p ${SSH_PORT} root@localhost"
echo "  VS Code:      code --remote ssh-remote+root@localhost:${SSH_PORT} /workspace/project"
echo "  Test app:     http://localhost:${APP_PORT}"
echo "  Alt port:     http://localhost:${ALT_PORT}"
echo ""
echo "Start Claude Code:"
echo "  ssh -p ${SSH_PORT} root@localhost 'cd /workspace/project && ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-\$ANTHROPIC_API_KEY} claude --dangerously-skip-permissions'"
echo ""
echo "Or interactively:"
echo "  ssh -t -p ${SSH_PORT} root@localhost 'cd /workspace/project && bash'"
```

### `sandbox-worktree` — Add a worktree to an existing project's repo

```bash
#!/usr/bin/env bash
# sandbox-worktree <source-name> <worktree-name> <slot> <branch>
#
# Creates a new container with a git worktree from an existing container's repo.
#
# Example:
#   sandbox-worktree proj-alpha proj-alpha-hotfix 4 hotfix/auth-fix

set -euo pipefail

SOURCE="${1:?Usage: sandbox-worktree <source-name> <worktree-name> <slot> <branch>}"
NAME="${2:?Worktree container name required}"
SLOT="${3:?Slot number required}"
BRANCH="${4:?Branch name required}"

SSH_PORT=$((2200 + SLOT))
APP_PORT=$((8000 + SLOT))
ALT_PORT=$((9000 + SLOT))

SOURCE_CONTAINER="agent-${SOURCE}"
CONTAINER="agent-${NAME}"

echo "Creating worktree container '${CONTAINER}' from '${SOURCE_CONTAINER}'..."

orb run -m sandbox bash << EOF
set -e

# Clone from golden (clean environment, not from source)
incus copy golden/ready ${CONTAINER}
incus config set ${CONTAINER} limits.cpu=4
incus config set ${CONTAINER} limits.memory=8GiB

# Add proxy devices
incus config device add ${CONTAINER} ssh-proxy proxy \
  listen=tcp:0.0.0.0:${SSH_PORT} connect=tcp:127.0.0.1:22
incus config device add ${CONTAINER} app-proxy proxy \
  listen=tcp:0.0.0.0:${APP_PORT} connect=tcp:127.0.0.1:8080
incus config device add ${CONTAINER} alt-proxy proxy \
  listen=tcp:0.0.0.0:${ALT_PORT} connect=tcp:127.0.0.1:9090

incus start ${CONTAINER}
sleep 3

# Get the repo URL from the source container
REPO_URL=\$(incus exec ${SOURCE_CONTAINER} -- git -C /workspace/project remote get-url origin)

# Clone the same repo and checkout the worktree branch
incus exec ${CONTAINER} -- git clone "\${REPO_URL}" /workspace/project
incus exec ${CONTAINER} -- bash -c "cd /workspace/project && git checkout -b ${BRANCH} 2>/dev/null || git checkout ${BRANCH}"

echo "Container ${CONTAINER} ready with branch ${BRANCH}"
EOF

echo ""
echo "=== Worktree container '${CONTAINER}' ready ==="
echo "  Branch: ${BRANCH}"
echo "  SSH:    ssh -p ${SSH_PORT} root@localhost"
echo "  App:    http://localhost:${APP_PORT}"
```

### `sandbox-expose` — Dynamically expose additional ports

```bash
#!/usr/bin/env bash
# sandbox-expose <name> <host-port> <container-port> [protocol]
#
# Add a new port proxy to a running container.
#
# Examples:
#   sandbox-expose proj-alpha 5433 5432          # Postgres
#   sandbox-expose proj-alpha 6380 6379          # Redis
#   sandbox-expose proj-alpha 3001 3000          # Dev server
#   sandbox-expose proj-alpha 4443 443           # HTTPS
#   sandbox-expose proj-alpha 5555 5555 udp      # UDP port

set -euo pipefail

NAME="${1:?Usage: sandbox-expose <name> <host-port> <container-port> [protocol]}"
HOST_PORT="${2:?Host port required}"
CONTAINER_PORT="${3:?Container port required}"
PROTO="${4:-tcp}"

CONTAINER="agent-${NAME}"
DEVICE_NAME="port-${HOST_PORT}"

orb run -m sandbox incus config device add "${CONTAINER}" "${DEVICE_NAME}" proxy \
  "listen=${PROTO}:0.0.0.0:${HOST_PORT}" \
  "connect=${PROTO}:127.0.0.1:${CONTAINER_PORT}"

echo "Exposed ${CONTAINER}:${CONTAINER_PORT} → localhost:${HOST_PORT} (${PROTO})"
```

### `sandbox-list` — Show all running agent containers

```bash
#!/usr/bin/env bash
# sandbox-list — List all agent containers with their ports

orb run -m sandbox bash << 'EOF'
echo ""
printf "%-30s %-10s %-8s %-8s %-8s\n" "CONTAINER" "STATE" "SSH" "APP" "ALT"
printf "%-30s %-10s %-8s %-8s %-8s\n" "─────────" "─────" "───" "───" "───"

for container in $(incus list -f csv -c n | grep "^agent-"); do
  state=$(incus info "$container" | grep "Status:" | awk '{print $2}')
  
  # Extract proxy ports
  ssh_port=$(incus config device get "$container" ssh-proxy listen 2>/dev/null | grep -oP ':\K\d+$' || echo "-")
  app_port=$(incus config device get "$container" app-proxy listen 2>/dev/null | grep -oP ':\K\d+$' || echo "-")
  alt_port=$(incus config device get "$container" alt-proxy listen 2>/dev/null | grep -oP ':\K\d+$' || echo "-")
  
  printf "%-30s %-10s %-8s %-8s %-8s\n" "$container" "$state" "$ssh_port" "$app_port" "$alt_port"
done

echo ""
# Also show any extra exposed ports
for container in $(incus list -f csv -c n | grep "^agent-"); do
  extras=$(incus config device list "$container" 2>/dev/null | grep "^port-" || true)
  if [ -n "$extras" ]; then
    echo "Extra ports on $container:"
    for dev in $extras; do
      listen=$(incus config device get "$container" "$dev" listen 2>/dev/null)
      connect=$(incus config device get "$container" "$dev" connect 2>/dev/null)
      echo "  $listen → $connect"
    done
  fi
done
EOF
```

### `sandbox-stop` — Stop and optionally remove a container

```bash
#!/usr/bin/env bash
# sandbox-stop <name> [--rm]
#
# Stop a container. Pass --rm to also delete it.

set -euo pipefail

NAME="${1:?Usage: sandbox-stop <name> [--rm]}"
REMOVE="${2:-}"

CONTAINER="agent-${NAME}"

orb run -m sandbox bash << EOF
incus stop "${CONTAINER}" --force 2>/dev/null || true
echo "Stopped ${CONTAINER}"

if [ "${REMOVE}" = "--rm" ]; then
  incus delete "${CONTAINER}"
  echo "Deleted ${CONTAINER}"
fi
EOF
```

### `sandbox-shell` — Quick shell into a container

```bash
#!/usr/bin/env bash
# sandbox-shell <name> [command]
#
# Open an interactive shell (or run a command) in the container.
#
# Examples:
#   sandbox-shell proj-alpha
#   sandbox-shell proj-alpha "cd /workspace/project && git status"

NAME="${1:?Usage: sandbox-shell <name> [command]}"
shift
COMMAND="${*:-bash}"
CONTAINER="agent-${NAME}"

orb run -m sandbox incus exec "${CONTAINER}" -- bash -c "${COMMAND}"
```

### `sandbox-claude` — Start Claude Code in a container

```bash
#!/usr/bin/env bash
# sandbox-claude <name> [extra-claude-args...]
#
# Start Claude Code in YOLO mode inside the container.
#
# Examples:
#   sandbox-claude proj-alpha
#   sandbox-claude proj-alpha --model sonnet
#   sandbox-claude proj-alpha --resume

set -euo pipefail

NAME="${1:?Usage: sandbox-claude <name> [extra-claude-args...]}"
shift
EXTRA_ARGS="${*:-}"

CONTAINER="agent-${NAME}"

orb run -m sandbox incus exec "${CONTAINER}" -- bash -c \
  "cd /workspace/project && \
   export ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY}' && \
   claude --dangerously-skip-permissions ${EXTRA_ARGS}"
```

### `sandbox-tmux` — Monitor multiple agents in tmux

```bash
#!/usr/bin/env bash
# sandbox-tmux [name1] [name2] [name3] ...
#
# Opens a tmux session with one pane per agent container.
# If no names given, opens panes for ALL running agent containers.
#
# Examples:
#   sandbox-tmux proj-alpha proj-beta proj-gamma
#   sandbox-tmux   # all running agents

SESSION="agents"

# Kill existing session if present
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Get container list
if [ $# -gt 0 ]; then
  CONTAINERS=("$@")
else
  # Get all running agent containers
  mapfile -t CONTAINERS < <(orb run -m sandbox incus list -f csv -c n status=running | grep "^agent-" | sed 's/^agent-//')
fi

if [ ${#CONTAINERS[@]} -eq 0 ]; then
  echo "No agent containers found"
  exit 1
fi

echo "Opening tmux session with ${#CONTAINERS[@]} panes:"
for c in "${CONTAINERS[@]}"; do echo "  - agent-${c}"; done

# Create session with first container
FIRST="${CONTAINERS[0]}"
SSH_PORT=$(orb run -m sandbox incus config device get "agent-${FIRST}" ssh-proxy listen 2>/dev/null | grep -oP ':\K\d+$')
tmux new-session -d -s "$SESSION" -n "agents" \
  "ssh -o StrictHostKeyChecking=no -p ${SSH_PORT} root@localhost"

# Add panes for remaining containers
for ((i=1; i<${#CONTAINERS[@]}; i++)); do
  NAME="${CONTAINERS[$i]}"
  SSH_PORT=$(orb run -m sandbox incus config device get "agent-${NAME}" ssh-proxy listen 2>/dev/null | grep -oP ':\K\d+$')
  tmux split-window -t "$SESSION" \
    "ssh -o StrictHostKeyChecking=no -p ${SSH_PORT} root@localhost"
  tmux select-layout -t "$SESSION" tiled
done

# Attach
tmux attach-session -t "$SESSION"
```

### `sandbox-nuke` — Destroy everything and start fresh

```bash
#!/usr/bin/env bash
# sandbox-nuke — Remove ALL agent containers (keeps golden image)
# Pass --all to also remove the golden image

set -euo pipefail

FLAG="${1:-}"

echo "This will destroy ALL agent containers."
read -p "Are you sure? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted"
  exit 0
fi

orb run -m sandbox bash << EOF
# Stop and delete all agent containers
for container in \$(incus list -f csv -c n | grep "^agent-"); do
  echo "Destroying \$container..."
  incus delete "\$container" --force
done

if [ "${FLAG}" = "--all" ]; then
  echo "Destroying golden image..."
  incus delete golden --force 2>/dev/null || true
  echo "Everything destroyed. Re-run Steps 3-4 to rebuild."
else
  echo "All agent containers destroyed. Golden image preserved."
fi
EOF
```

## Walkthrough: 3 projects + 1 worktree

This walkthrough sets up exactly the scenario described: three independent projects running in parallel, each with its own Claude Code agent, plus a fourth worktree branch for a hotfix on the first project. You monitor all four simultaneously in tmux.

### 1. Create the three project containers

```bash
# Ensure API key is set
export ANTHROPIC_API_KEY="sk-ant-..."

# Project Alpha: a Rust web service
sandbox-create proj-alpha 1 git@github.com:yourorg/alpha-service.git

# Project Beta: a React frontend
sandbox-create proj-beta 2 git@github.com:yourorg/beta-frontend.git

# Project Gamma: a Python data pipeline
sandbox-create proj-gamma 3 git@github.com:yourorg/gamma-pipeline.git
```

### 2. Start Claude Code agents in each

In three separate terminal tabs:

```bash
# Terminal 1
sandbox-claude proj-alpha

# Terminal 2
sandbox-claude proj-beta

# Terminal 3
sandbox-claude proj-gamma
```

Or, use tmux to see all three at once:

```bash
sandbox-tmux proj-alpha proj-beta proj-gamma
# Then in each pane, run:
# cd /workspace/project && ANTHROPIC_API_KEY=sk-ant-... claude --dangerously-skip-permissions
```

### 3. Test the apps from your Mac

```bash
# Alpha's web service
curl http://localhost:8001/health

# Beta's React dev server (if running on 3000 inside container)
sandbox-expose proj-beta 3002 3000
open http://localhost:3002

# Gamma's API
curl http://localhost:8003/api/status
```

### 4. Add a hotfix worktree for Alpha

While the Alpha agent continues working on `main`, spin up a new container for a hotfix:

```bash
sandbox-worktree proj-alpha proj-alpha-hotfix 4 hotfix/auth-fix
sandbox-claude proj-alpha-hotfix
```

### 5. Monitor all four agents

```bash
sandbox-tmux proj-alpha proj-beta proj-gamma proj-alpha-hotfix
```

This opens tmux with four tiled panes, each SSH'd into a container. The layout:

```
┌─────────────────────┬─────────────────────┐
│ agent-proj-alpha    │ agent-proj-beta     │
│ (main branch)       │ (React frontend)    │
│                     │                     │
├─────────────────────┼─────────────────────┤
│ agent-proj-gamma    │ agent-proj-alpha-   │
│ (Python pipeline)   │ hotfix              │
│                     │ (hotfix/auth-fix)   │
└─────────────────────┴─────────────────────┘
```

### 6. Connect VS Code for code review

```bash
# Open VS Code connected to Alpha's container
code --remote ssh-remote+root@localhost:2201 /workspace/project

# Or add to ~/.ssh/config for convenience:
# Host sandbox-alpha
#   HostName localhost
#   Port 2201
#   User root
#   StrictHostKeyChecking no
```

### 7. Clean up when done

```bash
# Stop one container (preserves data)
sandbox-stop proj-gamma

# Remove a container entirely
sandbox-stop proj-alpha-hotfix --rm

# Nuclear: remove all agents
sandbox-nuke

# Nuclear+: remove everything including golden image
sandbox-nuke --all
```

## Port allocation convention

| Slot | SSH    | App    | Alt    | Suggested use          |
|------|--------|--------|--------|------------------------|
| 1    | 2201   | 8001   | 9001   | Project Alpha          |
| 2    | 2202   | 8002   | 9002   | Project Beta           |
| 3    | 2203   | 8003   | 9003   | Project Gamma          |
| 4    | 2204   | 8004   | 9004   | Worktree / branch      |
| 5-9  | 220x   | 800x   | 900x   | Additional agents      |
| 10+  | 22xx   | 80xx   | 90xx   | Overflow               |

Use `sandbox-expose` for additional ports beyond the three defaults (SSH, App, Alt).

## SSH config for convenience

Add to `~/.ssh/config` on macOS:

```
Host sandbox-*
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  User root
  LogLevel ERROR

Host sandbox-alpha
  HostName localhost
  Port 2201

Host sandbox-beta
  HostName localhost
  Port 2202

Host sandbox-gamma
  HostName localhost
  Port 2203

Host sandbox-alpha-hotfix
  HostName localhost
  Port 2204
```

Then: `ssh sandbox-alpha`, `code --remote ssh-remote+sandbox-alpha /workspace/project`

## Security notes

**What's protected:**
- Your macOS filesystem is completely isolated — agents can't read/write your Mac files
- Each Incus container has its own filesystem, process space, and Docker daemon
- Containers run as unprivileged (UID-mapped) — root inside ≠ root on host
- Seccomp + AppArmor profiles are enabled by default in Incus
- A `rm -rf /` inside a container only destroys that container

**What's NOT protected by default:**
- Network egress — agents can reach the internet (add iptables rules in the OrbStack machine to restrict this)
- Container-to-container — containers on incusbr0 can talk to each other (add Incus network ACLs if needed)
- OrbStack shared kernel — a kernel exploit could theoretically escape (unlikely for AI agent threat model)

**Optional: Egress filtering**

To restrict outbound network access, add iptables rules inside the OrbStack machine:

```bash
orb run -m sandbox bash << 'EGRESS'
# Default deny outbound from containers, allow only essentials
iptables -I FORWARD -i incusbr0 -o eth0 -j DROP

# Allow DNS
iptables -I FORWARD -i incusbr0 -o eth0 -p udp --dport 53 -j ACCEPT
iptables -I FORWARD -i incusbr0 -o eth0 -p tcp --dport 53 -j ACCEPT

# Allow HTTPS (package managers, git, API calls)
iptables -I FORWARD -i incusbr0 -o eth0 -p tcp --dport 443 -j ACCEPT

# Allow HTTP (some package repos)
iptables -I FORWARD -i incusbr0 -o eth0 -p tcp --dport 80 -j ACCEPT

# Allow SSH (git over SSH)
iptables -I FORWARD -i incusbr0 -o eth0 -p tcp --dport 22 -j ACCEPT

# Allow established connections back in
iptables -I FORWARD -i eth0 -o incusbr0 -m state --state ESTABLISHED,RELATED -j ACCEPT
EGRESS
```

For stricter control, use domain-based filtering with a transparent proxy (mitmproxy or squid).

## Troubleshooting

**Incus containers can't start Docker:**
```bash
# Verify nesting is enabled
orb run -m sandbox incus config get agent-proj-alpha security.nesting
# Should return: true
```

**Port not accessible from macOS:**
```bash
# Check the proxy device exists
orb run -m sandbox incus config device show agent-proj-alpha

# Verify the service is listening inside the container
orb run -m sandbox incus exec agent-proj-alpha -- ss -tlnp

# Test from inside the OrbStack machine
orb run -m sandbox curl -s http://localhost:8001
```

**Container runs out of disk:**
```bash
# Increase root disk size
orb run -m sandbox incus config device set agent-proj-alpha root size=50GiB
```

**OrbStack machine runs out of resources:**
```bash
# Check resource usage
orb run -m sandbox incus list -f csv -c nSsm

# Adjust OrbStack's global limits
orb config set memory_mib 16384
orb config set cpu 8
```
