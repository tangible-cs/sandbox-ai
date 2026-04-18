#!/usr/bin/env bats
load '../test_helper/common'

@test "setup_shell_refresh_command: prefers zsh when current shell is zsh" {
  run bash -lc "SCRIPT_DIR='${PROJECT_ROOT}/bin'; source '${PROJECT_ROOT}/lib/sandbox-common.sh'; SHELL=/bin/zsh; setup_shell_refresh_command"

  assert_success
  assert_output "source ~/.zshrc"
}

@test "setup_shell_refresh_command: prefers bash when current shell is bash" {
  run bash -lc "SCRIPT_DIR='${PROJECT_ROOT}/bin'; source '${PROJECT_ROOT}/lib/sandbox-common.sh'; SHELL=/bin/bash; setup_shell_refresh_command"

  assert_success
  assert_output "source ~/.bashrc"
}

@test "setup_shell_refresh_command: falls back to a new login shell when shell is unknown" {
  run bash -lc "SCRIPT_DIR='${PROJECT_ROOT}/bin'; source '${PROJECT_ROOT}/lib/sandbox-common.sh'; SHELL=/bin/fish; setup_shell_refresh_command"

  assert_success
  assert_output "exec \$SHELL -l"
}

@test "setup_next_steps_message: uses the shell refresh helper instead of install.sh guidance" {
  run bash -lc "SCRIPT_DIR='${PROJECT_ROOT}/bin'; source '${PROJECT_ROOT}/lib/sandbox-common.sh'; SHELL=/bin/zsh; setup_next_steps_message"

  assert_success
  assert_output --partial "source ~/.zshrc"
  refute_output --partial "./install.sh"
  assert_output --partial "sandbox-start my-project git@github.com:you/repo.git --stack base"
}
