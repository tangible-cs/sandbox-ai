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

@test "runtime_prereqs_for_agents: claude requires no extra runtime" {
  run runtime_prereqs_for_agents "claude"
  assert_success
  assert_output ""
}

@test "runtime_prereqs_for_agents: codex requires node and bubblewrap" {
  run runtime_prereqs_for_agents "codex"
  assert_success
  assert_output "node,bubblewrap"
}

@test "runtime_prereqs_for_agents: deduplicates shared runtime requirements" {
  run runtime_prereqs_for_agents "codex" "claude" "codex"
  assert_success
  assert_output "node,bubblewrap"
}

@test "ensure_container_agent_runtime_prereqs: installs node and bubblewrap when required and missing" {
  container_command_exists() { return 1; }

  run ensure_container_agent_runtime_prereqs "agent-test" "codex"
  assert_success

  run cat "${EXEC_LOG}"
  assert_success
  assert_output --partial "apt-get install -y nodejs"
  assert_output --partial "apt-get install -y bubblewrap"
}

@test "ensure_container_agent_runtime_prereqs: does nothing when node is already present" {
  container_command_exists() { return 0; }

  run ensure_container_agent_runtime_prereqs "agent-test" "codex"
  assert_success

  if [[ -f "${EXEC_LOG}" ]]; then
    run cat "${EXEC_LOG}"
    assert_success
    assert_output ""
  fi
}
