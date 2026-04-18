# Completed Tasks

The actionable items from the previous review cycle are now complete.

## 3. Fix Post-Setup Next Steps Messaging
Status: completed

What changed:
- `sandbox-setup` now prints a shell refresh step instead of incorrectly telling users to rerun `./install.sh`.
- The next-steps text is driven by a shared helper so the shell-specific command is testable.
- Coverage was added for `zsh`, `bash`, and fallback shells.

Validation:
- Unit coverage confirms the message includes `source ~/.zshrc` for `zsh`.
- The old `./install.sh` guidance is explicitly excluded by test.

## 4. Add Robust `--help` Output Across CLI Utilities
Status: completed

What changed:
- Added consistent `--help` support to:
  - `sandbox`
  - `sandbox-start`
  - `sandbox-stop`
  - `sandbox-list`
  - `sandbox-expose`
  - `sandbox-setup`
  - `sandbox-linux-prereqs`
  - `sandbox-nuke`
- Help output now includes purpose, usage, flags, defaults, and examples.
- Unknown flags now point users to the relevant `--help` screen.

Validation:
- Unit coverage exercises `--help` and unknown-flag behavior across all user-facing CLIs.

## 5. Resolve Missing Codex Prerequisite In The Golden Image
Status: completed

Fix approach implemented:
- Added `bubblewrap` to Codex runtime prerequisites.
- Added an on-start runtime fallback so Codex sandboxes install `bubblewrap` if it is missing.
- Added `bubblewrap` to `stacks/base.sh` so rebuilt golden images include it by default.
- Rebuilt `golden-base` and verified the live image contains `bwrap`.

Validation:
- Unit coverage asserts the Codex runtime prerequisite set includes `bubblewrap`.
- Unit coverage asserts `stacks/base.sh` installs `bubblewrap`.
- Integration coverage verifies `bwrap --version` succeeds inside a real base sandbox.

## 6. Placeholder
Status: pending definition

Notes:
- The task file previously contained a blank `6.` entry with no executable work attached to it.
- Leave this undefined until a concrete task is written.
