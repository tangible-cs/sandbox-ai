#!/usr/bin/env bats
load '../test_helper/common'

@test "effective_container_agents_csv: falls back to default agent when metadata is missing" {
  get_installed_agents_metadata() { echo ""; }

  run effective_container_agents_csv "agent-test"
  assert_success
  assert_output "codex"
}

@test "effective_container_agents_csv: returns stored metadata when present" {
  get_installed_agents_metadata() { echo "claude,codex"; }

  run effective_container_agents_csv "agent-test"
  assert_success
  assert_output "claude,codex"
}

@test "format_agent_auth_statuses: formats one status per agent" {
  container_agent_auth_status() {
    case "$2" in
      claude) echo "auth'd" ;;
      codex) echo "no-auth" ;;
    esac
  }

  run format_agent_auth_statuses "agent-test" "claude" "codex"
  assert_success
  assert_output "claude:auth'd codex:no-auth"
}
