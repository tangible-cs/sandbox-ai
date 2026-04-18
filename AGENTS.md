# Repository Guidelines

## Project Structure & Module Organization
This repository is a Bash-based CLI for managing isolated Incus sandboxes. Put user-facing commands in `bin/` (`sandbox-start`, `sandbox-stop`, `sandbox-setup`), shared helpers in `lib/sandbox-common.sh`, and stack image definitions in `stacks/*.sh`. Default network allowlists live in `domains/`. Tests are under `tests/`: fast pure-function coverage in `tests/unit/`, container-backed coverage in `tests/integration/`, shared BATS helpers in `tests/test_helper/`, and fixtures in `tests/fixtures/`.

## Build, Test, and Development Commands
Use the repository scripts directly:

- `./install.sh` installs wrappers for `bin/sandbox*` into `~/.local/bin`.
- `sandbox-setup` performs one-time environment setup and builds golden images.
- `./tests/run-tests.sh unit` runs fast unit tests.
- `./tests/run-tests.sh integration` runs real-container integration tests; requires `sandbox-setup`.
- `./tests/run-tests.sh` runs the full suite.
- `bats tests/unit/parse_domains.bats` runs one test file while iterating.

## Coding Style & Naming Conventions
Write Bash with `#!/usr/bin/env bash` and `set -euo pipefail`. Keep shared logic in `lib/` and leave `bin/` scripts focused on argument parsing and orchestration. Follow existing naming: dashed command files in `bin/`, lowercase stack files in `stacks/`, and snake_case function names such as `parse_repo_nwo` and `wait_for_container_networking`. Prefer clear helper functions, quote variable expansions, and keep comments brief and operational.

## Testing Guidelines
Tests use BATS plus `bats-support` and `bats-assert`, cloned into `tests/test_helper/`. Name test files by behavior, for example `parse_domains.bats` or `container_lifecycle.bats`. Add unit tests for pure parsing, validation, and port logic first; add integration tests when behavior depends on Incus, networking, or filesystem isolation. Keep integration tests cleanup-safe and runnable through `./tests/run-tests.sh integration`.

## Commit & Pull Request Guidelines
Recent history uses conventional prefixes with imperative summaries: `feat:`, `fix:`, `test:`, `docs:`. Keep that format, for example `fix: preserve domains file on restart`. PRs should describe the user-visible change, list commands run for validation, and call out platform scope (`macOS`, `Linux`, or both). For CLI or setup changes, include example commands or output snippets instead of screenshots.
When working in this repository, commit changes as you go: make one commit per completed task instead of leaving large batches uncommitted. At the end of a run of work, push the completed commits to `origin`.
Changes to `bin/`, `lib/`, `agents/`, `domains/`, `README.md`, or `AGENTS.md` are security-sensitive. Keep them under the repository `CODEOWNERS` policy and require code-owner review in GitHub before merge.

## Configuration & Security Notes
Never commit real credentials. Use `env.example` as the template for `~/.sandbox/env`, and treat `domains/anthropic-default.txt` changes as security-sensitive because they affect egress policy.
