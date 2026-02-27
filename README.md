# Sandbox Claude Code

Run Claude Code agents in fully isolated Incus containers inside an OrbStack VM on macOS. Enable YOLO mode with confidence -- your Mac filesystem, credentials, and network stay untouched. Each container gets its own filesystem, Docker daemon, workspace, dedicated SSH deploy key, bidirectional port forwarding, and egress filtering.

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quickstart](#quickstart)
- [Commands Reference](#commands-reference)
- [GitHub Deploy Keys](#github-deploy-keys)
- [Stacks](#stacks)
- [Port Allocation](#port-allocation)
- [Security Model](#security-model)
- [Environment Variables](#environment-variables)
- [Troubleshooting](#troubleshooting)

## Architecture

The sandbox uses a three-layer isolation model:

```
macOS (safe, never touched by agents)
 |
 +-- OrbStack machine "sandbox" (lightweight Ubuntu Noble VM, shared kernel)
      |
      +-- Incus (btrfs storage pool, incusbr0 bridge network)
           |
           +-- golden-base/ready     (Docker, Node 22, Claude Code, SSH, git, Python 3)
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

**Port forwarding** is bidirectional and traverses two hops:

```
Incus container (app listens on 0.0.0.0:<port>)
  --> Incus proxy device: listen=tcp:0.0.0.0:<host-port> connect=tcp:127.0.0.1:<port>
OrbStack machine (now listening on 0.0.0.0:<host-port>)
  --> OrbStack auto-forward
macOS localhost:<host-port>
```

Golden images are btrfs snapshots. Creating a new container is an instant copy-on-write clone -- no reinstalling packages, no waiting.

## Prerequisites

| Requirement | How to install | Why |
|---|---|---|
| **macOS** (Apple Silicon or Intel) | -- | Host OS |
| **OrbStack** | `brew install orbstack` | Lightweight Linux VM runtime |
| **GitHub CLI (`gh`)** | `brew install gh` then `gh auth login` | Deploy key automation |
| **Admin access** on target repos | -- | Required to register deploy keys |
| **16 GB RAM** (recommended) | -- | VM + containers + Docker daemons |

## Quickstart

```bash
# 1. Clone and install
git clone https://github.com/you/sandbox-claude.git
cd sandbox-claude
./install.sh                # Symlinks bin/* into ~/.local/bin

# 2. One-time setup (creates VM, installs Incus, builds golden images)
sandbox-setup               # Takes ~10 minutes the first time

# 3. Create a sandbox for your project
sandbox-create my-project git@github.com:me/my-repo.git --stack rust

# 4. Authenticate Claude inside the container
sandbox-login my-project

# 5. Open a shell to verify everything
sandbox my-project

# 6. Run Claude Code in YOLO mode
sandbox my-project --claude

# 7. When done, stop or destroy
sandbox-stop my-project       # Stop (preserves container, can restart)
sandbox-stop my-project --rm  # Destroy (removes container + deploy key)
```

## Commands Reference

### Overview

| Command | Purpose |
|---|---|
| `sandbox-setup` | One-time: create VM, install Incus, build golden images, apply egress rules |
| `sandbox-create` | Create a new agent container from a golden image |
| `sandbox` | Session entry point: shell, Claude, or arbitrary command |
| `sandbox-list` | List all containers with health status |
| `sandbox-expose` | Expose additional ports bidirectionally |
| `sandbox-login` | Authenticate Claude Code via OAuth inside a container |
| `sandbox-stop` | Stop and optionally remove a container |
| `sandbox-nuke` | Destroy all agent containers (nuclear option) |

---

### sandbox-setup

One-time infrastructure setup. Idempotent -- safe to re-run.

```
sandbox-setup [--rebuild <stack>]
```

| Flag | Description |
|---|---|
| `--rebuild <stack>` | Force rebuild of a specific golden image (e.g. `base`, `rust`, `all`) |

**What it does:**

1. Validates prerequisites (OrbStack, `gh`, `ssh-keygen`)
2. Creates OrbStack machine `sandbox` (Ubuntu Noble) -- skips if exists
3. Installs Incus inside the VM (Zabbly repo, btrfs backend, `incusbr0` bridge) -- skips if installed
4. Applies default egress iptables rules on `incusbr0`
5. Builds golden images: runs `stacks/base.sh` first, then each variant stack. Skips stacks that already have a `ready` snapshot

```bash
# First time setup
sandbox-setup

# Rebuild just the Rust golden image (e.g., after updating stacks/rust.sh)
sandbox-setup --rebuild rust

# Rebuild everything from scratch
sandbox-setup --rebuild all
```

---

### sandbox-create

Create a new agent container.

```
sandbox-create <name> [repo-url] [flags]
```

| Flag | Description | Default |
|---|---|---|
| `--stack <name>` | Golden image to use | `base` |
| `--branch <name>` | Git branch to checkout after cloning | Repo default branch |
| `--from <name>` | Copy repo URL and stack from an existing container | -- |
| `--ssh-key <path>` | Use a specific SSH key instead of auto-generating a deploy key | Auto-generate |
| `--slot <n>` | Force a specific port slot (1-99) | Auto-assign |
| `--cpu <n>` | CPU core limit | No limit (shares VM) |
| `--memory <size>` | Memory limit (e.g., `8GiB`) | No limit (shares VM) |
| `--env KEY=VALUE` | Extra environment variable (repeatable) | -- |

**Steps performed:**

1. Validates the golden image exists for the chosen stack
2. Auto-assigns the next free slot (or validates a manually provided slot)
3. If a repo URL is provided and `--ssh-key` is not set: auto-generates an ed25519 deploy key and registers it on GitHub via `gh`
4. Clones the golden image snapshot (instant btrfs copy-on-write)
5. Applies resource limits if `--cpu` or `--memory` are set
6. Adds Incus proxy devices for SSH, App, and Alt ports
7. Starts the container
8. Sets up a dedicated ssh-agent in the OrbStack VM and mounts the socket into the container
9. Injects environment variables from `~/.sandbox/env` and any `--env` overrides into `/root/.bashrc`
10. Clones the repo into `/workspace/project` (with `--branch` if specified)
11. Stores metadata (stack, repo, slot) in Incus config for later retrieval
12. Prints connection info

```bash
# Minimal -- just a scratch container
sandbox-create scratch

# Typical usage -- project with a specific stack
sandbox-create proj-alpha git@github.com:me/alpha.git --stack rust

# Branch from an existing container (inherits repo URL and stack)
sandbox-create proj-alpha-hotfix --from proj-alpha --branch hotfix/auth-fix

# Custom resources for a heavy build
sandbox-create big-build git@github.com:me/monorepo.git --stack node --cpu 8 --memory 16GiB

# Manual SSH key (for repos where deploy keys can't be used)
sandbox-create proj git@github.com:me/repo.git --ssh-key ~/.ssh/my_key

# Extra env vars
sandbox-create proj git@github.com:me/repo.git --env DB_HOST=localhost --env DB_PORT=5432
```

---

### sandbox

Session entry point. Opens a shell, runs Claude Code, or executes a command inside one or more containers. When multiple containers are specified, a tmux session is created with a pane for each.

```
sandbox <name> [name2...] [flags]
```

| Flag | Description |
|---|---|
| `--claude` | Run Claude Code instead of a shell |
| `--cmd "<command>"` | Run a specific command |

All sessions use `incus exec` via `orb run` -- no SSH dependency.

```bash
# Shell into one container
sandbox proj-alpha

# tmux session with shells in two containers
sandbox proj-alpha proj-beta

# Run Claude Code in one container
sandbox proj-alpha --claude

# Run Claude Code in multiple containers (tmux, one per pane)
sandbox proj-alpha proj-beta --claude

# Run a command in one container
sandbox proj-alpha --cmd "git status"

# Run the same command across multiple containers
sandbox proj-alpha proj-beta --cmd "git status"
```

---

### sandbox-list

List all containers with health status.

```
sandbox-list
```

No flags. Produces a table like:

```
CONTAINER              STATE     SLOT  SSH   APP   ALT   EXTRA          DOCKER  AGENT  CLAUDE  REPO
agent-proj-alpha       Running   1     2201  8001  9001  5432,6379      ok      ok     auth'd  me/alpha (main)
agent-proj-beta        Running   2     2202  8002  9002  -              ok      no-key no-auth me/beta (main)
agent-proj-gamma       Stopped   3     2203  8003  9003  3000           -       -      -       me/gamma (dev)
```

**Health check columns** (checked via `incus exec` into running containers):

| Column | Meaning |
|---|---|
| DOCKER | `docker info` succeeds: `ok`, fails: `err` |
| AGENT | `ssh-add -l` succeeds: `ok`, no keys loaded: `no-key`, no socket: `none` |
| CLAUDE | Auth token in `~/.claude/`: `auth'd`, missing: `no-auth` |
| REPO | Shortened git remote URL + current branch |
| EXTRA | Comma-separated list of additionally exposed ports |

Stopped containers show `-` for all health columns.

---

### sandbox-expose

Expose additional ports bidirectionally (inbound from macOS to container AND outbound from container to external network).

```
sandbox-expose <name> <port> [protocol]
```

| Argument | Description | Default |
|---|---|---|
| `<name>` | Container name (without `agent-` prefix) | Required |
| `<port>` | Port number to expose | Required |
| `[protocol]` | `tcp`, `udp`, or `both` | `tcp` |

**What it does:**

- **Inbound**: Creates an Incus proxy device so `macOS:port` reaches the container
- **Outbound**: Adds a per-container iptables rule so the container can reach external services on that port

Both directions are opened in a single command.

```bash
# Expose PostgreSQL (TCP both directions)
sandbox-expose proj-alpha 5432

# Expose a UDP port
sandbox-expose proj-alpha 5432 udp

# Expose both TCP and UDP
sandbox-expose proj-alpha 5432 both
```

---

### sandbox-login

Authenticate Claude Code via OAuth inside a container.

```
sandbox-login <name>
```

**Steps:**

1. Adds a temporary Incus proxy device for the OAuth callback port
2. Runs `claude login` inside the container via `incus exec`
3. You complete the OAuth flow in your Mac browser
4. The auth token is stored in the container's `~/.claude/` directory (persists across restarts)
5. Removes the temporary proxy device
6. Confirms success

---

### sandbox-stop

Stop and optionally remove a container.

```
sandbox-stop <name> [--rm]
```

| Flag | Description |
|---|---|
| `--rm` | Also remove the container, its deploy key from GitHub, and the local key pair |

**Without `--rm`:**
- Stops the container
- Kills the ssh-agent
- Deploy key stays on GitHub (container can be restarted later)

**With `--rm`:**
- Stops the container
- Kills the ssh-agent
- Removes the deploy key from GitHub via `gh repo deploy-key delete`
- Deletes the local key pair from `~/.sandbox/keys/`
- Deletes the container

```bash
# Stop (preserves state, can restart)
sandbox-stop proj-alpha

# Full teardown
sandbox-stop proj-alpha --rm
```

---

### sandbox-nuke

Destroy all agent containers. Requires interactive confirmation.

```
sandbox-nuke [--all]
```

| Flag | Description |
|---|---|
| `--all` | Also destroy golden images (requires re-running `sandbox-setup`) |

**Without `--all`:** Destroys all `agent-*` containers, cleans up their deploy keys and ssh-agents. Golden images are preserved.

**With `--all`:** Also destroys golden images. Full reset -- run `sandbox-setup` again to rebuild.

Prompts for confirmation by typing `yes`.

```bash
# Remove all agent containers, keep golden images
sandbox-nuke

# Full nuclear reset -- everything gone
sandbox-nuke --all
```

## GitHub Deploy Keys

### Automatic Lifecycle

When you create a container with a repo URL (and no `--ssh-key` flag), the deploy key lifecycle is fully automated:

**On `sandbox-create`:**

1. Generates an ed25519 key pair at `~/.sandbox/keys/deploy_<name>`
2. Registers the public key on GitHub via `gh repo deploy-key add -R <org/repo> -t "sandbox-<name>" -w` (the `-w` flag grants write/push access)
3. Spawns a dedicated ssh-agent process inside the OrbStack VM with its socket at `/tmp/sandbox-agent-<container>.sock`
4. Adds the private key to the agent via `ssh-add`
5. Mounts the agent socket into the container as an Incus disk device at `/run/ssh-agent.sock`
6. Sets `SSH_AUTH_SOCK=/run/ssh-agent.sock` in the container's `/root/.bashrc`

**On `sandbox-stop`:**

- Kills the ssh-agent and removes the socket
- The deploy key remains on GitHub so the container can be restarted

**On `sandbox-stop --rm`:**

- Kills the ssh-agent and removes the socket
- Removes the deploy key from GitHub via `gh repo deploy-key delete`
- Deletes the local key pair from `~/.sandbox/keys/`

### Security Properties

- Private key material never touches the container's disk -- it lives only in the ssh-agent's memory
- Each deploy key is scoped to a single repository (enforced by GitHub)
- Each container has its own ssh-agent process -- containers cannot see each other's keys
- Deploy keys have write access (`-w` flag) so Claude can push commits
- Keys are automatically cleaned up from GitHub when a container is destroyed with `--rm`

### Manual Key Override

For repos where deploy keys cannot be used (org policy restrictions, monorepo setups, etc.):

```bash
sandbox-create proj git@github.com:me/repo.git --ssh-key ~/.ssh/my_key
```

This skips the `gh` automation entirely and uses the provided key directly. The key is loaded into a dedicated ssh-agent the same way, but no deploy key is registered on GitHub, and no cleanup is performed on `--rm`.

## Stacks

Golden images are pre-built container snapshots with all tooling installed. Creating a new container from a golden image is instant (btrfs copy-on-write clone).

### Available Stacks

| Stack | Image Name | Includes | Quality/Coverage Tools |
|---|---|---|---|
| **base** | `golden-base` | Docker CE + docker-compose-plugin, Node.js 22 LTS + npm, Claude Code (npm global), Python 3 + pip + venv, git, tmux, openssh-server, ripgrep, jq, htop, wget, unzip, build-essential, ca-certificates | -- |
| **rust** | `golden-rust` | Everything in base + Rust stable toolchain via rustup | clippy (linting), rustfmt (formatting), cargo-tarpaulin (coverage), cargo-audit (security) |
| **python** | `golden-python` | Everything in base + Poetry, uv | ruff (linting + formatting), mypy (type checking), bandit (security), coverage (code coverage) |
| **node** | `golden-node` | Everything in base + pnpm, yarn, bun | c8 (V8-native coverage), eslint (linting), prettier (formatting) |
| **go** | `golden-go` | Everything in base + Go latest stable | golangci-lint (meta-linter), govulncheck (security), `go tool cover` (built-in coverage) |
| **dotnet** | `golden-dotnet` | Everything in base + .NET SDK (latest LTS) | dotnet-coverage (coverage), `dotnet format` (built-in formatting), dotnet-sonarscanner (quality analysis), security analyzers via NuGet |

### Adding a Custom Stack

1. Create a new file `stacks/<name>.sh`. The script runs inside a container that already has the base stack installed.

```bash
#!/usr/bin/env bash
# stacks/elixir.sh -- Elixir toolchain + quality tools
# Runs INSIDE container after base.sh
set -e
export DEBIAN_FRONTEND=noninteractive

echo "Installing Elixir stack..."

# Add Erlang Solutions repo
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
dpkg -i erlang-solutions_2.0_all.deb
apt-get update
apt-get install -y esl-erlang elixir

# Quality tools
mix local.hex --force
mix local.rebar --force
mix archive.install hex phx_new --force

echo "Elixir stack complete"
```

2. Make it executable:

```bash
chmod +x stacks/elixir.sh
```

3. Rebuild golden images to include it:

```bash
sandbox-setup --rebuild elixir
```

4. Use it:

```bash
sandbox-create my-elixir-app git@github.com:me/app.git --stack elixir
```

## Port Allocation

Each container is assigned a **slot** (1-99). Slots are auto-assigned by default (lowest available) or manually specified with `--slot`.

### Slot-Based Port Scheme

| Port Type | Formula | Range | Purpose |
|---|---|---|---|
| **SSH** | 2200 + slot | 2201-2299 | SSH access to container |
| **App** | 8000 + slot | 8001-8099 | Primary application port (maps to container port 8080) |
| **Alt** | 9000 + slot | 9001-9099 | Secondary application port (maps to container port 9090) |

For example, a container in slot 3 gets:

- SSH: `localhost:2203`
- App: `localhost:8003` (maps to container `127.0.0.1:8080`)
- Alt: `localhost:9003` (maps to container `127.0.0.1:9090`)

### Extra Ports

Use `sandbox-expose` to open additional ports beyond the standard three. Extra ports are mapped 1:1 (macOS port = container port) and also open outbound access for that port.

```bash
# Open PostgreSQL port
sandbox-expose proj-alpha 5432

# Open Redis port
sandbox-expose proj-alpha 6379

# Both show up in sandbox-list under the EXTRA column
sandbox-list
# ... EXTRA: 5432,6379
```

## Security Model

### What IS Protected

| Boundary | Protection |
|---|---|
| **macOS filesystem** | Agents run inside Incus containers inside an OrbStack VM. No macOS filesystem access whatsoever. |
| **Per-container isolation** | Each container is a separate Incus system container with its own filesystem, process tree, and network namespace. Containers cannot see each other. |
| **SSH private keys** | Private keys live only in ssh-agent memory inside the OrbStack VM. Key material never touches the container's disk. |
| **Deploy key scoping** | Each deploy key is scoped to a single GitHub repository. A compromised container cannot access other repos. |
| **Egress filtering** | Default iptables rules on `incusbr0` DROP all outbound traffic except DNS (53), HTTP (80), HTTPS (443), and SSH (22). Containers cannot reach arbitrary services unless explicitly opened with `sandbox-expose`. |
| **Port isolation** | Extra ports opened via `sandbox-expose` are per-container (keyed on container IP). Opening port 5432 on `proj-alpha` does not open it for `proj-beta`. |

### What is NOT Protected by Default

| Risk | Details |
|---|---|
| **Container-to-container via bridge** | Containers on the same `incusbr0` bridge can potentially reach each other. Incus profile-level network isolation is not enforced by default. |
| **OrbStack VM access** | All containers share the same OrbStack VM kernel. A container escape (unlikely but theoretically possible) would give access to the VM, though not to macOS. |
| **Env var exposure** | Environment variables injected via `~/.sandbox/env` or `--env` are written to `/root/.bashrc` inside the container. An agent can read them. This is by design (agents need API keys to function), but be aware. |
| **Deploy key write access** | Deploy keys are created with `-w` (write) access. An agent can push to the repo it was created for. |
| **HTTPS traffic content** | Egress filtering allows all HTTPS traffic. Agents can reach any HTTPS endpoint (npm registry, PyPI, crates.io, but also arbitrary APIs). Content inspection is not performed. |
| **Persistent container state** | Stopping a container preserves its filesystem. Anything the agent wrote remains until the container is destroyed with `--rm`. |

## Environment Variables

### The `~/.sandbox/env` File

Create `~/.sandbox/env` to define environment variables that are automatically injected into every container:

```bash
# ~/.sandbox/env
ANTHROPIC_API_KEY=sk-ant-...
GITHUB_TOKEN=ghp_...
MY_CUSTOM_VAR=some-value
```

This file is read by `sandbox-create` and injected into each container's `/root/.bashrc`. Variables persist across container restarts.

### Per-Container Overrides with `--env`

Add or override environment variables for a specific container:

```bash
sandbox-create proj git@github.com:me/repo.git \
  --env DATABASE_URL=postgres://localhost/mydb \
  --env REDIS_URL=redis://localhost:6379
```

The `--env` flag is repeatable. Values provided via `--env` take precedence over values in `~/.sandbox/env`.

### Layering Order

1. `~/.sandbox/env` -- loaded first, applies to all containers
2. `--env KEY=VALUE` -- per-container overrides, applied after

### env.example Reference

A typical `~/.sandbox/env` file:

```bash
# Required for Claude Code
ANTHROPIC_API_KEY=sk-ant-your-key-here

# Optional: GitHub token for API access inside containers
GITHUB_TOKEN=ghp_your-token-here

# Optional: Custom variables for your projects
NODE_ENV=development
RUST_LOG=debug
```

The `~/.sandbox/` directory (including `env` and `keys/`) lives outside the repo entirely and is never committed.

## Troubleshooting

### Docker Not Working Inside Container

**Symptom:** `docker: Cannot connect to the Docker daemon` or similar errors.

**Cause:** Docker-in-Incus requires specific security settings on the container.

**Fix:** Golden images are created with the correct security flags (`security.nesting=true`, `security.syscalls.intercept.mknod=true`, `security.syscalls.intercept.setxattr=true`). If Docker still fails:

```bash
# Shell into the container and check Docker service
sandbox proj-alpha --cmd "systemctl status docker"

# Restart Docker daemon
sandbox proj-alpha --cmd "systemctl restart docker"

# If the container was created without proper flags, recreate it
sandbox-stop proj-alpha --rm
sandbox-create proj-alpha git@github.com:me/alpha.git --stack rust
```

### Cannot Access Ports from macOS

**Symptom:** `curl localhost:8001` times out or refuses connection.

**Cause:** The port forwarding chain has two hops (container -> OrbStack -> macOS). A break at either hop causes failures.

**Fix:**

```bash
# 1. Check that the container is running
sandbox-list

# 2. Verify the app is listening inside the container
sandbox proj-alpha --cmd "ss -tlnp | grep 8080"

# 3. Verify the Incus proxy device exists
sandbox proj-alpha --cmd "exit"  # just confirm you can connect
orb run -m sandbox incus config device show agent-proj-alpha

# 4. Check OrbStack is forwarding
orb run -m sandbox ss -tlnp | grep 8001
```

Your app must listen on `0.0.0.0` (not `127.0.0.1`) inside the container for port forwarding to work through the Incus proxy device.

### Disk Space Issues

**Symptom:** Containers fail to start or builds fail with "no space left on device".

**Fix:**

```bash
# Check disk usage inside the VM
orb run -m sandbox df -h

# Check btrfs usage
orb run -m sandbox btrfs filesystem usage /

# Remove stopped containers to reclaim space
sandbox-nuke

# Nuclear option: destroy everything and rebuild
sandbox-nuke --all
sandbox-setup
```

### Resource Limits

By default, containers share the VM's resources without hard limits. If an agent is consuming too much:

```bash
# Create with limits
sandbox-create proj git@github.com:me/repo.git --cpu 4 --memory 8GiB

# Or set limits on an existing container (requires stop/start)
orb run -m sandbox incus config set agent-proj limits.cpu=4
orb run -m sandbox incus config set agent-proj limits.memory=8GiB
orb run -m sandbox incus restart agent-proj
```

### Rebuilding Golden Images

If a golden image becomes stale (outdated packages, broken dependencies):

```bash
# Rebuild a specific stack
sandbox-setup --rebuild rust

# Rebuild everything (base + all variants)
sandbox-setup --rebuild all
```

Existing containers are NOT affected by golden image rebuilds. Only new containers created after the rebuild will use the updated image.

### Deploy Key Issues

**Symptom:** `git push` fails with "Permission denied (publickey)".

```bash
# 1. Check the ssh-agent has a key loaded
sandbox proj-alpha --cmd "ssh-add -l"

# 2. Test SSH connectivity to GitHub
sandbox proj-alpha --cmd "ssh -T git@github.com"

# 3. Check if the deploy key exists on GitHub
gh repo deploy-key list -R me/alpha

# 4. If the key was removed manually from GitHub, recreate the container
sandbox-stop proj-alpha --rm
sandbox-create proj-alpha git@github.com:me/alpha.git --stack rust
```

**Symptom:** `sandbox-create` fails with "Failed to add deploy key".

- Verify you have admin access on the target repo
- Verify `gh auth status` shows a valid session
- For org repos, check if the org has restrictions on deploy keys

### Claude Auth Issues

**Symptom:** Claude reports it is not authenticated.

```bash
# Re-run the login flow
sandbox-login proj-alpha

# Verify auth token exists
sandbox proj-alpha --cmd "ls -la ~/.claude/"
```

The auth token is stored inside the container at `~/.claude/` and persists across container restarts. It is lost only when the container is destroyed with `--rm`.

### OrbStack VM Not Starting

```bash
# Check OrbStack status
orb list

# Try restarting the sandbox machine
orb stop sandbox
orb start sandbox

# If the machine is corrupted, recreate it (destroys all containers)
orb delete sandbox
sandbox-setup
```

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
|   +-- sandbox-common.sh    # Shared functions (slot mgmt, deploy keys, ssh-agent, env)
+-- stacks/
|   +-- base.sh              # Core golden image
|   +-- rust.sh              # Rust additions
|   +-- python.sh            # Python additions
|   +-- node.sh              # Node additions
|   +-- go.sh                # Go additions
|   +-- dotnet.sh            # .NET additions
+-- install.sh               # Symlinks bin/* into ~/.local/bin
+-- docs/                    # Design docs (reference)
+-- .gitignore
```

## License

MIT
