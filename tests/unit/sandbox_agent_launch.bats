#!/usr/bin/env bats
load '../test_helper/common'

@test "agent_launch_command: uses claude default flags from config" {
  run agent_launch_command "claude"
  assert_success
  assert_output "claude --dangerously-skip-permissions"
}

@test "agent_launch_command: returns codex launch command" {
  run agent_launch_command "codex"
  assert_success
  assert_output "codex"
}

@test "resolve_container_agent_id: prefers requested agent" {
  get_default_agent_metadata() { echo "claude"; }

  run resolve_container_agent_id "agent-test" "codex"
  assert_success
  assert_output "codex"
}

@test "resolve_container_agent_id: falls back to container metadata" {
  get_default_agent_metadata() { echo "codex"; }

  run resolve_container_agent_id "agent-test" ""
  assert_success
  assert_output "codex"
}

@test "resolve_container_agent_id: falls back to repo default when metadata is missing" {
  get_default_agent_metadata() { echo ""; }

  run resolve_container_agent_id "agent-test" ""
  assert_success
  assert_output "codex"
}
