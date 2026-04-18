#!/usr/bin/env bats
load '../test_helper/integration'

_name_file() { echo "${BATS_FILE_TMPDIR}/agent_metadata_name"; }

setup_file() {
  create_test_container || return
  echo "$TEST_CONTAINER_NAME" > "$(_name_file)"
}

teardown_file() {
  TEST_CONTAINER_NAME=$(<"$(_name_file)")
  destroy_test_container
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  TEST_CONTAINER_NAME=$(<"$(_name_file)")
}

@test "set_installed_agents_metadata: stores a single agent" {
  run set_installed_agents_metadata "agent-${TEST_CONTAINER_NAME}" "claude"
  assert_success

  run get_installed_agents_metadata "agent-${TEST_CONTAINER_NAME}"
  assert_success
  assert_output "claude"
}

@test "set_installed_agents_metadata: stores multiple unique agents" {
  run set_installed_agents_metadata "agent-${TEST_CONTAINER_NAME}" "claude" "codex" "claude"
  assert_success

  run get_installed_agents_metadata "agent-${TEST_CONTAINER_NAME}"
  assert_success
  assert_output "claude,codex"
}

@test "set_default_agent_metadata: stores the default agent" {
  run set_default_agent_metadata "agent-${TEST_CONTAINER_NAME}" "codex"
  assert_success

  run get_default_agent_metadata "agent-${TEST_CONTAINER_NAME}"
  assert_success
  assert_output "codex"
}
