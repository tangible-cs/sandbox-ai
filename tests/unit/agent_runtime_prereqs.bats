#!/usr/bin/env bats
load '../test_helper/common'

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  VM_EXEC_LOG="${TEST_TMPDIR}/vm_exec.log"
  info() { :; }
  ok() { :; }
  warn() { :; }
  vm_exec() {
    printf '%s\n' "$1" >> "${VM_EXEC_LOG}"
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

@test "runtime_prereqs_for_agents: codex requires node" {
  run runtime_prereqs_for_agents "codex"
  assert_success
  assert_output "node"
}

@test "runtime_prereqs_for_agents: deduplicates shared runtime requirements" {
  run runtime_prereqs_for_agents "codex" "claude" "codex"
  assert_success
  assert_output "node"
}

@test "ensure_container_agent_runtime_prereqs: installs node when required and missing" {
  container_command_exists() { return 1; }

  run ensure_container_agent_runtime_prereqs "agent-test" "codex"
  assert_success

  run cat "${VM_EXEC_LOG}"
  assert_success
  assert_output --partial "apt-get install -y nodejs"
}

@test "ensure_container_agent_runtime_prereqs: does nothing when node is already present" {
  container_command_exists() { return 0; }

  run ensure_container_agent_runtime_prereqs "agent-test" "codex"
  assert_success

  if [[ -f "${VM_EXEC_LOG}" ]]; then
    run cat "${VM_EXEC_LOG}"
    assert_success
    assert_output ""
  fi
}
