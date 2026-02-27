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
