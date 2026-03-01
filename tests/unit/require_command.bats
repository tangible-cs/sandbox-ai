#!/usr/bin/env bats
load '../test_helper/common'

@test "require_command: succeeds for bash" {
  run require_command "bash"
  assert_success
}

@test "require_command: succeeds for cat" {
  run require_command "cat"
  assert_success
}

@test "require_command: fails for nonexistent command" {
  run require_command "nonexistent_cmd_xyz_12345"
  assert_failure
  assert_output --partial "required but not found"
}

@test "require_command: error message includes command name" {
  run require_command "my_missing_tool"
  assert_failure
  assert_output --partial "my_missing_tool"
}
