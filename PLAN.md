# Plan: Multi-Agent CLI Support with Codex First

## Goal
Extend this project so a sandbox can support OpenAI Codex CLI in addition to Claude Code, with a general design that can later support other agentic engineering CLIs without turning the image matrix into a maintenance problem.

## Current State
- `golden-base` installs Claude Code unconditionally in `stacks/base.sh`.
- `sandbox` has a Claude-specific launch mode (`--claude`) rather than a generic agent selector.
- `sandbox-list` reports Claude auth explicitly.
- Domain filtering is centered on Anthropic defaults (`domains/anthropic-default.txt`).
- `golden-base` does not include Node.js, so npm-only CLIs are not universally available out of the box.

## Research Snapshot (April 17, 2026)
The current terminal-native CLIs worth tracking are:

1. OpenAI Codex CLI: local coding agent; supports ChatGPT-plan sign-in and API-key auth.
2. Anthropic Claude Code: terminal coding agent with native installer.
3. Google Gemini CLI: terminal agent with built-in tools and sandboxing docs.
4. Continue CLI (`cn`): terminal coding agent with TUI and headless modes.
5. OpenCode: open-source terminal coding agent with CLI/TUI/web modes.
6. Goose: agent CLI/Desktop with provider routing, including Claude Code and Codex providers.
7. Aider: terminal pair-programming agent with broad model/provider support.
8. Kiro CLI: AWS-backed terminal agent with custom agents and MCP support.
9. Amp: terminal coding agent with multi-model routing.
10. Crush: terminal agent with MCP and skills support.

These tools differ sharply in packaging:
- Native/script installer or standalone binary: Codex, Claude Code, Goose, OpenCode, Amp, Kiro.
- npm-first: Gemini CLI, Continue CLI, Crush, Codebuff-style tools.
- Python-isolated install: Aider.

This packaging split is the main architectural constraint for this repository.

## Recommendation
Do not install every CLI in every sandbox by default.

Instead:
- Allow one primary CLI per sandbox.
- Allow zero or more additional CLIs as optional installs.
- Keep Codex and Claude as first-class supported agents first.
- Add more CLIs through a registry-driven mechanism after the generic plumbing exists.

Why:
- Installing everything by default bloats `golden-base`, increases setup time, expands the network allowlist surface, and complicates auth/status checks.
- Supporting exactly one CLI per sandbox is too restrictive because some tools compose with others. Goose, for example, can use Codex or Claude Code as providers.
- The best tradeoff is one default agent plus optional extras.

## Proposed UX

### Sandbox Creation
Add agent selection to `sandbox-start`:

```bash
sandbox-start my-project git@github.com:me/repo.git --stack rust --agent codex
sandbox-start my-project git@github.com:me/repo.git --stack rust --agent claude --agent codex --default-agent codex
```

Behavior:
- `--agent <name>` is repeatable.
- `--default-agent <name>` sets the CLI used by generic launch shortcuts.
- If no `--agent` is provided and the command is interactive, prompt the user to choose one or more CLIs.
- If no `--agent` is provided and the command is non-interactive, preserve current behavior initially by installing Claude only, then consider a configurable default later.

### Session Entry
Generalize `sandbox`:

```bash
sandbox my-project --agent codex
sandbox my-project --agent claude
```

Compatibility:
- Keep `--claude` as a backward-compatible alias during migration.
- Add `--codex` as a convenience alias if desired, but make `--agent` the canonical interface.

### Authentication
Support both env-based and browser-based auth:
- Codex: support subscription login via `codex --login` inside the sandbox, with credentials persisted in the container home directory.
- Claude: keep current in-container auth behavior.
- Expose generic helpers later if needed, such as `sandbox-auth <name> <agent>`.

## Architecture

### 1. Add a CLI Configuration Registry
Create an `agents/` directory with one configuration file per supported CLI. Because this project is Bash-based, these should be shell-sourceable config files rather than JSON so they can be consumed directly by `sandbox-start`, `sandbox`, and test helpers.

Example future files:
- `agents/codex.conf`
- `agents/claude.conf`
- `agents/gemini.conf`

Each CLI config should define the attributes needed to install, launch, validate, authenticate, and report status consistently.

Recommended attributes:
- `id`: stable internal key, for example `codex`
- `display_name`: human-readable name
- `binary_name`: executable expected in `PATH`
- `install_strategy`: `binary`, `script`, `npm`, `pipx`, or `custom`
- `install_ref`: download URL, package name, or installer entrypoint
- `install_command`: canonical install command or script wrapper
- `update_command`: optional future update path
- `uninstall_command`: optional future uninstall path
- `launch_command`: canonical interactive launch command
- `headless_command`: optional non-interactive command form if the CLI supports it
- `version_check_command`: command used to verify installation
- `post_install_validation_command`: extra smoke test after installation
- `auth_strategy`: `browser_login`, `api_key`, `either`, or `external_provider`
- `auth_command`: command used to initiate login
- `auth_check_command`: command used by `sandbox-list` to detect auth state
- `credential_paths`: home-directory paths that should exist after login
- `required_env_vars`: env vars needed for non-browser auth or automation
- `optional_env_vars`: additional recognized env vars
- `supports_chatgpt_subscription_login`: `yes` or `no`
- `supports_browser_login`: `yes` or `no`
- `requires_node`: `yes` or `no`
- `requires_python`: `yes` or `no`
- `requires_uv_or_pipx`: `yes` or `no`
- `runtime_prereqs`: extra packages or commands needed before install
- `cache_strategy`: how artifacts should be cached, for example `binary`, `npm`, or `none`
- `cache_key`: stable identifier used for cached downloads/installers
- `allowlist_file`: provider/domain allowlist file for filtered sandboxes
- `session_home_subdir`: where the CLI stores config/auth under the user home
- `status_label`: short label for list/status output
- `default_flags`: any safe default flags the repo should pass when launching
- `notes`: optional human-facing notes for README/help output

This config layer should be the only place that knows whether a CLI needs Node, Python, a browser login flow, a provider-specific allowlist, or a special validation check.

### 2. Decouple Language Stacks from Agent CLIs
Keep `stacks/` focused on language/toolchain images.

Install selected agent CLIs after container creation, not by prebuilding every possible agent combination into golden snapshots. Otherwise the matrix becomes unmanageable:
- language stacks: base, rust, python, node, go, dotnet, unison
- agent combinations: potentially 2^N

That combination explosion is not acceptable.

Add a small runtime-prerequisite step driven by the CLI config:
- if `requires_node=yes`, ensure Node is present before installing that CLI
- if `requires_python=yes`, ensure the needed Python tooling exists
- keep these prerequisite installs scoped to the selected CLI, not forced into `golden-base`

This preserves the current contract that language/toolchain stacks stay intentional while agent support remains extensible.

### 3. Add Lightweight Install Caching
To preserve the repo’s “fast sandbox start” value:
- cache downloaded agent installers/binaries in the VM or host-side sandbox state directory
- reuse cached artifacts during `sandbox-start`
- validate versions before reuse

Codex should use the official standalone binary or official install path rather than forcing Node into `golden-base`.

### 4. Store Agent Metadata
Persist in Incus metadata:
- installed agents
- default agent
- install status/version if useful
- resolved prerequisite state if useful, for example whether Node was installed for this container because of a selected CLI

This enables `sandbox`, `sandbox-list`, and restart behavior without re-detection hacks.

### 5. Generalize Status Reporting
Replace the Claude-specific column in `sandbox-list` with something like:
- `DEFAULT`
- `AGENTS`
- `AUTH`

Start with compact output, for example:
- `DEFAULT=codex`
- `AGENTS=claude,codex`
- `AUTH=codex:auth'd claude:no-auth`

## Codex-Specific Work
Codex should be the first new agent implemented.

Codex plan:
1. Add `agents/codex.conf`.
2. Install Codex in a selected sandbox using an official supported method suitable for Linux containers.
3. Add a `sandbox --agent codex` launcher.
4. Document ChatGPT-plan login flow explicitly.
5. Add OpenAI-specific domain allowlist support for filtered sandboxes.
6. Add tests that verify install selection and successful command presence (`codex --version`), without depending on real login.

Important note:
- As of April 17, 2026, OpenAI documents subscription-backed Codex access through ChatGPT plans and a `codex --login` flow. This should be treated as a first-class path, not an API-key-only integration.

## Testing Strategy
- Unit tests for parsing repeatable `--agent` flags and default-agent validation.
- Unit tests for agent registry helpers and metadata serialization.
- Integration tests that start a sandbox with `--agent codex` and verify the binary exists.
- Integration tests for multiple agent selection, restart persistence, and generic session launching.
- Regression tests to preserve current Claude workflows.

## Documentation Changes
- Update README command examples from Claude-only language to agent-neutral language.
- Add a supported-agents section with install/auth notes.
- Expand `env.example` to clarify provider-specific keys and note that Codex can use ChatGPT-plan login instead of `OPENAI_API_KEY`.
- Document the recommendation: choose one default CLI, add extras only when needed.
- Document the CLI configuration model, especially `requires_node` and other runtime/auth/install attributes.

## Rollout Phases
1. Build the generic agent registry, metadata model, and `sandbox --agent` plumbing.
2. Implement Codex end to end.
3. Migrate Claude onto the same registry path without breaking existing flags.
4. Add interactive agent selection in `sandbox-start`.
5. Add provider-specific allowlists and auth/status reporting.
6. Evaluate the next expansion set: Gemini CLI, Goose, and Aider.

## Open Questions
- Which official Codex install path is most reliable for this Ubuntu-based container flow: standalone binary, npm, or both? A: go ahead and use npm. 

- Should agent installers run only at `sandbox-start`, or should there also be a `sandbox-agent add/remove` command later? A: allow selection of one or more at start. The user can add or remove on their own later. 

- How should interactive selection behave in non-TTY environments and CI? No idea, provide some ideas to float and allow me to choose when time to implement related behavior. 

- Should filtered mode merge allowlists per installed agent, or per default agent only?
A: merged 


## Sources
- OpenAI Codex CLI help: https://help.openai.com/en/articles/11096431-openai-codex-ci-getting-started
- Codex CLI sign-in with ChatGPT: https://help.openai.com/en/articles/11381614
- OpenAI Codex repo: https://github.com/openai/codex
- Claude Code setup: https://docs.anthropic.com/en/docs/claude-code/getting-started
- Gemini CLI docs: https://google-gemini.github.io/gemini-cli/docs/get-started/
- Continue CLI quickstart: https://docs.continue.dev/cli/quickstart
- OpenCode docs: https://opencode.ai/en/docs
- Goose install docs: https://block.github.io/goose/docs/getting-started/installation/
- Aider install docs: https://aider.chat/docs/install.html
- Kiro CLI docs: https://kiro.dev/docs/cli/
- Amp manual: https://ampcode.com/manual
- Crush repo: https://github.com/charmbracelet/crush
