#!/usr/bin/env bats
load '../test_helper/common'

@test "serialize_agent_ids: empty list serializes to empty string" {
  run serialize_agent_ids
  assert_success
  assert_output ""
}

@test "serialize_agent_ids: single agent serializes unchanged" {
  run serialize_agent_ids "claude"
  assert_success
  assert_output "claude"
}

@test "serialize_agent_ids: multiple agents serialize as comma-separated list" {
  run serialize_agent_ids "claude" "codex"
  assert_success
  assert_output "claude,codex"
}

@test "serialize_agent_ids: removes duplicates while preserving order" {
  run serialize_agent_ids "claude" "codex" "claude"
  assert_success
  assert_output "claude,codex"
}

@test "parse_agent_ids: empty string yields no output" {
  run parse_agent_ids ""
  assert_success
  assert_output ""
}

@test "parse_agent_ids: comma-separated metadata yields one id per line" {
  run parse_agent_ids "claude,codex"
  assert_success
  assert_line --index 0 "claude"
  assert_line --index 1 "codex"
}

@test "set_default_agent_metadata: requires a non-empty id" {
  run set_default_agent_metadata "agent-test" ""
  assert_failure
  assert_output --partial "requires a non-empty agent id"
}
