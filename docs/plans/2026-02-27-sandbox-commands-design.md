# Sandboxed Claude Code — Implementation Design

## Overview

A set of 8 commands for running Claude Code agents in YOLO mode inside isolated Incus system containers, nested inside an OrbStack Linux VM on macOS. Each container gets its own filesystem, Docker daemon, SSH agent, and network-scoped deploy key.

## Architecture

```
macOS (safe, never touched by agents)
 |
 +-- OrbStack machine "sandbox" (lightweight Linux VM, shared kernel)
      |
      +-- Incus (btrfs storage, incusbr0 bridge)
           |
           +-- golden-base/ready     (Docker, Node, Claude Code, SSH, git, Python 3)
           +-- golden-rust/ready     (base + Rust toolchain + quality tools)
           +-- golden-python/ready   (base + Poetry, uv, ruff, mypy, etc.)
           +-- golden-node/ready     (base + pnpm, yarn, bun, eslint, etc.)
           +-- golden-go/ready       (base + Go, golangci-lint, govulncheck)
           +-- golden-dotnet/ready   (base + .NET SDK, dotnet tools)
           |
           +-- agent-proj-alpha      (clone of golden-rust)
           +-- agent-proj-beta       (clone of golden-node)
           +-- agent-proj-gamma      (clone of golden-python)
           +-- ...
```

### Port Forwarding Chain

```
Incus container (app listens on 0.0.0.0:<port>)
  --> Incus proxy device: listen=tcp:0.0.0.0:<host-port> connect=tcp:127.0.0.1:<port>
OrbStack machine (now listening on 0.0.0.0:<host-port>)
  --> OrbStack auto-forward
macOS localhost:<host-port>
```

Port exposure is always bidirectional — one command opens inbound (macOS to container) and outbound (container to external) for the given port.

## Prerequisites

- **macOS** with Apple Silicon or Intel
- **OrbStack** installed (`brew install orbstack`)
- **gh** CLI installed and authenticated (`gh auth login`) — needed for deploy key automation
- User must have admin access on target repos (to add deploy keys)
- At least 16GB RAM recommended

## Project Structure

```
sandbox-claude/
+-- bin/
|   +-- sandbox              # Session entry (shell/claude/cmd, auto-tmux)
|   +-- sandbox-setup        # One-time: OrbStack VM + Incus + golden images + egress
|   +-- sandbox-create       # Create container
|   +-- sandbox-stop         # Stop/remove container
|   +-- sandbox-nuke         # Destroy all containers
|   +-- sandbox-list         # List containers with health
|   +-- sandbox-expose       # Expose extra ports (bidirectional)
|   +-- sandbox-login        # Claude OAuth login flow
+-- lib/
|   +-- sandbox-common.sh    # Shared functions
+-- stacks/
|   +-- base.sh              # Core golden image
|   +-- rust.sh              # Rust additions
|   +-- python.sh            # Python additions
|   +-- node.sh              # Node additions
|   +-- go.sh                # Go additions
|   +-- dotnet.sh            # .NET additions
+-- install.sh               # Symlinks bin/* into ~/.local/bin
+-- README.md
+-- docs/                    # Design docs (reference)
+-- .gitignore
```

## Shared Library: lib/sandbox-common.sh

Sourced by every `bin/sandbox-*` script. Contains:

- `MACHINE="sandbox"` — constant for OrbStack machine name
- `container_name <name>` — returns `agent-<name>`
- `next_free_slot` — queries running containers, returns lowest unused slot (1-99)
- `port_for_slot <slot> <type>` — calculates port: SSH=2200+slot, App=8000+slot, Alt=9000+slot
- `validate_slot <slot>` — checks no port collision with running containers
- `load_env [extra-env-args...]` — reads `~/.sandbox/env` + --env overrides
- `orb_exec <command>` — wrapper for `orb run -m sandbox`
- `require_golden <stack>` — validates golden image exists, errors if not
- `ssh_agent_setup <container> <key-path>` — spawn dedicated ssh-agent, mount socket
- `ssh_agent_cleanup <container>` — kill agent, remove socket
- `deploy_key_create <name> <repo-url>` — generate key, register via gh, return key path
- `deploy_key_cleanup <name> <repo-url>` — remove from GitHub, delete local key
- `require_command <cmd>` — validates a CLI tool is available

## Commands

### sandbox-setup

One-time infrastructure setup. Idempotent — safe to re-run.

Steps:
1. Validate prerequisites: OrbStack installed, gh authenticated
2. Create OrbStack machine `sandbox` (skip if exists)
3. Install Incus inside the VM: Zabbly repo, btrfs backend, incusbr0 bridge, preseed config (skip if installed)
4. Apply default egress rules on incusbr0:
   - Default policy: DROP all outbound from containers
   - Allow DNS: TCP+UDP port 53
   - Allow HTTP: TCP port 80
   - Allow HTTPS: TCP+UDP port 443 (HTTP/3 QUIC support)
   - Allow SSH: TCP port 22 (git over SSH)
   - Allow established/related return traffic
5. Build golden images:
   - Run `stacks/base.sh` to create `golden-base`, snapshot as `golden-base/ready`
   - For each variant (rust, python, node, go, dotnet): clone `golden-base/ready`, run variant script inside, snapshot as `golden-<stack>/ready`
   - Skip stacks that already have a `ready` snapshot

Flags:
- `--rebuild <stack>` — force rebuild of a specific stack image

### sandbox-create

Create a new agent container.

```
sandbox-create <name> [repo-url] [flags]

Flags:
  --stack <name>       Golden image to use (default: base)
  --branch <name>      Git branch to checkout (default: repo default)
  --from <name>        Copy repo URL and stack from existing container
  --ssh-key <path>     Use specific key instead of auto-generating deploy key
  --slot <n>           Force specific slot (default: auto-assign)
  --cpu <n>            CPU limit (default: no limit, shares VM resources)
  --memory <size>      Memory limit (default: no limit, shares VM resources)
  --env KEY=VALUE      Extra env var (repeatable)
```

Steps:
1. Validate golden image exists for stack
2. Auto-assign slot (or validate provided slot is free)
3. If repo URL provided and no --ssh-key: auto-generate deploy key via gh, register on repo
4. Clone golden image snapshot (instant with btrfs CoW)
5. Set resource limits (only if --cpu or --memory provided)
6. Add proxy devices: SSH (2200+slot), App (8000+slot), Alt (9000+slot)
7. Start container
8. If ssh key (auto or manual): spawn dedicated ssh-agent in OrbStack, mount socket into container
9. Inject env vars from ~/.sandbox/env + --env overrides into /root/.bashrc
10. If repo URL: clone repo into /workspace/project (with --branch if specified)
11. Print connection info

Examples:
```bash
# Minimal
sandbox-create scratch

# Typical
sandbox-create proj-alpha git@github.com:me/alpha.git --stack rust

# Branch from existing container
sandbox-create proj-alpha-hotfix --from proj-alpha --branch hotfix/auth-fix

# Custom resources
sandbox-create big-build git@github.com:me/monorepo.git --stack node --cpu 8 --memory 16GiB
```

### sandbox

Session entry point. Opens shell, runs Claude, or executes a command. Single container = direct session, multiple containers = auto-tmux.

```
sandbox <name> [name2...] [flags]

Flags:
  --claude             Run Claude Code instead of shell
  --cmd "<command>"    Run a specific command
```

All sessions use `incus exec` via `orb run` (consistent, no SSH dependency).

Examples:
```bash
sandbox proj-alpha                           # shell into one container
sandbox proj-alpha proj-beta                 # tmux with shells in each
sandbox proj-alpha --claude                  # run claude in one container
sandbox proj-alpha proj-beta --claude        # tmux with claude in each
sandbox proj-alpha --cmd "git status"        # run command in one
sandbox proj-alpha proj-beta --cmd "git st"  # tmux with command in each
```

### sandbox-stop

Stop and optionally remove a container.

```
sandbox-stop <name> [--rm]
```

- Without --rm: stops the container, kills ssh-agent, deploy key stays on GitHub (container can restart)
- With --rm: stops container, kills ssh-agent, removes deploy key from GitHub via gh, deletes local key pair, deletes container

### sandbox-nuke

Destroy all agent containers.

```
sandbox-nuke [--all]
```

- Without --all: destroys all agent-* containers, cleans up their deploy keys and ssh-agents. Preserves golden images.
- With --all: also destroys golden images. Full reset — re-run sandbox-setup to rebuild.

Requires interactive confirmation ("yes").

### sandbox-list

List all containers with health status.

```
CONTAINER              STATE     SLOT  SSH   APP   ALT   EXTRA          DOCKER  AGENT  CLAUDE  REPO
agent-proj-alpha       Running   1     2201  8001  9001  5432,6379      ok      ok     auth'd  me/alpha (main)
agent-proj-beta        Running   2     2202  8002  9002  -              ok      no-key no-auth me/beta (main)
agent-proj-gamma       Stopped   3     2203  8003  9003  3000           -       -      -       me/gamma (dev)
```

Health checks (via incus exec into running containers):
- DOCKER: `docker info` succeeds -> ok, fails -> err
- AGENT: `ssh-add -l` succeeds -> ok, no keys -> no-key, no socket -> none
- CLAUDE: auth token exists in ~/.claude/ -> auth'd, missing -> no-auth
- REPO: git remote URL (shortened) + current branch
- EXTRA: comma-separated list of additional exposed ports

Stopped containers show `-` for health columns.

### sandbox-expose

Expose additional ports bidirectionally.

```
sandbox-expose <name> <port> [protocol]
```

- Default protocol: tcp
- Options: tcp, udp, both
- Opens INBOUND (macOS:port -> container:port) via Incus proxy device
- Opens OUTBOUND (container -> external:port) via per-container iptables rule
- Both directions in one command

Examples:
```bash
sandbox-expose proj-alpha 5432             # PostgreSQL (TCP both ways)
sandbox-expose proj-alpha 5432 udp         # UDP both ways
sandbox-expose proj-alpha 5432 both        # TCP+UDP both ways
```

### sandbox-login

Authenticate Claude Code via OAuth inside a container.

Steps:
1. Add temporary proxy device for OAuth callback port
2. Run `claude login` inside the container via incus exec
3. User completes OAuth in Mac browser
4. Auth token stored in container's ~/.claude/ (persists across restarts)
5. Remove temporary proxy device
6. Confirm success

```
sandbox-login <name>
```

## SSH Agent Isolation & Deploy Keys

Each container gets its own dedicated ssh-agent process running inside the OrbStack VM.

### Automated deploy key lifecycle

On `sandbox-create` (when repo URL provided, no --ssh-key flag):
1. Generate ed25519 key pair: `~/.sandbox/keys/deploy_<name>`
2. Register on GitHub: `gh repo deploy-key add ... -R <repo> -t "sandbox-<name>" -w`
3. Spawn ssh-agent in OrbStack: socket at `/tmp/sandbox-agent-<container>.sock`
4. Add key to agent: `ssh-add`
5. Mount socket into container as Incus disk device at `/run/ssh-agent.sock`
6. Set `SSH_AUTH_SOCK=/run/ssh-agent.sock` in container's `/root/.bashrc`

On `sandbox-stop`:
- Kill ssh-agent, remove socket
- Deploy key stays on GitHub (container may restart)

On `sandbox-stop --rm`:
- Kill ssh-agent, remove socket
- Remove deploy key from GitHub: `gh repo deploy-key delete <id> -R <repo>`
- Delete local key pair from `~/.sandbox/keys/`

### Security properties

- Key material never touches container disk (only in ssh-agent memory)
- Each deploy key is scoped to one repo (GitHub enforces this)
- Each container only sees its own key (separate agent process)
- Deploy keys have write access (-w flag) for push capability
- Keys are cleaned up from GitHub when container is destroyed (--rm)

### Manual key override

For repos where you can't use deploy keys (org restrictions, etc.):
```bash
sandbox-create proj git@github.com:me/repo.git --ssh-key ~/.ssh/my_key
```
This skips the gh automation and uses the provided key directly.

## Stacks

### base.sh (core golden image)

Tools:
- Docker CE + docker-compose-plugin
- Node.js 22 LTS + npm
- Claude Code (npm global)
- Python 3 + pip + venv
- git, tmux, openssh-server, ripgrep, jq, htop, wget, unzip
- build-essential, ca-certificates

Config:
- SSH enabled (PermitRootLogin yes)
- Docker enabled
- /workspace directory created

### rust.sh (base +)

- Rust toolchain via rustup (stable)
- clippy (linting, included with rustup)
- rustfmt (formatting, included with rustup)
- cargo-tarpaulin (coverage)
- cargo-audit (security)

### python.sh (base +)

- poetry (dependency management)
- uv (fast package installer)
- ruff (linting + formatting)
- mypy (type checking)
- bandit (security)
- coverage (code coverage)

### node.sh (base +)

- pnpm
- yarn
- bun
- c8 (coverage, uses V8 native coverage)
- eslint (linting)
- prettier (formatting)

### go.sh (base +)

- Go toolchain (latest stable)
- golangci-lint (meta-linter)
- govulncheck (security)
- go tool cover (built-in coverage)

### dotnet.sh (base +)

- .NET SDK (latest LTS)
- dotnet-coverage (coverage)
- dotnet format (built-in formatting)
- dotnet-sonarscanner (quality analysis)
- Security analyzers via NuGet

## Egress Filtering

### Default rules (applied during sandbox-setup)

Applied as iptables rules on incusbr0 inside the OrbStack VM:

- Default: DROP all outbound from containers to external network
- Allow DNS: TCP+UDP port 53
- Allow HTTP: TCP port 80
- Allow HTTPS: TCP+UDP port 443 (includes HTTP/3 QUIC)
- Allow SSH: TCP port 22
- Allow established/related return traffic

### Per-container overrides

`sandbox-expose` opens ports bidirectionally, including an iptables rule keyed on the container's IP for outbound. Opening port 5432 on proj-alpha does not open it for proj-beta.

Cleanup: `sandbox-stop` removes per-container iptables rules.

## Env Forwarding

Layered approach:

1. `~/.sandbox/env` — default env file, always loaded. Auto-forwards ANTHROPIC_API_KEY if set.
2. `--env KEY=VALUE` on sandbox-create and sandbox — per-session overrides, repeatable.
3. Env vars injected into container's `/root/.bashrc` for persistence across sessions.

## .gitignore

```
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
```

Local user config (`~/.sandbox/env`, `~/.sandbox/keys/`) lives outside the repo entirely.

## Implementation Order

### Phase 1: Foundation
1. Create project structure (bin/, lib/, stacks/, .gitignore)
2. Implement lib/sandbox-common.sh with all shared functions
3. Implement install.sh

### Phase 2: Infrastructure
4. Implement sandbox-setup (OrbStack machine + Incus + egress rules)
5. Implement stacks/base.sh
6. Implement variant stacks (rust, python, node, go, dotnet)

### Phase 3: Container Lifecycle
7. Implement sandbox-create (with auto-slot, deploy keys, ssh-agent, env forwarding)
8. Implement sandbox-stop (with cleanup)
9. Implement sandbox-nuke

### Phase 4: Session & Operations
10. Implement sandbox (shell/claude/tmux consolidated command)
11. Implement sandbox-list (with health checks)
12. Implement sandbox-expose (bidirectional)
13. Implement sandbox-login (OAuth flow)

### Phase 5: Documentation
14. Write README.md with quickstart, full reference, troubleshooting
15. Document GitHub deploy key setup and security model
16. Document stack customisation (how to add your own)
