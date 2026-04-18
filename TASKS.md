# Set Aside For Review

All executable implementation tasks from the prior task list have been completed. The remaining items are blocked on environment or policy decisions rather than code construction.


## 3. Fix Post-Setup Next Steps Messaging
Status: pending

What remains:
- Update the post-setup output so it does not tell users to rerun `./install.sh` after installation has already been completed.
- Replace that guidance with the correct shell refresh step, for example `source ~/.zshrc`, or otherwise make the message conditional on whether the wrappers are already on `PATH`.

What to review:
- After implementation, confirm the next-steps text matches the actual user workflow on macOS with `zsh`.

## 4. Add Robust `--help` Output Across CLI Utilities
Status: pending

What remains:
- Add consistent `--help` support to each user-facing utility in `bin/`, including at least:
  - `sandbox`
  - `sandbox-start`
  - `sandbox-stop`
  - `sandbox-list`
  - `sandbox-expose`
  - `sandbox-setup`
  - `sandbox-linux-prereqs`
  - `sandbox-nuke`
- Make each help screen include:
  - purpose
  - usage syntax
  - flag descriptions
  - a few realistic examples
  - any important defaults or side effects
- Ensure unknown flags point users toward `--help` instead of only failing generically.
- Add automated coverage for help output and basic usage/error messaging where practical.

What to review:
- After implementation, confirm the help text is concise, accurate, and sufficient for first-time users to operate the tools without opening the README.

## 5. Resolve missing prerequisite for codex in the golden image
Chris got this warning when running codex inside a sandbox: "Codex could not find bubblewrap on PATH. Install bubblewrap with your OS package manager. See the sandbox prerequisites:
  https://developers.openai.com/codex/concepts/sandboxing#prerequisites. Codex will use the vendored bubblewrap in the meantime."
  you ran out of usage before helping chris frame this task, so rewrite this task five for clarity on the fix approach, and fix the image so this warning (ensure all prereqs are installed)
  
## 6.  