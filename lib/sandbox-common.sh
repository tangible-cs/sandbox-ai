#!/usr/bin/env bash
# lib/sandbox-common.sh — Shared functions for sandbox-* commands
# Source this file: SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" && source "${SCRIPT_DIR}/../lib/sandbox-common.sh"

set -euo pipefail

# ── Constants ───────────────────────────────────────────────────────
SANDBOX_MACHINE="sandbox"
SANDBOX_KEY_DIR="${HOME}/.sandbox/keys"
SANDBOX_ENV_FILE="${HOME}/.sandbox/env"
SANDBOX_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SANDBOX_AGENTS_DIR="${SANDBOX_ROOT}/agents"
WORKSPACE_DIR="/workspace/project"
SANDBOX_UID=1000
SANDBOX_GID=1000
SANDBOX_USER_HOME="/home/ubuntu"
SANDBOX_DEFAULT_DOMAINS="${SANDBOX_ROOT}/domains/anthropic-default.txt"
SANDBOX_USER_DOMAINS="${HOME}/.sandbox/allowed-domains.txt"
SQUID_PORT=3129

# ── Platform detection ────────────────────────────────────────────
detect_platform() {
  case "$(uname -s)" in
    Darwin) SANDBOX_PLATFORM="macos" ;;
    Linux)  SANDBOX_PLATFORM="linux" ;;
    *)      die "Unsupported platform: $(uname -s)" ;;
  esac
}

detect_outbound_iface() {
  if [[ "$SANDBOX_PLATFORM" == "macos" ]]; then
    # Inside OrbStack VM, the outbound interface is always eth0
    echo "eth0"
  else
    # Detect from default route on Linux host
    ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
  fi
}

detect_platform
OUTBOUND_IFACE=$(detect_outbound_iface)

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

require_vm() {
  if [[ "$SANDBOX_PLATFORM" == "macos" ]]; then
    require_command orb
    orb list &>/dev/null || die "OrbStack is not running. Start it first."
  else
    require_command incus
    incus list &>/dev/null 2>&1 || die "Incus is not running or not accessible. Check 'incus-admin' group membership."
  fi
}

require_sandbox() {
  require_vm
  if [[ "$SANDBOX_PLATFORM" == "macos" ]]; then
    orb list 2>/dev/null | grep -q "${SANDBOX_MACHINE}" \
      || die "Sandbox machine not found. Run 'sandbox-setup' first."
  else
    incus profile show default &>/dev/null 2>&1 \
      || die "Incus not initialized. Run 'sandbox-setup' first."
  fi
}

require_gh() {
  require_command gh
  gh auth status &>/dev/null 2>&1 || die "'gh' is not authenticated. Run 'gh auth login' first."
}

require_golden() {
  local stack="${1:-base}"
  local golden_name="golden-${stack}"
  vm_exec "incus info ${golden_name} &>/dev/null" \
    || die "Golden image '${golden_name}' not found. Run 'sandbox-setup' first."
  vm_exec "incus snapshot list ${golden_name} -f csv 2>/dev/null | grep -q ready" \
    || die "Golden image '${golden_name}' has no 'ready' snapshot. Run 'sandbox-setup' first."
}

require_container() {
  local container="$1"
  vm_exec "incus info ${container} &>/dev/null" 2>/dev/null \
    || die "Container '${container}' not found"
}

# ── Agent CLI registry ─────────────────────────────────────────────
clear_cli_config_vars() {
  local vars=(
    CLI_ID CLI_DISPLAY_NAME CLI_BINARY_NAME CLI_INSTALL_STRATEGY
    CLI_INSTALL_REF CLI_INSTALL_COMMAND CLI_INSTALL_USER
    CLI_UPDATE_COMMAND CLI_UNINSTALL_COMMAND
    CLI_LAUNCH_COMMAND CLI_HEADLESS_COMMAND CLI_VERSION_CHECK_COMMAND
    CLI_POST_INSTALL_VALIDATION_COMMAND CLI_AUTH_STRATEGY CLI_AUTH_COMMAND
    CLI_AUTH_CHECK_COMMAND CLI_CREDENTIAL_PATHS CLI_REQUIRED_ENV_VARS
    CLI_OPTIONAL_ENV_VARS CLI_SUPPORTS_CHATGPT_SUBSCRIPTION_LOGIN
    CLI_SUPPORTS_BROWSER_LOGIN CLI_REQUIRES_NODE CLI_REQUIRES_PYTHON
    CLI_REQUIRES_UV_OR_PIPX CLI_RUNTIME_PREREQS CLI_CACHE_STRATEGY
    CLI_CACHE_KEY CLI_ALLOWLIST_FILE CLI_SESSION_HOME_SUBDIR
    CLI_STATUS_LABEL CLI_PATH_LINK_SOURCE CLI_PATH_LINK_TARGET
    CLI_DEFAULT_FLAGS CLI_NOTES
  )
  local var
  for var in "${vars[@]}"; do
    unset "$var" 2>/dev/null || true
  done
}

cli_config_path() {
  local agent_id="${1:-}"
  [[ -n "$agent_id" ]] || die "Agent id is required"
  local path="${SANDBOX_AGENTS_DIR}/${agent_id}.conf"
  [[ -f "$path" ]] || die "Unknown agent: ${agent_id}"
  echo "$path"
}

list_agent_ids() {
  local path
  for path in "${SANDBOX_AGENTS_DIR}"/*.conf; do
    [[ -e "$path" ]] || continue
    basename "$path" .conf
  done | sort
}

validate_cli_config_file() {
  local config_path="${1:-}"
  [[ -n "$config_path" ]] || die "Config path is required"
  [[ -f "$config_path" ]] || die "Agent config not found: ${config_path}"

  clear_cli_config_vars
  # shellcheck disable=SC1090
  source "$config_path"

  local required_nonempty=(
    CLI_ID CLI_DISPLAY_NAME CLI_BINARY_NAME CLI_INSTALL_STRATEGY
    CLI_INSTALL_REF CLI_INSTALL_COMMAND CLI_INSTALL_USER CLI_LAUNCH_COMMAND
    CLI_VERSION_CHECK_COMMAND CLI_AUTH_STRATEGY CLI_AUTH_COMMAND
    CLI_AUTH_CHECK_COMMAND CLI_REQUIRES_NODE CLI_REQUIRES_PYTHON
    CLI_REQUIRES_UV_OR_PIPX CLI_CACHE_STRATEGY CLI_CACHE_KEY
    CLI_SESSION_HOME_SUBDIR CLI_STATUS_LABEL
  )
  local required_defined=(
    CLI_ALLOWLIST_FILE CLI_RUNTIME_PREREQS CLI_PATH_LINK_SOURCE
    CLI_PATH_LINK_TARGET CLI_DEFAULT_FLAGS
  )
  local field
  for field in "${required_nonempty[@]}"; do
    [[ -n "${!field:-}" ]] || die "Agent config '${config_path}' missing required field: ${field}"
  done
  for field in "${required_defined[@]}"; do
    [[ ${!field+x} ]] || die "Agent config '${config_path}' missing required field: ${field}"
  done

  [[ "$CLI_ID" == "$(basename "$config_path" .conf)" ]] \
    || die "Agent config '${config_path}' has mismatched CLI_ID: ${CLI_ID}"
}

load_cli_config() {
  local agent_id="${1:-}"
  local config_path
  config_path=$(cli_config_path "$agent_id")
  validate_cli_config_file "$config_path" >/dev/null
  clear_cli_config_vars
  # shellcheck disable=SC1090
  source "$config_path"
}

# ── Agent metadata helpers ─────────────────────────────────────────
serialize_agent_ids() {
  local out=()
  local seen=","
  local agent_id
  for agent_id in "$@"; do
    [[ -n "$agent_id" ]] || continue
    if [[ "$seen" != *",${agent_id},"* ]]; then
      out+=("$agent_id")
      seen="${seen}${agent_id},"
    fi
  done

  local IFS=,
  echo "${out[*]-}"
}

parse_agent_ids() {
  local value="${1:-}"
  [[ -n "$value" ]] || return 0
  tr ',' '\n' <<< "$value" | sed '/^$/d'
}

set_installed_agents_metadata() {
  local container="$1"
  shift
  local value
  value=$(serialize_agent_ids "$@")
  set_metadata "$container" "agents" "$value"
}

get_installed_agents_metadata() {
  local container="$1"
  get_metadata "$container" "agents"
}

list_installed_agents_metadata() {
  local container="$1"
  parse_agent_ids "$(get_installed_agents_metadata "$container")"
}

set_default_agent_metadata() {
  local container="$1"
  local agent_id="${2:-}"
  [[ -n "$agent_id" ]] || die "set_default_agent_metadata requires a non-empty agent id"
  set_metadata "$container" "default-agent" "$agent_id"
}

get_default_agent_metadata() {
  local container="$1"
  get_metadata "$container" "default-agent"
}

default_install_agent_ids() {
  echo "codex"
}

resolve_selected_agents() {
  local selected=("$@")
  if [[ ${#selected[@]} -eq 0 ]]; then
    serialize_agent_ids "$(default_install_agent_ids)"
    return 0
  fi

  local agent_id
  for agent_id in "${selected[@]}"; do
    cli_config_path "$agent_id" >/dev/null
  done

  serialize_agent_ids "${selected[@]}"
}

select_default_agent() {
  local requested_default="${1:-}"
  shift || true

  local selected_csv
  selected_csv=$(serialize_agent_ids "$@")
  [[ -n "$selected_csv" ]] || die "select_default_agent requires at least one selected agent"

  if [[ -z "$requested_default" ]]; then
    parse_agent_ids "$selected_csv" | head -1
    return 0
  fi

  cli_config_path "$requested_default" >/dev/null
  if ! parse_agent_ids "$selected_csv" | grep -qx "$requested_default"; then
    die "--default-agent '${requested_default}' must also be included via --agent"
  fi
  echo "$requested_default"
}

runtime_prereqs_for_agents() {
  local prereqs=()
  local agent_id
  local extra_prereq
  for agent_id in "$@"; do
    [[ -n "$agent_id" ]] || continue
    load_cli_config "$agent_id"
    [[ "${CLI_REQUIRES_NODE}" == "yes" ]] && prereqs+=("node")
    [[ "${CLI_REQUIRES_PYTHON}" == "yes" ]] && prereqs+=("python")
    for extra_prereq in ${CLI_RUNTIME_PREREQS}; do
      [[ -n "$extra_prereq" ]] && prereqs+=("$extra_prereq")
    done
  done

  serialize_agent_ids "${prereqs[@]-}"
}

container_command_exists() {
  local container="$1" command_name="$2"
  vm_exec "incus exec ${container} -- bash -lc 'command -v ${command_name}'" >/dev/null 2>&1
}

container_exec_shell() {
  local container="$1" command="$2" run_as="${3:-root}"
  local escaped_command="${command//\'/\'\\\'\'}"
  if [[ "$run_as" == "ubuntu" ]]; then
    vm_exec "incus exec ${container} --user ${SANDBOX_UID} --group ${SANDBOX_GID} --env HOME=${SANDBOX_USER_HOME} -- bash -lc '${escaped_command}'"
  else
    vm_exec "incus exec ${container} -- bash -lc '${escaped_command}'"
  fi
}

ensure_container_node_runtime() {
  local container="$1"
  if container_command_exists "$container" "node" && container_command_exists "$container" "npm"; then
    return 0
  fi

  info "Installing Node.js runtime in ${container}..."
  container_exec_shell "$container" "curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs && apt-get clean && rm -rf /var/lib/apt/lists/*"
}

ensure_container_agent_runtime_prereqs() {
  local container="$1"
  shift
  local prereqs_csv
  local prereq
  prereqs_csv=$(runtime_prereqs_for_agents "$@")
  while IFS= read -r prereq; do
    case "$prereq" in
      node|npm) ensure_container_node_runtime "$container" ;;
      python|"") ;;
      *) warn "Unknown runtime prerequisite '${prereq}' requested by agent config; skipping" ;;
    esac
  done < <(parse_agent_ids "$prereqs_csv")
}

validate_agent_cli_installation() {
  local container="$1" agent_id="$2"
  load_cli_config "$agent_id"
  container_exec_shell "$container" "$CLI_VERSION_CHECK_COMMAND" "$CLI_INSTALL_USER" >/dev/null
}

container_has_agent_cli() {
  local container="$1" agent_id="$2"
  validate_agent_cli_installation "$container" "$agent_id" >/dev/null 2>&1
}

install_agent_cli() {
  local container="$1" agent_id="$2"
  load_cli_config "$agent_id"

  if container_has_agent_cli "$container" "$agent_id"; then
    return 0
  fi

  info "Installing ${CLI_DISPLAY_NAME} in ${container}..."
  case "$CLI_INSTALL_STRATEGY" in
    npm|script|custom)
      container_exec_shell "$container" "$CLI_INSTALL_COMMAND" "$CLI_INSTALL_USER"
      ;;
    *)
      die "Unsupported install strategy '${CLI_INSTALL_STRATEGY}' for agent '${agent_id}'"
      ;;
  esac

  if [[ -n "$CLI_PATH_LINK_SOURCE" && -n "$CLI_PATH_LINK_TARGET" ]]; then
    container_exec_shell "$container" "ln -sf ${CLI_PATH_LINK_SOURCE} ${CLI_PATH_LINK_TARGET}" "root"
  fi

  validate_agent_cli_installation "$container" "$agent_id" \
    || die "Failed to validate ${CLI_DISPLAY_NAME} installation in ${container}"
}

install_selected_agent_clis() {
  local container="$1"
  shift
  local agent_id
  for agent_id in "$@"; do
    install_agent_cli "$container" "$agent_id"
  done
}

agent_launch_command() {
  local agent_id="$1"
  load_cli_config "$agent_id"
  if [[ -n "$CLI_DEFAULT_FLAGS" ]]; then
    echo "${CLI_LAUNCH_COMMAND} ${CLI_DEFAULT_FLAGS}"
  else
    echo "${CLI_LAUNCH_COMMAND}"
  fi
}

resolve_container_agent_id() {
  local container="$1"
  local requested_agent="${2:-}"
  if [[ -n "$requested_agent" ]]; then
    cli_config_path "$requested_agent" >/dev/null
    echo "$requested_agent"
    return 0
  fi

  local default_agent
  default_agent=$(get_default_agent_metadata "$container")
  if [[ -n "$default_agent" ]]; then
    echo "$default_agent"
  else
    default_install_agent_ids
  fi
}

effective_container_agents_csv() {
  local container="$1"
  local installed_agents
  installed_agents=$(get_installed_agents_metadata "$container")
  if [[ -n "$installed_agents" ]]; then
    echo "$installed_agents"
  else
    serialize_agent_ids "$(default_install_agent_ids)"
  fi
}

effective_container_agent_ids() {
  local container="$1"
  parse_agent_ids "$(effective_container_agents_csv "$container")"
}

container_agent_auth_status() {
  local container="$1" agent_id="$2"
  load_cli_config "$agent_id"
  if container_exec_shell "$container" "$CLI_AUTH_CHECK_COMMAND" "root" >/dev/null 2>&1; then
    echo "auth'd"
  else
    echo "no-auth"
  fi
}

format_agent_auth_statuses() {
  local container="$1"
  shift
  local statuses=()
  local agent_id
  local auth_status
  for agent_id in "$@"; do
    [[ -n "$agent_id" ]] || continue
    auth_status=$(container_agent_auth_status "$container" "$agent_id")
    statuses+=("${agent_id}:${auth_status}")
  done

  local IFS=' '
  echo "${statuses[*]-}"
}

agent_allowlist_paths() {
  local seen=$'\n'
  local agent_id
  local path
  for agent_id in "$@"; do
    [[ -n "$agent_id" ]] || continue
    load_cli_config "$agent_id"
    path="${CLI_ALLOWLIST_FILE}"
    if [[ -n "$path" && "$seen" != *$'\n'"$path"$'\n'* ]]; then
      echo "$path"
      seen+="${path}"$'\n'
    fi
  done
}

resolve_extra_domains_file() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    [[ -f "$explicit" ]] || die "Domains file not found: $explicit"
    echo "$explicit"
  elif [[ -f "${SANDBOX_USER_DOMAINS}" ]]; then
    echo "${SANDBOX_USER_DOMAINS}"
  fi
  return 0
}

merged_agent_allowlist_domains() {
  local extra_domains_file="${1:-}"
  shift || true

  local seen=$'\n'
  local file
  local line
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      if [[ "$seen" != *$'\n'"$line"$'\n'* ]]; then
        echo "$line"
        seen+="${line}"$'\n'
      fi
    done < <(parse_domains_file "$file")
  done < <(
    agent_allowlist_paths "$@"
    resolve_extra_domains_file "$extra_domains_file"
  )
}

write_merged_agent_allowlist_file() {
  local extra_domains_file="${1:-}"
  shift || true
  local merged_file
  merged_file=$(mktemp)
  merged_agent_allowlist_domains "$extra_domains_file" "$@" > "$merged_file"
  echo "$merged_file"
}

# ── VM execution abstraction ──────────────────────────────────────
# vm_run: Execute a command as root in the sandbox VM (exec-style, separate args).
#   Supports stdin piping and heredocs.
#   macOS: orb run -m sandbox sudo <args>
#   Linux: sudo <args>
vm_run() {
  if [[ "$SANDBOX_PLATFORM" == "macos" ]]; then
    orb run -m "${SANDBOX_MACHINE}" sudo "$@"
  else
    sudo "$@"
  fi
}

# vm_exec: Execute a shell command string as root in the sandbox VM (eval-style).
#   Use when the command contains pipes, redirects, or chained operators.
#   Delegates to vm_run, which handles sudo.
vm_exec() {
  vm_run bash -c "$1"
}

# ── Container naming ───────────────────────────────────────────────
container_name() {
  local name="$1"
  if [[ -z "$name" || ! "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
    echo "Invalid container name: '${name}'. Use only alphanumeric, hyphens, dots, underscores." >&2
    return 1
  fi
  echo "agent-${name}"
}

# Wait up to 30s for a container's eth0 to get an IPv4 address
wait_for_container_networking() {
  local container="$1"
  local attempts=0
  while ! vm_exec "incus exec ${container} -- ip addr show eth0 2>/dev/null | grep -q 'inet '" 2>/dev/null; do
    attempts=$((attempts + 1))
    if (( attempts > 30 )); then
      die "Timed out waiting for container networking"
    fi
    sleep 1
  done
}

# ── Slot management ────────────────────────────────────────────────
# Port scheme: SSH = 2200+slot, App = 8000+slot, Alt = 9000+slot
ssh_port()  { echo $(( 2200 + $1 )); }
app_port()  { echo $(( 8000 + $1 )); }
alt_port()  { echo $(( 9000 + $1 )); }
exposed_host_port() { echo $(( $1 + $2 )); }

# Get the IPv4 address of a container. Returns empty string if not found.
get_container_ip() {
  local container="$1"
  vm_exec "incus list ${container} -f csv -c 4 2>/dev/null | grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' | head -1" || true
}

# Check if a host port is already in use by another container's proxy device.
# Returns the conflicting container name, or empty string if no conflict.
# Usage: check_port_conflict <host_port> <protocol> <self_container>
check_port_conflict() {
  local host_port="$1" proto="$2" self="$3"
  vm_exec "
    for c in \$(incus list -f csv -c n 2>/dev/null | grep '^agent-'); do
      [ \"\$c\" = '${self}' ] && continue
      for dev in \$(incus config device list \"\$c\" 2>/dev/null | grep '^port-' || true); do
        listen=\$(incus config device get \"\$c\" \"\$dev\" listen 2>/dev/null || true)
        if echo \"\$listen\" | grep -q '^${proto}:.*:${host_port}\$'; then
          echo \"\$c\"
          exit 0
        fi
      done
    done
  " 2>/dev/null || true
}

# Returns list of currently used slots by querying ssh-proxy listen ports
used_slots() {
  vm_exec '
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
    die "Slot $slot is already in use. Used slots: $(echo "$used" | tr '\n' ' ')"
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
    gh repo deploy-key delete "$key_id" -R "$nwo" 2>/dev/null || true
  fi

  # Delete local key pair
  rm -f "$key_path" "${key_path}.pub" 2>/dev/null || true
}

# ── SSH agent management (per-container, inside OrbStack VM) ───────
ssh_agent_setup() {
  local container="$1"
  local key_path="$2"  # Host path to private key

  # Copy key into sandbox VM temporarily
  local vm_key="/tmp/sandbox-key-${container}"
  if [[ "$SANDBOX_PLATFORM" == "macos" ]]; then
    orb run -m "${SANDBOX_MACHINE}" tee "$vm_key" < "$key_path" >/dev/null
  else
    cp "$key_path" "$vm_key"
  fi
  vm_exec "chmod 600 ${vm_key}"

  # Push deploy key into the container for the ubuntu user
  vm_exec "incus file push ${vm_key} ${container}${SANDBOX_USER_HOME}/.ssh/deploy-key --uid=${SANDBOX_UID} --gid=${SANDBOX_GID} --mode=600"
  vm_exec "rm -f ${vm_key}"

  # Configure SSH to use deploy key for github.com
  vm_exec "incus exec ${container} -- bash -c 'cat > ${SANDBOX_USER_HOME}/.ssh/config << SSHEOF
Host github.com
  IdentityFile ${SANDBOX_USER_HOME}/.ssh/deploy-key
  StrictHostKeyChecking accept-new
SSHEOF
chmod 600 ${SANDBOX_USER_HOME}/.ssh/config
chown ${SANDBOX_UID}:${SANDBOX_GID} ${SANDBOX_USER_HOME}/.ssh/config'"

  # Start SSH agent inside the container (as root, then make socket accessible to ubuntu)
  vm_exec "incus exec ${container} -- bash -c 'eval \$(ssh-agent -a /run/ssh-agent.sock) && echo \$SSH_AGENT_PID > /run/ssh-agent.pid && chmod 660 /run/ssh-agent.sock && chown root:${SANDBOX_GID} /run/ssh-agent.sock && ssh-add ${SANDBOX_USER_HOME}/.ssh/deploy-key'"

  # Set SSH_AUTH_SOCK in ubuntu user's bashrc
  vm_exec "
    incus exec ${container} -- bash -c '
      grep -q SSH_AUTH_SOCK ${SANDBOX_USER_HOME}/.bashrc 2>/dev/null || \
        echo \"export SSH_AUTH_SOCK=/run/ssh-agent.sock\" >> ${SANDBOX_USER_HOME}/.bashrc
    '
  "
}

ssh_agent_cleanup() {
  local container="$1"

  # Kill agent inside the container
  vm_exec "incus exec ${container} -- bash -c 'if [ -f /run/ssh-agent.pid ]; then kill \$(cat /run/ssh-agent.pid) 2>/dev/null; fi; rm -f /run/ssh-agent.pid /run/ssh-agent.sock'" 2>/dev/null || true

  # Also clean up old-style VM-side agent (backward compat)
  vm_exec "
    if [ -f /tmp/sandbox-agent-${container}.pid ]; then
      kill \$(cat /tmp/sandbox-agent-${container}.pid) 2>/dev/null || true
      rm -f /tmp/sandbox-agent-${container}.pid
    fi
    rm -f /tmp/sandbox-agent-${container}.sock
  " 2>/dev/null || true
}

ssh_agent_restart() {
  local container="$1"
  if ! vm_exec "incus exec ${container} -- test -f ${SANDBOX_USER_HOME}/.ssh/deploy-key" 2>/dev/null; then
    info "No deploy key found in ${container}, skipping SSH agent restart"
    return 0
  fi
  vm_exec "incus exec ${container} -- bash -c '
    eval \$(ssh-agent -a /run/ssh-agent.sock)
    echo \$SSH_AGENT_PID > /run/ssh-agent.pid
    chmod 660 /run/ssh-agent.sock
    chown root:${SANDBOX_GID} /run/ssh-agent.sock
    ssh-add ${SANDBOX_USER_HOME}/.ssh/deploy-key
  '"
}

# ── Env forwarding ─────────────────────────────────────────────────
inject_env() {
  local container="$1"
  shift
  local extra_envs=("$@")

  # Read ~/.sandbox/env if it exists
  local env_lines=()
  if [[ -f "${SANDBOX_ENV_FILE}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      # Skip comments (including indented) and empty lines
      [[ "$line" =~ ^[[:space:]]*# || -z "${line// }" ]] && continue
      env_lines+=("$line")
    done < "${SANDBOX_ENV_FILE}"
  fi

  # Add extra env overrides
  if [[ ${#extra_envs[@]} -gt 0 ]]; then
    for e in "${extra_envs[@]}"; do
      env_lines+=("$e")
    done
  fi

  # Inject into /etc/profile.d so env vars are available to all login shells
  if [[ ${#env_lines[@]} -gt 0 ]]; then
    local tmpfile
    tmpfile=$(mktemp)
    for line in "${env_lines[@]}"; do
      if [[ "$line" != export\ * ]]; then
        printf 'export %s\n' "$line" >> "$tmpfile"
      else
        printf '%s\n' "$line" >> "$tmpfile"
      fi
    done
    # Pipe content into container via stdin — no shell interpolation of values
    vm_run incus exec "${container}" -- bash -c 'cat >> /etc/profile.d/sandbox-env.sh' < "$tmpfile"
    rm -f "$tmpfile"
  fi
}

# ── Container metadata helpers ─────────────────────────────────────
# Store metadata in Incus config user.* keys for later retrieval
set_metadata() {
  local container="$1" key="$2" value="$3"
  vm_run incus config set "$container" "user.sandbox.${key}" "$value"
}

get_metadata() {
  local container="$1" key="$2"
  vm_run incus config get "$container" "user.sandbox.${key}" 2>/dev/null || true
}

# ── Domain-based egress filtering (Squid proxy) ──────────────────

# Resolve which domains file to use: explicit path > user override > bundled default
resolve_domains_file() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    [[ -f "$explicit" ]] || die "Domains file not found: $explicit"
    echo "$explicit"
  elif [[ -f "${SANDBOX_USER_DOMAINS}" ]]; then
    echo "${SANDBOX_USER_DOMAINS}"
  elif [[ -f "${SANDBOX_DEFAULT_DOMAINS}" ]]; then
    echo "${SANDBOX_DEFAULT_DOMAINS}"
  else
    die "No domains file found. Expected one of: ${SANDBOX_USER_DOMAINS} or ${SANDBOX_DEFAULT_DOMAINS}"
  fi
}

# Parse a domains file: strip comments and blank lines, output clean domain list
parse_domains_file() {
  local file="$1"
  sed -e 's/[[:space:]]*#.*//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" || true
}

# Install squid-openssl in the VM if not present
ensure_squid_installed() {
  vm_run bash << 'SQUID_INSTALL'
set -e
if command -v squid &>/dev/null; then
  echo "Squid already installed"
  exit 0
fi

apt-get update
apt-get install -y squid-openssl ssl-cert
mkdir -p /etc/squid/sandbox/containers
echo "Squid installed"
SQUID_INSTALL
}

# Write base squid.conf with peek/splice SNI filtering config
deploy_squid_config() {
  vm_run bash << 'SQUID_CONF'
set -e

CONF_DIR="/etc/squid/sandbox"
CERT_DIR="/etc/squid/ssl"
mkdir -p "$CONF_DIR/containers" "$CERT_DIR"
# Ensure at least one .conf file exists so the glob include always succeeds
touch "$CONF_DIR/containers/000-placeholder.conf"

# Generate a dummy self-signed cert (required by Squid ssl-bump even without MITM)
if [ ! -f "$CERT_DIR/squid-dummy.pem" ]; then
  openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/CN=sandbox-squid-dummy" \
    -keyout "$CERT_DIR/squid-dummy.key" \
    -out "$CERT_DIR/squid-dummy.pem" 2>/dev/null
  cat "$CERT_DIR/squid-dummy.key" "$CERT_DIR/squid-dummy.pem" > "$CERT_DIR/squid-dummy-combined.pem"
  chmod 600 "$CERT_DIR/squid-dummy-combined.pem"
fi

# Initialise SSL db if needed
if [ ! -d /var/lib/squid/ssl_db ]; then
  /usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 4MB 2>/dev/null || true
  chown -R proxy:proxy /var/lib/squid/ssl_db 2>/dev/null || true
fi

cat > /etc/squid/squid.conf << 'EOF'
# Sandbox Squid — SNI-based transparent HTTPS filtering (peek/splice, no MITM)

# Transparent HTTPS interception port (containers are redirected here via iptables)
https_port 3129 intercept ssl-bump \
  cert=/etc/squid/ssl/squid-dummy-combined.pem \
  generate-host-certificates=off \
  dynamic_cert_mem_cache_size=4MB

# Forward-proxy port on localhost only (required by Squid for internal URL handling)
http_port 127.0.0.1:3128

sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/lib/squid/ssl_db -M 4MB

# Peek at TLS ClientHello to read SNI
acl step1 at_step SslBump1

# Include per-container ACLs (ssl_bump splice rules for allowed domains)
include /etc/squid/sandbox/containers/*.conf

# SSL bump steps:
# 1. Peek at ClientHello to read SNI (step1)
# 2. Per-container rules splice allowed domains (from included configs)
# 3. Default: terminate any connection not explicitly spliced
ssl_bump peek step1
ssl_bump terminate all

# Allow intercepted traffic through to the ssl-bump stage
# (actual filtering is done via ssl_bump rules, not http_access)
http_access allow all

# Logging
access_log daemon:/var/log/squid/access.log squid
cache_log /var/log/squid/cache.log

# No caching — we are a pass-through filter, not a cache
cache deny all

# Misc
visible_hostname sandbox-proxy
pid_filename /run/squid.pid
shutdown_lifetime 3 seconds
EOF

echo "Squid config deployed"
SQUID_CONF
}

# Upload domains list and generate per-container Squid ACL, then reload Squid
setup_container_domain_filter() {
  local container="$1"
  local domains_file="$2"
  local container_ip="$3"

  # Parse domains and upload to VM
  local parsed_domains
  parsed_domains=$(parse_domains_file "$domains_file")

  vm_exec "
    cat > /etc/squid/sandbox/containers/${container}.domains << 'DOMAINS'
${parsed_domains}
DOMAINS
  "

  vm_exec "
    cat > /etc/squid/sandbox/containers/${container}.conf << ACL_EOF
acl ${container}_src src ${container_ip}/32
acl ${container}_domains ssl::server_name \"/etc/squid/sandbox/containers/${container}.domains\"
ssl_bump splice ${container}_src ${container}_domains
ACL_EOF
  "

  vm_exec "squid -k reconfigure 2>/dev/null || systemctl reload squid 2>/dev/null || systemctl restart squid 2>/dev/null || true"
}

# Remove per-container Squid ACL and domains file, then reload
cleanup_container_domain_filter() {
  local container="$1"
  vm_exec "
    sudo rm -f /etc/squid/sandbox/containers/${container}.conf \
          /etc/squid/sandbox/containers/${container}.domains
    sudo squid -k reconfigure 2>/dev/null || sudo systemctl reload squid 2>/dev/null || sudo systemctl restart squid 2>/dev/null || true
  " 2>/dev/null || true
}

# Add iptables NAT PREROUTING rules to redirect this container's 443/80 traffic to Squid
redirect_container_to_squid() {
  local container_ip="$1"
  vm_exec "
    sudo iptables -t nat -A PREROUTING -s '${container_ip}/32' -p tcp --dport 443 \
      -j REDIRECT --to-port ${SQUID_PORT}
    sudo iptables -t nat -A PREROUTING -s '${container_ip}/32' -p tcp --dport 80 \
      -j REDIRECT --to-port ${SQUID_PORT}
  "
}

# Remove iptables NAT PREROUTING rules for this container
remove_container_squid_redirect() {
  local container_ip="$1"
  vm_exec "
    sudo iptables -t nat -S PREROUTING 2>/dev/null | grep '${container_ip}' | while read -r rule; do
      sudo iptables -t nat \$(echo \"\$rule\" | sed 's/^-A/-D/')
    done
  " 2>/dev/null || true
}

# Remove per-container FORWARD iptables rules
cleanup_container_forward_rules() {
  local container_ip="$1"
  vm_exec "
    sudo iptables -S FORWARD 2>/dev/null | grep '${container_ip}' | while read -r rule; do
      sudo iptables \$(echo \"\$rule\" | sed 's/^-A/-D/')
    done
  " 2>/dev/null || true
}

# ── Source this library ─────────────────────────────────────────────
# Usage in bin/* scripts:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "${SCRIPT_DIR}/../lib/sandbox-common.sh"
