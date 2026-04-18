#!/usr/bin/env bats
load '../test_helper/common'

@test "resolve_selected_agents: defaults to codex when no agents are provided" {
  run resolve_selected_agents
  assert_success
  assert_output "codex"
}

@test "resolve_selected_agents: deduplicates while preserving order" {
  run resolve_selected_agents "claude" "codex" "claude"
  assert_success
  assert_output "claude,codex"
}

@test "resolve_selected_agents: rejects an unknown agent" {
  run resolve_selected_agents "claude" "unknown-agent"
  assert_failure
  assert_output --partial "Unknown agent"
}

@test "select_default_agent: returns requested default when it is selected" {
  run select_default_agent "codex" "claude" "codex"
  assert_success
  assert_output "codex"
}

@test "select_default_agent: defaults to first selected agent when unspecified" {
  run select_default_agent "" "codex" "claude"
  assert_success
  assert_output "codex"
}

@test "select_default_agent: rejects a default agent that is not selected" {
  run select_default_agent "codex" "claude"
  assert_failure
  assert_output --partial "must also be included"
}
