# Sandbox Commands Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement 8 commands for running Claude Code agents in isolated Incus containers inside OrbStack on macOS, with automated deploy key management, per-container SSH agent isolation, egress filtering, and multi-stack golden images.

**Architecture:** macOS -> OrbStack VM "sandbox" (Ubuntu Noble) -> Incus containers (btrfs CoW clones of golden images). Each container gets its own SSH agent, deploy key, Docker daemon, and workspace. Port forwarding is bidirectional via Incus proxy devices + iptables egress rules.

**Tech Stack:** Bash scripts, OrbStack CLI (`orb`), Incus, iptables, GitHub CLI (`gh`), ssh-agent, btrfs

**Reference docs:** `docs/README.md` has the original architecture. `docs/sandbox-*` are reference scripts (not used directly, but patterns are reused). `docs/plans/2026-02-27-sandbox-commands-design.md` is the full design spec.

---

## Task 1: Project Structure & .gitignore

**Files:**
- Create: `.gitignore`
- Create: `bin/` (directory)
- Create: `lib/` (directory)
- Create: `stacks/` (directory)

**Step 1: Create directory structure**

```bash
mkdir -p bin lib stacks
```

**Step 2: Create .gitignore**

Create `.gitignore` at the project root:

```gitignore
# OS
.DS_Store

# Editor
*.swp
*.swo
*~
.idea/
.vscode/

# Environment / secrets
.env
*.key
*.pem

# Runtime
*.log

# Serena
.serena/
```

**Step 3: Commit**

```bash
git init
git add .gitignore
git add bin/.gitkeep lib/.gitkeep stacks/.gitkeep
git commit -m "chore: init project structure with .gitignore"
```

Note: create `.gitkeep` files in empty dirs so git tracks them. These get removed as real files are added.

---

## Task 2: Shared Library — lib/sandbox-common.sh

This is the foundation everything else depends on. Build it incrementally.

**Files:**
- Create: `lib/sandbox-common.sh`

**Step 1: Create the shared library with constants and basic helpers**

Create `lib/sandbox-common.sh`:

```bash
#!/usr/bin/env bash
# lib/sandbox-common.sh — Shared functions for sandbox-* commands
# Source this file: SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" && source "${SCRIPT_DIR}/../lib/sandbox-common.sh"

set -euo pipefail

# ── Constants ───────────────────────────────────────────────────────
SANDBOX_MACHINE="sandbox"
SANDBOX_KEY_DIR="${HOME}/.sandbox/keys"
SANDBOX_ENV_FILE="${HOME}/.sandbox/env"
WORKSPACE_DIR="/workspace/project"

# ── Colour helpers (no-op if not a terminal) ────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

info()  { echo -e "${BLUE}${BOLD}[sandbox]${NC} $*"; }
ok()    { echo -e "${GREEN}${BOLD}[sandbox]${NC} $*"; }
warn()  { echo -e "${YELLOW}${BOLD}[sandbox]${NC} $*" >&2; }
err()   { echo -e "${RED}${BOLD}[sandbox]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ── Prerequisite checks ────────────────────────────────────────────
require_command() {
  command -v "$1" &>/dev/null || die "'$1' is required but not found. Install it first."
}

require_orb() {
  require_command orb
  orb list &>/dev/null || die "OrbStack is not running. Start it first."
}

require_machine() {
  require_orb
  orb list 2>/dev/null | grep -q "${SANDBOX_MACHINE}" \
    || die "Sandbox machine not found. Run 'sandbox-setup' first."
}

require_gh() {
  require_command gh
  gh auth status &>/dev/null 2>&1 || die "'gh' is not authenticated. Run 'gh auth login' first."
}

require_golden() {
  local stack="${1:-base}"
  local golden_name="golden-${stack}"
  orb_exec "incus info ${golden_name} &>/dev/null" \
    || die "Golden image '${golden_name}' not found. Run 'sandbox-setup' first."
  orb_exec "incus snapshot list ${golden_name} -f csv 2>/dev/null | grep -q ready" \
    || die "Golden image '${golden_name}' has no 'ready' snapshot. Run 'sandbox-setup' first."
}

# ── OrbStack execution ─────────────────────────────────────────────
orb_exec() {
  orb run -m "${SANDBOX_MACHINE}" bash -c "$1"
}

# ── Container naming ───────────────────────────────────────────────
container_name() {
  echo "agent-${1}"
}

# ── Slot management ────────────────────────────────────────────────
# Port scheme: SSH = 2200+slot, App = 8000+slot, Alt = 9000+slot
ssh_port()  { echo $(( 2200 + $1 )); }
app_port()  { echo $(( 8000 + $1 )); }
alt_port()  { echo $(( 9000 + $1 )); }

# Returns list of currently used slots by querying ssh-proxy listen ports
used_slots() {
  orb_exec '
    for c in $(incus list -f csv -c n 2>/dev/null | grep "^agent-"); do
      port=$(incus config device get "$c" ssh-proxy listen 2>/dev/null | grep -o "[0-9]*$" || true)
      if [ -n "$port" ]; then
        echo $(( port - 2200 ))
      fi
    done
  ' 2>/dev/null | sort -n
}

next_free_slot() {
  local used
  used=$(used_slots)
  for slot in $(seq 1 99); do
    if ! echo "$used" | grep -qx "$slot"; then
      echo "$slot"
      return 0
    fi
  done
  die "No free slots available (all 1-99 in use)"
}

validate_slot() {
  local slot="$1"
  if [[ ! "$slot" =~ ^[0-9]+$ ]] || (( slot < 1 || slot > 99 )); then
    die "Slot must be a number between 1 and 99, got: $slot"
  fi
  local used
  used=$(used_slots)
  if echo "$used" | grep -qx "$slot"; then
    die "Slot $slot is already in use. Used slots: $(echo $used | tr '\n' ' ')"
  fi
}

# ── Deploy key management ──────────────────────────────────────────
# Extracts org/repo from a git URL (SSH or HTTPS)
# e.g., git@github.com:me/alpha.git -> me/alpha
#        https://github.com/me/alpha.git -> me/alpha
parse_repo_nwo() {
  local url="$1"
  echo "$url" | sed -E 's#.*github\.com[:/]##; s#\.git$##'
}

deploy_key_create() {
  local name="$1"
  local repo_url="$2"
  local nwo
  nwo=$(parse_repo_nwo "$repo_url")
  local key_path="${SANDBOX_KEY_DIR}/deploy_${name}"

  mkdir -p "${SANDBOX_KEY_DIR}"

  if [[ -f "$key_path" ]]; then
    warn "Deploy key already exists at ${key_path}, reusing"
    return 0
  fi

  info "Generating deploy key for ${nwo}..."
  ssh-keygen -t ed25519 -f "$key_path" -C "sandbox-${name}" -N "" -q

  info "Registering deploy key on GitHub (${nwo})..."
  gh repo deploy-key add "${key_path}.pub" -R "$nwo" -t "sandbox-${name}" -w \
    || die "Failed to add deploy key to ${nwo}. Check repo admin access."

  ok "Deploy key registered for ${nwo}"
}

deploy_key_cleanup() {
  local name="$1"
  local repo_url="$2"
  local nwo
  nwo=$(parse_repo_nwo "$repo_url")
  local key_path="${SANDBOX_KEY_DIR}/deploy_${name}"

  # Find and delete the deploy key from GitHub
  local key_id
  key_id=$(gh repo deploy-key list -R "$nwo" 2>/dev/null \
    | grep "sandbox-${name}" | awk '{print $1}' || true)

  if [[ -n "$key_id" ]]; then
    info "Removing deploy key from GitHub (${nwo})..."
    gh repo deploy-key delete "$key_id" -R "$nwo" --yes 2>/dev/null || true
  fi

  # Delete local key pair
  rm -f "$key_path" "${key_path}.pub" 2>/dev/null || true
}

# ── SSH agent management (per-container, inside OrbStack VM) ───────
ssh_agent_setup() {
  local container="$1"
  local key_path="$2"  # macOS path to private key
  local socket_path="/tmp/sandbox-agent-${container}.sock"

  # Copy key into OrbStack VM temporarily
  local vm_key="/tmp/sandbox-key-${container}"
  orb run -m "${SANDBOX_MACHINE}" tee "$vm_key" < "$key_path" >/dev/null
  orb_exec "chmod 600 ${vm_key}"

  # Start dedicated ssh-agent and add key
  orb_exec "
    # Kill any existing agent for this container
    if [ -f /tmp/sandbox-agent-${container}.pid ]; then
      kill \$(cat /tmp/sandbox-agent-${container}.pid) 2>/dev/null || true
      rm -f /tmp/sandbox-agent-${container}.pid
    fi
    rm -f ${socket_path}

    eval \$(ssh-agent -a ${socket_path})
    echo \$SSH_AGENT_PID > /tmp/sandbox-agent-${container}.pid
    SSH_AUTH_SOCK=${socket_path} ssh-add ${vm_key}

    # Remove the temporary key from VM disk
    rm -f ${vm_key}
  "

  # Mount the socket into the container
  orb_exec "
    incus config device add ${container} ssh-agent disk \
      source=${socket_path} \
      path=/run/ssh-agent.sock
  "

  # Set SSH_AUTH_SOCK in container's bashrc
  orb_exec "
    incus exec ${container} -- bash -c '
      grep -q SSH_AUTH_SOCK /root/.bashrc 2>/dev/null || \
        echo \"export SSH_AUTH_SOCK=/run/ssh-agent.sock\" >> /root/.bashrc
    '
  "
}

ssh_agent_cleanup() {
  local container="$1"

  orb_exec "
    if [ -f /tmp/sandbox-agent-${container}.pid ]; then
      kill \$(cat /tmp/sandbox-agent-${container}.pid) 2>/dev/null || true
      rm -f /tmp/sandbox-agent-${container}.pid
    fi
    rm -f /tmp/sandbox-agent-${container}.sock
  " 2>/dev/null || true
}

# ── Env forwarding ─────────────────────────────────────────────────
inject_env() {
  local container="$1"
  shift
  # Extra --env KEY=VALUE pairs passed as remaining args
  local extra_envs=("$@")

  # Read ~/.sandbox/env if it exists
  local env_lines=()
  if [[ -f "${SANDBOX_ENV_FILE}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      # Skip comments and empty lines
      [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
      env_lines+=("$line")
    done < "${SANDBOX_ENV_FILE}"
  fi

  # Add extra env overrides
  for e in "${extra_envs[@]}"; do
    env_lines+=("$e")
  done

  # Inject into container's /root/.bashrc
  if [[ ${#env_lines[@]} -gt 0 ]]; then
    local export_block=""
    for line in "${env_lines[@]}"; do
      # Ensure each line is an export statement
      if [[ "$line" != export\ * ]]; then
        export_block+="export ${line}\n"
      else
        export_block+="${line}\n"
      fi
    done
    orb_exec "
      incus exec ${container} -- bash -c 'echo -e \"${export_block}\" >> /root/.bashrc'
    "
  fi
}

# ── Container metadata helpers ─────────────────────────────────────
# Store metadata in Incus config user.* keys for later retrieval
set_metadata() {
  local container="$1" key="$2" value="$3"
  orb_exec "incus config set ${container} user.sandbox.${key}='${value}'"
}

get_metadata() {
  local container="$1" key="$2"
  orb_exec "incus config get ${container} user.sandbox.${key} 2>/dev/null" || true
}

# ── Source this library ─────────────────────────────────────────────
# Usage in bin/* scripts:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "${SCRIPT_DIR}/../lib/sandbox-common.sh"
```

**Step 2: Verify syntax**

```bash
bash -n lib/sandbox-common.sh
```

Expected: no output (syntax OK).

**Step 3: Commit**

```bash
git add lib/sandbox-common.sh
git rm lib/.gitkeep 2>/dev/null || true
git commit -m "feat: add shared library with slot mgmt, deploy keys, ssh-agent, env forwarding"
```

---

## Task 3: Stack Definitions — stacks/base.sh

**Files:**
- Create: `stacks/base.sh`

**Step 1: Create the base stack**

The base stack installs the core tooling. This runs inside an Incus container via `incus exec`. The script receives one argument: the golden container name.

Create `stacks/base.sh`:

```bash
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
```

**Step 2: Verify syntax**

```bash
bash -n stacks/base.sh
```

**Step 3: Commit**

```bash
git add stacks/base.sh
git commit -m "feat: add base stack (Docker, Node 22, Claude Code, Python 3, dev tools)"
```

---

## Task 4: Stack Definitions — Variant Stacks

**Files:**
- Create: `stacks/rust.sh`
- Create: `stacks/python.sh`
- Create: `stacks/node.sh`
- Create: `stacks/go.sh`
- Create: `stacks/dotnet.sh`

Each variant script runs inside a container that already has the base stack installed.

**Step 1: Create stacks/rust.sh**

```bash
#!/usr/bin/env bash
# stacks/rust.sh — Rust toolchain + quality/coverage tools
# Runs INSIDE container after base.sh
set -e
export DEBIAN_FRONTEND=noninteractive

echo "Installing Rust stack..."

# Rust toolchain (stable) — installs rustc, cargo, clippy, rustfmt
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Coverage
cargo install cargo-tarpaulin

# Security auditing
cargo install cargo-audit

echo "Rust stack complete"
```

**Step 2: Create stacks/python.sh**

```bash
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
```

**Step 3: Create stacks/node.sh**

```bash
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
```

**Step 4: Create stacks/go.sh**

```bash
#!/usr/bin/env bash
# stacks/go.sh — Go toolchain + quality/coverage tools
# Runs INSIDE container after base.sh
set -e
export DEBIAN_FRONTEND=noninteractive

echo "Installing Go stack..."

# Go toolchain (latest stable)
GO_VERSION=$(curl -sL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version')
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" \
  | tar -C /usr/local -xzf -
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> /root/.bashrc
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

# golangci-lint (meta-linter)
curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sh -s -- -b /usr/local/bin

# govulncheck (security)
go install golang.org/x/vuln/cmd/govulncheck@latest

# Coverage: built-in via `go tool cover`, no install needed

echo "Go stack complete"
```

**Step 5: Create stacks/dotnet.sh**

```bash
#!/usr/bin/env bash
# stacks/dotnet.sh — .NET SDK + quality/coverage tools
# Runs INSIDE container after base.sh
set -e
export DEBIAN_FRONTEND=noninteractive

echo "Installing .NET stack..."

# .NET SDK (latest LTS) via Microsoft package repo
curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
rm /tmp/packages-microsoft-prod.deb
apt-get update
apt-get install -y dotnet-sdk-8.0

# Coverage tool
dotnet tool install --global dotnet-coverage

# SonarScanner for quality analysis
dotnet tool install --global dotnet-sonarscanner

# Add dotnet tools to PATH
echo 'export PATH=$PATH:$HOME/.dotnet/tools' >> /root/.bashrc

# Formatting: built-in via `dotnet format`, no install needed
# Security analyzers: installed per-project via NuGet

echo ".NET stack complete"
```

**Step 6: Verify all syntax**

```bash
for f in stacks/*.sh; do bash -n "$f" && echo "OK: $f"; done
```

Expected: all OK.

**Step 7: Commit**

```bash
git add stacks/rust.sh stacks/python.sh stacks/node.sh stacks/go.sh stacks/dotnet.sh
git rm stacks/.gitkeep 2>/dev/null || true
git commit -m "feat: add variant stacks (rust, python, node, go, dotnet) with quality tools"
```

---

## Task 5: sandbox-setup

**Files:**
- Create: `bin/sandbox-setup`

**Step 1: Create bin/sandbox-setup**

```bash
#!/usr/bin/env bash
# sandbox-setup — One-time setup: OrbStack machine + Incus + egress rules + golden images
# Usage: sandbox-setup [--rebuild <stack>]
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/sandbox-common.sh"

STACKS_DIR="${SCRIPT_DIR}/../stacks"
REBUILD_STACK=""

# ── Parse args ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD_STACK="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ── Step 1: Prerequisites ──────────────────────────────────────────
info "Checking prerequisites..."
require_command orb
require_command gh
require_command ssh-keygen
gh auth status &>/dev/null 2>&1 || warn "gh not authenticated — deploy key automation won't work until you run 'gh auth login'"
ok "Prerequisites OK"

# ── Step 2: OrbStack machine ───────────────────────────────────────
echo ""
info "Step 1: OrbStack machine '${SANDBOX_MACHINE}'..."
if orb list 2>/dev/null | grep -q "${SANDBOX_MACHINE}"; then
  ok "Machine already exists, skipping"
else
  orb create ubuntu:noble "${SANDBOX_MACHINE}"
  ok "Machine created"
fi

# ── Step 3: Install Incus ──────────────────────────────────────────
echo ""
info "Step 2: Installing Incus..."
orb run -m "${SANDBOX_MACHINE}" bash << 'INCUS_SETUP'
set -e

if command -v incus &>/dev/null; then
  echo "Incus already installed: $(incus version)"
  exit 0
fi

curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg
cat > /etc/apt/sources.list.d/zabbly-incus.list << EOF
deb [signed-by=/etc/apt/keyrings/zabbly.gpg] https://pkgs.zabbly.com/incus/stable $(. /etc/os-release && echo $VERSION_CODENAME) main
EOF

apt-get update
apt-get install -y incus btrfs-progs

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

echo "Incus initialized: $(incus version)"
INCUS_SETUP
ok "Incus ready"

# ── Step 4: Egress filtering ───────────────────────────────────────
echo ""
info "Step 3: Applying egress filtering rules..."
orb run -m "${SANDBOX_MACHINE}" bash << 'EGRESS'
set -e

# Check if rules already exist (idempotent)
if iptables -L FORWARD -n 2>/dev/null | grep -q "incusbr0.*DROP"; then
  echo "Egress rules already applied"
  exit 0
fi

# Default deny outbound from containers
iptables -I FORWARD -i incusbr0 -o eth0 -j DROP

# Allow DNS (TCP + UDP)
iptables -I FORWARD -i incusbr0 -o eth0 -p udp --dport 53 -j ACCEPT
iptables -I FORWARD -i incusbr0 -o eth0 -p tcp --dport 53 -j ACCEPT

# Allow HTTP
iptables -I FORWARD -i incusbr0 -o eth0 -p tcp --dport 80 -j ACCEPT

# Allow HTTPS (TCP + UDP for HTTP/3 QUIC)
iptables -I FORWARD -i incusbr0 -o eth0 -p tcp --dport 443 -j ACCEPT
iptables -I FORWARD -i incusbr0 -o eth0 -p udp --dport 443 -j ACCEPT

# Allow SSH (git over SSH)
iptables -I FORWARD -i incusbr0 -o eth0 -p tcp --dport 22 -j ACCEPT

# Allow established/related return traffic
iptables -I FORWARD -i eth0 -o incusbr0 -m state --state ESTABLISHED,RELATED -j ACCEPT

echo "Egress rules applied"
EGRESS
ok "Egress filtering active"

# ── Step 5: Build golden images ────────────────────────────────────
echo ""
info "Step 4: Building golden images..."

build_golden() {
  local stack="$1"
  local golden_name="golden-${stack}"
  local stack_script="${STACKS_DIR}/${stack}.sh"

  if [[ ! -f "$stack_script" ]]; then
    die "Stack script not found: ${stack_script}"
  fi

  # Check if already built (unless --rebuild)
  if [[ "$REBUILD_STACK" != "$stack" && "$REBUILD_STACK" != "all" ]]; then
    if orb_exec "incus snapshot list ${golden_name} -f csv 2>/dev/null | grep -q ready" 2>/dev/null; then
      ok "${golden_name}/ready already exists, skipping"
      return 0
    fi
  fi

  # Clean up existing if rebuilding
  orb_exec "incus delete ${golden_name} --force 2>/dev/null || true"

  if [[ "$stack" == "base" ]]; then
    # Base image: launch fresh Ubuntu
    info "Building ${golden_name} (this takes several minutes)..."
    orb_exec "
      incus launch images:ubuntu/24.04 ${golden_name} \
        -c security.nesting=true \
        -c security.syscalls.intercept.mknod=true \
        -c security.syscalls.intercept.setxattr=true
    "
    orb_exec "sleep 5 && incus exec ${golden_name} -- cloud-init status --wait 2>/dev/null || true"
  else
    # Variant: clone from base
    info "Building ${golden_name} from golden-base..."
    orb_exec "incus copy golden-base/ready ${golden_name}"
    orb_exec "incus start ${golden_name}"
    orb_exec "sleep 3"
  fi

  # Run the stack script inside the container
  info "Running ${stack}.sh inside ${golden_name}..."
  orb run -m "${SANDBOX_MACHINE}" bash -c "
    cat /dev/stdin | incus exec ${golden_name} -- bash
  " < "$stack_script"

  # Stop and snapshot
  orb_exec "incus stop ${golden_name}"
  orb_exec "incus snapshot create ${golden_name} ready"
  ok "${golden_name}/ready created"
}

# Always build base first
build_golden "base"

# Build variant stacks
for stack_file in "${STACKS_DIR}"/*.sh; do
  stack_name="$(basename "$stack_file" .sh)"
  [[ "$stack_name" == "base" ]] && continue
  build_golden "$stack_name"
done

echo ""
ok "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Ensure scripts are in PATH: run ./install.sh"
echo "  2. Create your first sandbox:"
echo "     sandbox-create my-project git@github.com:you/repo.git --stack base"
```

**Step 2: Make executable and verify syntax**

```bash
chmod +x bin/sandbox-setup
bash -n bin/sandbox-setup
```

**Step 3: Commit**

```bash
git add bin/sandbox-setup
git rm bin/.gitkeep 2>/dev/null || true
git commit -m "feat: add sandbox-setup (OrbStack + Incus + egress + golden image builder)"
```

---

## Task 6: sandbox-create

**Files:**
- Create: `bin/sandbox-create`

**Step 1: Create bin/sandbox-create**

```bash
#!/usr/bin/env bash
# sandbox-create <name> [repo-url] [flags]
# Create a new agent container from a golden image
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/sandbox-common.sh"

# ── Parse args ──────────────────────────────────────────────────────
NAME=""
REPO=""
STACK="base"
BRANCH=""
FROM=""
SSH_KEY=""
SLOT=""
CPU=""
MEMORY=""
EXTRA_ENVS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack)   STACK="$2"; shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    --from)    FROM="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --slot)    SLOT="$2"; shift 2 ;;
    --cpu)     CPU="$2"; shift 2 ;;
    --memory)  MEMORY="$2"; shift 2 ;;
    --env)     EXTRA_ENVS+=("$2"); shift 2 ;;
    --*)       die "Unknown flag: $1" ;;
    *)
      if [[ -z "$NAME" ]]; then
        NAME="$1"
      elif [[ -z "$REPO" ]]; then
        REPO="$1"
      else
        die "Unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "$NAME" ]] || die "Usage: sandbox-create <name> [repo-url] [flags]"

# ── Resolve --from ──────────────────────────────────────────────────
if [[ -n "$FROM" ]]; then
  FROM_CONTAINER=$(container_name "$FROM")
  require_machine

  if [[ -z "$REPO" ]]; then
    REPO=$(orb_exec "incus exec ${FROM_CONTAINER} -- git -C ${WORKSPACE_DIR} remote get-url origin 2>/dev/null" || true)
    [[ -n "$REPO" ]] || die "Could not determine repo URL from container '${FROM_CONTAINER}'"
    info "Inherited repo: ${REPO}"
  fi

  if [[ "$STACK" == "base" ]]; then
    FROM_STACK=$(get_metadata "$FROM_CONTAINER" "stack")
    if [[ -n "$FROM_STACK" ]]; then
      STACK="$FROM_STACK"
      info "Inherited stack: ${STACK}"
    fi
  fi

  if [[ -z "$SSH_KEY" ]]; then
    FROM_KEY="${SANDBOX_KEY_DIR}/deploy_${FROM}"
    if [[ -f "$FROM_KEY" ]]; then
      # Don't reuse the key — generate a new one for this container
      info "Will generate new deploy key (not reusing from '${FROM}')"
    fi
  fi
fi

# ── Validate ────────────────────────────────────────────────────────
require_machine
require_golden "$STACK"

CONTAINER=$(container_name "$NAME")

# Check container doesn't already exist
if orb_exec "incus info ${CONTAINER} &>/dev/null" 2>/dev/null; then
  die "Container '${CONTAINER}' already exists. Use 'sandbox-stop ${NAME} --rm' to remove it first."
fi

# ── Auto-assign or validate slot ────────────────────────────────────
if [[ -z "$SLOT" ]]; then
  SLOT=$(next_free_slot)
  info "Auto-assigned slot: ${SLOT}"
else
  validate_slot "$SLOT"
fi

SSH_P=$(ssh_port "$SLOT")
APP_P=$(app_port "$SLOT")
ALT_P=$(alt_port "$SLOT")

# ── Deploy key (auto-generate if repo provided and no --ssh-key) ───
KEY_PATH=""
if [[ -n "$REPO" && -z "$SSH_KEY" ]]; then
  require_gh
  deploy_key_create "$NAME" "$REPO"
  KEY_PATH="${SANDBOX_KEY_DIR}/deploy_${NAME}"
elif [[ -n "$SSH_KEY" ]]; then
  [[ -f "$SSH_KEY" ]] || die "SSH key not found: ${SSH_KEY}"
  KEY_PATH="$SSH_KEY"
fi

# ── Create container ────────────────────────────────────────────────
info "Creating '${CONTAINER}' from golden-${STACK}/ready (slot ${SLOT})..."

orb_exec "
  incus copy golden-${STACK}/ready ${CONTAINER}
"

# Resource limits (only if explicitly set)
if [[ -n "$CPU" ]]; then
  orb_exec "incus config set ${CONTAINER} limits.cpu=${CPU}"
fi
if [[ -n "$MEMORY" ]]; then
  orb_exec "incus config set ${CONTAINER} limits.memory=${MEMORY}"
fi

# Proxy devices for port forwarding
orb_exec "
  incus config device add ${CONTAINER} ssh-proxy proxy \
    listen=tcp:0.0.0.0:${SSH_P} connect=tcp:127.0.0.1:22

  incus config device add ${CONTAINER} app-proxy proxy \
    listen=tcp:0.0.0.0:${APP_P} connect=tcp:127.0.0.1:8080

  incus config device add ${CONTAINER} alt-proxy proxy \
    listen=tcp:0.0.0.0:${ALT_P} connect=tcp:127.0.0.1:9090
"

# Start
orb_exec "incus start ${CONTAINER}"
orb_exec "sleep 3"

# ── SSH agent ───────────────────────────────────────────────────────
if [[ -n "$KEY_PATH" ]]; then
  info "Setting up SSH agent..."
  ssh_agent_setup "$CONTAINER" "$KEY_PATH"
fi

# ── Env vars ────────────────────────────────────────────────────────
inject_env "$CONTAINER" "${EXTRA_ENVS[@]}"

# ── Store metadata ──────────────────────────────────────────────────
set_metadata "$CONTAINER" "slot" "$SLOT"
set_metadata "$CONTAINER" "stack" "$STACK"
[[ -n "$REPO" ]] && set_metadata "$CONTAINER" "repo" "$REPO"

# ── Clone repo ──────────────────────────────────────────────────────
if [[ -n "$REPO" ]]; then
  info "Cloning repository..."
  CLONE_CMD="git clone"
  [[ -n "$BRANCH" ]] && CLONE_CMD+=" --branch ${BRANCH}"
  CLONE_CMD+=" '${REPO}' ${WORKSPACE_DIR}"

  orb_exec "incus exec ${CONTAINER} -- bash -c '${CLONE_CMD}'" \
    || die "Git clone failed. Check SSH key and repo access."
  ok "Repository cloned"
fi

# ── Done ────────────────────────────────────────────────────────────
echo ""
ok "=== '${CONTAINER}' ready ==="
echo ""
echo "  Slot:      ${SLOT}"
echo "  Stack:     ${STACK}"
echo "  SSH:       ssh -o StrictHostKeyChecking=no -p ${SSH_P} root@localhost"
echo "  VS Code:   code --remote ssh-remote+root@localhost:${SSH_P} ${WORKSPACE_DIR}"
echo "  App:       http://localhost:${APP_P}"
echo "  Alt:       http://localhost:${ALT_P}"
echo ""
echo "  Shell:     sandbox ${NAME}"
echo "  Claude:    sandbox ${NAME} --claude"
[[ -z "$(get_metadata "$CONTAINER" "repo")" ]] || echo "  Login:     sandbox-login ${NAME}"
```

**Step 2: Make executable and verify syntax**

```bash
chmod +x bin/sandbox-create
bash -n bin/sandbox-create
```

**Step 3: Commit**

```bash
git add bin/sandbox-create
git commit -m "feat: add sandbox-create (auto-slot, deploy keys, ssh-agent, env forwarding)"
```

---

## Task 7: sandbox-stop

**Files:**
- Create: `bin/sandbox-stop`

**Step 1: Create bin/sandbox-stop**

```bash
#!/usr/bin/env bash
# sandbox-stop <name> [--rm]
# Stop a container. Pass --rm to also delete it and clean up deploy keys.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/sandbox-common.sh"

NAME="${1:?Usage: sandbox-stop <name> [--rm]}"
REMOVE="${2:-}"
CONTAINER=$(container_name "$NAME")

require_machine

# Verify container exists
orb_exec "incus info ${CONTAINER} &>/dev/null" 2>/dev/null \
  || die "Container '${CONTAINER}' not found"

# Clean up SSH agent
info "Cleaning up SSH agent..."
ssh_agent_cleanup "$CONTAINER"

# Clean up per-container egress rules
info "Cleaning up egress rules..."
CONTAINER_IP=$(orb_exec "
  incus list ${CONTAINER} -f csv -c 4 2>/dev/null | grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
" || true)
if [[ -n "$CONTAINER_IP" ]]; then
  orb_exec "
    iptables -S FORWARD 2>/dev/null | grep '${CONTAINER_IP}' | while read -r rule; do
      iptables \$(echo \"\$rule\" | sed 's/^-A/-D/')
    done
  " 2>/dev/null || true
fi

# Stop
orb_exec "incus stop '${CONTAINER}' --force 2>/dev/null || true"
ok "Stopped ${CONTAINER}"

# Remove if --rm
if [[ "$REMOVE" == "--rm" ]]; then
  # Clean up deploy key from GitHub
  REPO=$(get_metadata "$CONTAINER" "repo")
  if [[ -n "$REPO" ]]; then
    deploy_key_cleanup "$NAME" "$REPO"
  fi

  orb_exec "incus delete '${CONTAINER}'"
  ok "Deleted ${CONTAINER}"
fi
```

**Step 2: Make executable and verify syntax**

```bash
chmod +x bin/sandbox-stop
bash -n bin/sandbox-stop
```

**Step 3: Commit**

```bash
git add bin/sandbox-stop
git commit -m "feat: add sandbox-stop (with deploy key + ssh-agent cleanup)"
```

---

## Task 8: sandbox-nuke

**Files:**
- Create: `bin/sandbox-nuke`

**Step 1: Create bin/sandbox-nuke**

```bash
#!/usr/bin/env bash
# sandbox-nuke [--all]
# Destroy ALL agent containers. Pass --all to also remove golden images.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/sandbox-common.sh"

FLAG="${1:-}"

require_machine

echo "This will destroy ALL agent containers and their deploy keys."
read -p "Are you sure? (yes/no): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted"; exit 0; }

# Get list of containers before destroying them
CONTAINERS=$(orb_exec "incus list -f csv -c n 2>/dev/null | grep '^agent-'" || true)

for container in $CONTAINERS; do
  name="${container#agent-}"

  # Clean up SSH agent
  ssh_agent_cleanup "$container"

  # Clean up deploy key
  repo=$(get_metadata "$container" "repo")
  if [[ -n "$repo" ]]; then
    deploy_key_cleanup "$name" "$repo"
  fi

  # Clean up egress rules
  container_ip=$(orb_exec "
    incus list ${container} -f csv -c 4 2>/dev/null | grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
  " || true)
  if [[ -n "$container_ip" ]]; then
    orb_exec "
      iptables -S FORWARD 2>/dev/null | grep '${container_ip}' | while read -r rule; do
        iptables \$(echo \"\$rule\" | sed 's/^-A/-D/')
      done
    " 2>/dev/null || true
  fi

  info "Destroying ${container}..."
  orb_exec "incus delete '${container}' --force"
done

if [[ "$FLAG" == "--all" ]]; then
  info "Destroying golden images..."
  orb_exec "
    for g in \$(incus list -f csv -c n 2>/dev/null | grep '^golden-'); do
      echo \"Destroying \$g...\"
      incus delete \"\$g\" --force
    done
  "
  ok "Everything destroyed. Run 'sandbox-setup' to rebuild."
else
  ok "All agent containers destroyed. Golden images preserved."
fi

# Clean up any remaining local keys
if [[ -d "${SANDBOX_KEY_DIR}" ]]; then
  rm -rf "${SANDBOX_KEY_DIR}"
  info "Cleaned up local deploy keys"
fi
```

**Step 2: Make executable and verify syntax**

```bash
chmod +x bin/sandbox-nuke
bash -n bin/sandbox-nuke
```

**Step 3: Commit**

```bash
git add bin/sandbox-nuke
git commit -m "feat: add sandbox-nuke (destroy all containers + cleanup deploy keys)"
```

---

## Task 9: sandbox (consolidated session command)

**Files:**
- Create: `bin/sandbox`

**Step 1: Create bin/sandbox**

```bash
#!/usr/bin/env bash
# sandbox <name> [name2...] [flags]
# Session entry point: shell, Claude, or command. Auto-tmux for multiple containers.
#
# Examples:
#   sandbox proj-alpha                        # shell into one
#   sandbox proj-alpha proj-beta              # tmux with shells
#   sandbox proj-alpha --claude               # run claude
#   sandbox proj-alpha proj-beta --claude     # tmux with claude
#   sandbox proj-alpha --cmd "git status"     # run command
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/sandbox-common.sh"

# ── Parse args ──────────────────────────────────────────────────────
NAMES=()
MODE="shell"   # shell | claude | cmd
CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude) MODE="claude"; shift ;;
    --cmd)    MODE="cmd"; CMD="$2"; shift 2 ;;
    --*)      die "Unknown flag: $1" ;;
    *)        NAMES+=("$1"); shift ;;
  esac
done

[[ ${#NAMES[@]} -gt 0 ]] || die "Usage: sandbox <name> [name2...] [--claude] [--cmd \"command\"]"

require_machine

# ── Build the command to run in each container ──────────────────────
build_session_cmd() {
  local name="$1"
  local container
  container=$(container_name "$name")

  case "$MODE" in
    shell)
      echo "orb run -m ${SANDBOX_MACHINE} incus exec ${container} -- bash"
      ;;
    claude)
      echo "orb run -m ${SANDBOX_MACHINE} incus exec ${container} -- bash -c 'cd ${WORKSPACE_DIR} 2>/dev/null; claude --dangerously-skip-permissions'"
      ;;
    cmd)
      echo "orb run -m ${SANDBOX_MACHINE} incus exec ${container} -- bash -c '${CMD}'"
      ;;
  esac
}

# ── Validate all containers exist and are running ───────────────────
for name in "${NAMES[@]}"; do
  container=$(container_name "$name")
  state=$(orb_exec "incus info ${container} 2>/dev/null | grep 'Status:' | awk '{print \$2}'" || true)
  if [[ -z "$state" ]]; then
    die "Container '${container}' not found"
  fi
  if [[ "$state" != "RUNNING" ]]; then
    die "Container '${container}' is ${state}, not running. Start it first."
  fi
done

# ── Single container: direct session ────────────────────────────────
if [[ ${#NAMES[@]} -eq 1 ]]; then
  exec $(build_session_cmd "${NAMES[0]}")
fi

# ── Multiple containers: tmux ───────────────────────────────────────
require_command tmux

SESSION="sandbox-agents"
tmux kill-session -t "$SESSION" 2>/dev/null || true

# First pane
FIRST_CMD=$(build_session_cmd "${NAMES[0]}")
tmux new-session -d -s "$SESSION" -n "agents" "$FIRST_CMD"

# Remaining panes
for ((i=1; i<${#NAMES[@]}; i++)); do
  PANE_CMD=$(build_session_cmd "${NAMES[$i]}")
  tmux split-window -t "$SESSION" "$PANE_CMD"
  tmux select-layout -t "$SESSION" tiled
done

tmux attach-session -t "$SESSION"
```

**Step 2: Make executable and verify syntax**

```bash
chmod +x bin/sandbox
bash -n bin/sandbox
```

**Step 3: Commit**

```bash
git add bin/sandbox
git commit -m "feat: add sandbox command (shell/claude/cmd, auto-tmux for multiple containers)"
```

---

## Task 10: sandbox-list

**Files:**
- Create: `bin/sandbox-list`

**Step 1: Create bin/sandbox-list**

```bash
#!/usr/bin/env bash
# sandbox-list — List all agent containers with health status
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/sandbox-common.sh"

require_machine

orb run -m "${SANDBOX_MACHINE}" bash << 'INNERLIST'
#!/usr/bin/env bash

CONTAINERS=$(incus list -f csv -c n 2>/dev/null | grep "^agent-" || true)

if [ -z "$CONTAINERS" ]; then
  echo "No agent containers found"
  exit 0
fi

# Header
printf "\n%-25s %-9s %-5s %-6s %-6s %-6s %-14s %-8s %-8s %-8s %s\n" \
  "CONTAINER" "STATE" "SLOT" "SSH" "APP" "ALT" "EXTRA" "DOCKER" "AGENT" "CLAUDE" "REPO"
printf "%-25s %-9s %-5s %-6s %-6s %-6s %-14s %-8s %-8s %-8s %s\n" \
  "─────────" "─────" "────" "───" "───" "───" "─────" "──────" "─────" "──────" "────"

for c in $CONTAINERS; do
  state=$(incus info "$c" 2>/dev/null | grep "Status:" | awk '{print $2}')

  # Ports
  ssh_p=$(incus config device get "$c" ssh-proxy listen 2>/dev/null | grep -o '[0-9]*$' || echo "-")
  app_p=$(incus config device get "$c" app-proxy listen 2>/dev/null | grep -o '[0-9]*$' || echo "-")
  alt_p=$(incus config device get "$c" alt-proxy listen 2>/dev/null | grep -o '[0-9]*$' || echo "-")

  # Slot (from SSH port)
  if [ "$ssh_p" != "-" ]; then
    slot=$(( ssh_p - 2200 ))
  else
    slot="-"
  fi

  # Extra ports
  extras=""
  for dev in $(incus config device list "$c" 2>/dev/null | grep "^port-" || true); do
    port=$(incus config device get "$c" "$dev" listen 2>/dev/null | grep -o '[0-9]*$' || true)
    if [ -n "$port" ]; then
      [ -n "$extras" ] && extras="${extras},"
      extras="${extras}${port}"
    fi
  done
  [ -z "$extras" ] && extras="-"

  # Health checks (only for running containers)
  docker_status="-"
  agent_status="-"
  claude_status="-"
  repo_info="-"

  if [ "$state" = "RUNNING" ]; then
    # Docker
    if incus exec "$c" -- docker info &>/dev/null; then
      docker_status="ok"
    else
      docker_status="err"
    fi

    # SSH agent
    agent_out=$(incus exec "$c" -- bash -c 'SSH_AUTH_SOCK=/run/ssh-agent.sock ssh-add -l 2>&1' || true)
    if echo "$agent_out" | grep -q "no identities"; then
      agent_status="no-key"
    elif echo "$agent_out" | grep -q "Could not open\|Error\|refused"; then
      agent_status="none"
    elif echo "$agent_out" | grep -qE "^[0-9]"; then
      agent_status="ok"
    else
      agent_status="none"
    fi

    # Claude auth
    if incus exec "$c" -- test -d /root/.claude 2>/dev/null && \
       incus exec "$c" -- bash -c 'ls /root/.claude/.credentials* 2>/dev/null || ls /root/.claude/auth* 2>/dev/null' &>/dev/null; then
      claude_status="auth'd"
    else
      claude_status="no-auth"
    fi

    # Repo info
    if incus exec "$c" -- test -d /workspace/project/.git 2>/dev/null; then
      remote=$(incus exec "$c" -- git -C /workspace/project remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##' || echo "?")
      branch=$(incus exec "$c" -- git -C /workspace/project branch --show-current 2>/dev/null || echo "?")
      repo_info="${remote} (${branch})"
    fi
  fi

  printf "%-25s %-9s %-5s %-6s %-6s %-6s %-14s %-8s %-8s %-8s %s\n" \
    "$c" "$state" "$slot" "$ssh_p" "$app_p" "$alt_p" "$extras" \
    "$docker_status" "$agent_status" "$claude_status" "$repo_info"
done
echo ""
INNERLIST
```

**Step 2: Make executable and verify syntax**

```bash
chmod +x bin/sandbox-list
bash -n bin/sandbox-list
```

**Step 3: Commit**

```bash
git add bin/sandbox-list
git commit -m "feat: add sandbox-list (containers with health, ports, repo status)"
```

---

## Task 11: sandbox-expose

**Files:**
- Create: `bin/sandbox-expose`

**Step 1: Create bin/sandbox-expose**

```bash
#!/usr/bin/env bash
# sandbox-expose <name> <port> [protocol]
# Expose a port bidirectionally: macOS→container (inbound) + container→external (outbound)
#
# Protocol: tcp (default), udp, both
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/sandbox-common.sh"

NAME="${1:?Usage: sandbox-expose <name> <port> [protocol]}"
PORT="${2:?Port number required}"
PROTO="${3:-tcp}"

CONTAINER=$(container_name "$NAME")

require_machine

# Validate port is a number
[[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be a number, got: $PORT"

# Validate protocol
case "$PROTO" in
  tcp|udp|both) ;;
  *) die "Protocol must be tcp, udp, or both — got: $PROTO" ;;
esac

# Verify container exists
orb_exec "incus info ${CONTAINER} &>/dev/null" 2>/dev/null \
  || die "Container '${CONTAINER}' not found"

# Get container IP for egress rules
CONTAINER_IP=$(orb_exec "
  incus list ${CONTAINER} -f csv -c 4 2>/dev/null | grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
")
[[ -n "$CONTAINER_IP" ]] || die "Could not determine container IP"

add_port() {
  local p="$1"
  local device_name="port-${PORT}-${p}"

  # Inbound: macOS → container
  orb_exec "
    incus config device add '${CONTAINER}' '${device_name}' proxy \
      'listen=${p}:0.0.0.0:${PORT}' \
      'connect=${p}:127.0.0.1:${PORT}'
  "

  # Outbound: container → external
  orb_exec "
    iptables -I FORWARD -s ${CONTAINER_IP} -o eth0 -p ${p} --dport ${PORT} -j ACCEPT
  "
}

case "$PROTO" in
  tcp)  add_port tcp ;;
  udp)  add_port udp ;;
  both) add_port tcp; add_port udp ;;
esac

ok "Exposed ${CONTAINER}:${PORT} bidirectionally (${PROTO})"
```

**Step 2: Make executable and verify syntax**

```bash
chmod +x bin/sandbox-expose
bash -n bin/sandbox-expose
```

**Step 3: Commit**

```bash
git add bin/sandbox-expose
git commit -m "feat: add sandbox-expose (bidirectional port mapping + egress rules)"
```

---

## Task 12: sandbox-login

**Files:**
- Create: `bin/sandbox-login`

**Step 1: Create bin/sandbox-login**

```bash
#!/usr/bin/env bash
# sandbox-login <name>
# Authenticate Claude Code via OAuth inside a container
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/sandbox-common.sh"

NAME="${1:?Usage: sandbox-login <name>}"
CONTAINER=$(container_name "$NAME")

require_machine

# Verify container is running
STATE=$(orb_exec "incus info ${CONTAINER} 2>/dev/null | grep 'Status:' | awk '{print \$2}'" || true)
[[ "$STATE" == "RUNNING" ]] || die "Container '${CONTAINER}' is not running (state: ${STATE:-not found})"

info "Starting Claude login flow for '${CONTAINER}'..."
echo ""
echo "This will open a browser-based OAuth flow."
echo "Complete the authentication in your browser when prompted."
echo ""

# Run claude login interactively inside the container
# The OAuth callback typically uses localhost which OrbStack auto-forwards
orb run -m "${SANDBOX_MACHINE}" incus exec "${CONTAINER}" -- bash -c \
  "claude login"

# Verify success
if orb_exec "incus exec ${CONTAINER} -- bash -c 'ls /root/.claude/.credentials* 2>/dev/null || ls /root/.claude/auth* 2>/dev/null'" &>/dev/null; then
  ok "Claude authenticated successfully in '${CONTAINER}'"
else
  warn "Authentication may not have completed. Check with: sandbox ${NAME} --cmd 'claude --version'"
fi
```

**Step 2: Make executable and verify syntax**

```bash
chmod +x bin/sandbox-login
bash -n bin/sandbox-login
```

**Step 3: Commit**

```bash
git add bin/sandbox-login
git commit -m "feat: add sandbox-login (Claude OAuth flow for containers)"
```

---

## Task 13: install.sh

**Files:**
- Create: `install.sh` (at project root, replacing the one in docs/)

**Step 1: Create install.sh**

```bash
#!/usr/bin/env bash
# install.sh — Symlink all bin/sandbox* scripts into a directory in your PATH
set -euo pipefail

DEST="${1:-${HOME}/.local/bin}"
mkdir -p "$DEST"

SCRIPT_DIR="$(cd "$(dirname "$0")/bin" && pwd)"

echo "Installing sandbox commands to ${DEST}..."
echo ""

for script in "${SCRIPT_DIR}"/sandbox*; do
  name="$(basename "$script")"
  chmod +x "$script"
  ln -sf "$script" "${DEST}/${name}"
  echo "  ${name} → ${DEST}/${name}"
done

echo ""

# Check if DEST is in PATH
if [[ ":$PATH:" != *":${DEST}:"* ]]; then
  echo "WARNING: ${DEST} is not in your PATH."
  echo "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
  echo ""
  echo "  export PATH=\"\$PATH:${DEST}\""
  echo ""
fi

echo "Done. Run 'sandbox-setup' to initialise the infrastructure."
```

**Step 2: Make executable**

```bash
chmod +x install.sh
```

**Step 3: Commit**

```bash
git add install.sh
git commit -m "feat: add install.sh (symlinks bin/ commands into PATH)"
```

---

## Task 14: README.md

**Files:**
- Create: `README.md` (at project root)

**Step 1: Create README.md**

Write the README covering: overview, prerequisites, quickstart, command reference, GitHub deploy keys guide, stack customisation, port allocation, security model, troubleshooting.

Key sections:

```markdown
# Sandbox Claude Code

Run Claude Code agents in isolated containers with full YOLO mode (`--dangerously-skip-permissions`)
while keeping your macOS completely safe.

## Architecture

macOS → OrbStack VM "sandbox" → Incus containers (one per project)

Each container gets:
- Its own filesystem, Docker daemon, and workspace
- A dedicated SSH deploy key (auto-generated, scoped to one repo)
- Bidirectional port forwarding to macOS
- Egress filtering (only DNS, HTTP/S, SSH by default)

## Prerequisites

- macOS with OrbStack (`brew install orbstack`)
- GitHub CLI authenticated (`gh auth login`) — for automatic deploy keys
- Admin access on target GitHub repos (to add deploy keys)

## Quickstart

\```bash
# 1. Install
git clone <repo-url> && cd sandbox-claude
./install.sh

# 2. One-time setup (creates VM, installs Incus, builds golden images)
sandbox-setup

# 3. Create a sandbox
sandbox-create my-project git@github.com:me/my-repo.git --stack rust

# 4. Open a shell
sandbox my-project

# 5. Or run Claude directly
sandbox my-project --claude
\```

## Commands

| Command | Purpose |
|---------|---------|
| `sandbox-setup` | One-time infrastructure setup |
| `sandbox-create` | Create a new agent container |
| `sandbox <name>` | Shell into container (or tmux for multiple) |
| `sandbox-list` | List containers with health status |
| `sandbox-expose` | Expose additional ports (bidirectional) |
| `sandbox-login` | Authenticate Claude via OAuth |
| `sandbox-stop` | Stop (and optionally remove) a container |
| `sandbox-nuke` | Destroy all agent containers |

[... full command reference with examples ...]

## GitHub Deploy Keys

Each sandbox automatically gets a dedicated deploy key scoped to its repository.
This happens transparently during `sandbox-create`:

1. An ed25519 key pair is generated locally (`~/.sandbox/keys/deploy_<name>`)
2. The public key is registered on GitHub via `gh repo deploy-key add -w`
3. The private key is loaded into a per-container SSH agent (never touches container disk)
4. When you `sandbox-stop <name> --rm`, the key is removed from GitHub

### Manual setup (if gh automation isn't available)

1. Generate a key: `ssh-keygen -t ed25519 -f ~/.ssh/deploy_myproject -N ""`
2. Add to GitHub: repo → Settings → Deploy keys → Add deploy key (check "Allow write access")
3. Use it: `sandbox-create my-project git@github.com:me/repo.git --ssh-key ~/.ssh/deploy_myproject`

## Stacks

| Stack | Includes | Quality/Coverage Tools |
|-------|----------|----------------------|
| base | Docker, Node 22, Claude Code, Python 3, git | — |
| rust | + Rust toolchain | clippy, rustfmt, cargo-tarpaulin, cargo-audit |
| python | + poetry, uv | ruff, mypy, bandit, coverage |
| node | + pnpm, yarn, bun | c8, eslint, prettier |
| go | + Go toolchain | golangci-lint, govulncheck, go tool cover |
| dotnet | + .NET SDK | dotnet-coverage, dotnet format, dotnet-sonarscanner |

### Adding a custom stack

1. Create `stacks/mystack.sh` (runs inside a container with base already installed)
2. Run `sandbox-setup --rebuild mystack` (or just `sandbox-setup` to build missing ones)

## Security Model

**Protected:**
- macOS filesystem — completely isolated, agents cannot access it
- Each container has its own filesystem, processes, Docker daemon
- SSH keys never touch container disk (held in agent memory only)
- Deploy keys are scoped to one repo (GitHub enforces this)
- Egress filtered: only DNS, HTTP/S, SSH by default

**Not protected by default:**
- Network egress beyond allowed ports (use `sandbox-expose` to open more)
- Container-to-container traffic on incusbr0 (add Incus ACLs if needed)
- OrbStack shared kernel (theoretical kernel exploit, unlikely threat model)

## Troubleshooting

[... Docker nesting, port access, disk space, resource issues ...]
```

This is a summary — the actual README should be fully written with all examples from the design doc.

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with quickstart, command reference, security model"
```

---

## Task 15: Create ~/.sandbox/env example

**Files:**
- Create: `env.example` (in project root, for reference)

**Step 1: Create env.example**

```bash
# ~/.sandbox/env — Environment variables forwarded to all sandbox containers
# Copy this to ~/.sandbox/env and customise
#
# Lines starting with # are ignored
# Format: KEY=VALUE (export prefix is optional)

# Anthropic API key (forwarded automatically if set in your macOS environment)
# ANTHROPIC_API_KEY=sk-ant-...

# Optional: other API keys
# OPENAI_API_KEY=sk-...
# GITHUB_TOKEN=ghp_...
```

**Step 2: Commit**

```bash
git add env.example
git commit -m "docs: add env.example for ~/.sandbox/env reference"
```

---

## Task 16: Verify All Scripts — Syntax & Permissions

**Step 1: Check all scripts parse correctly**

```bash
for f in bin/sandbox*; do
  bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"
done
bash -n lib/sandbox-common.sh && echo "OK: lib/sandbox-common.sh"
for f in stacks/*.sh; do
  bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"
done
bash -n install.sh && echo "OK: install.sh"
```

Expected: all OK.

**Step 2: Check all bin/ scripts are executable**

```bash
ls -la bin/sandbox*
```

All should have `x` permission.

**Step 3: Check all scripts source the common library correctly**

```bash
grep -l "sandbox-common.sh" bin/sandbox*
```

Should list all bin/ scripts except install.sh.

**Step 4: Verify no secrets in repo**

```bash
git grep -i "api_key\|password\|secret\|token" -- ':!*.md' ':!*.example' ':!lib/sandbox-common.sh'
```

Should return nothing (or only references in env handling code, not actual values).

---

## Task 17: Integration Test — sandbox-setup

This is a manual test since it requires OrbStack.

**Step 1: Run install**

```bash
./install.sh
```

Expected: all scripts linked to ~/.local/bin.

**Step 2: Run sandbox-setup**

```bash
sandbox-setup
```

Expected:
- OrbStack machine "sandbox" created (or exists)
- Incus installed and initialised
- Egress rules applied
- All 6 golden images built (base, rust, python, node, go, dotnet)

**Step 3: Verify golden images**

```bash
orb run -m sandbox incus list | grep golden
```

Expected: 6 golden-* containers in Stopped state.

**Step 4: Verify egress rules**

```bash
orb run -m sandbox iptables -L FORWARD -n
```

Expected: DROP default + ACCEPT rules for ports 22, 53, 80, 443.

---

## Task 18: Integration Test — Full Workflow

**Step 1: Create a container**

```bash
sandbox-create test-project git@github.com:<your-test-repo>.git --stack base
```

Expected: container created, deploy key registered, repo cloned.

**Step 2: List containers**

```bash
sandbox-list
```

Expected: shows agent-test-project with health info.

**Step 3: Shell in**

```bash
sandbox test-project
```

Expected: bash shell inside container.

**Step 4: Verify SSH agent**

```bash
# Inside container
ssh-add -l
```

Expected: shows the deploy key.

**Step 5: Expose a port**

```bash
sandbox-expose test-project 5432
```

Expected: port 5432 open bidirectionally.

**Step 6: Clean up**

```bash
sandbox-stop test-project --rm
```

Expected: container deleted, deploy key removed from GitHub, local key deleted.

**Step 7: Nuke**

```bash
sandbox-nuke
```

Expected: all agent containers destroyed (golden images preserved).
