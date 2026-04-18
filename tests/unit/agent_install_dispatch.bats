#!/usr/bin/env bats
load '../test_helper/common'

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  EXEC_LOG="${TEST_TMPDIR}/exec.log"
  info() { :; }
  ok() { :; }
  warn() { :; }
  container_exec_shell() {
    local container="$1" command="$2" run_as="${3:-root}"
    printf '%s|%s|%s\n' "${container}" "${run_as}" "${command}" >> "${EXEC_LOG}"
  }
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "install_agent_cli: skips work when the agent is already installed" {
  container_has_agent_cli() { return 0; }

  run install_agent_cli "agent-test" "claude"
  assert_success

  if [[ -f "${EXEC_LOG}" ]]; then
    run cat "${EXEC_LOG}"
    assert_success
    assert_output ""
  fi
}

@test "install_agent_cli: runs npm install for codex when missing" {
  container_has_agent_cli() { return 1; }
  validate_agent_cli_installation() { return 0; }

  run install_agent_cli "agent-test" "codex"
  assert_success

  run cat "${EXEC_LOG}"
  assert_success
  assert_output --partial "agent-test|root|npm install -g @openai/codex"
}

@test "install_agent_cli: runs the pinned claude npm install as root" {
  container_has_agent_cli() { return 1; }
  validate_agent_cli_installation() { return 0; }

  run install_agent_cli "agent-test" "claude"
  assert_success

  run cat "${EXEC_LOG}"
  assert_success
  assert_output --partial "agent-test|root|ACTUAL_INTEGRITY=\$(npm view @anthropic-ai/claude-code@2.1.114 dist.integrity)"
}
