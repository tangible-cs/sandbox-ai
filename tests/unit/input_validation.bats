#!/usr/bin/env bats
load '../test_helper/common'

@test "validate_cpu: accepts whole-number limits" {
  run validate_cpu "2"
  assert_success
}

@test "validate_cpu: rejects shell metacharacters" {
  run validate_cpu '2;[SPECTER_CANARY]'
  assert_failure
  assert_output --partial "Invalid CPU value"
}

@test "validate_memory: accepts supported units" {
  run validate_memory "8GiB"
  assert_success
}

@test "validate_memory: rejects shell metacharacters" {
  run validate_memory '8GiB;[SPECTER_CANARY]'
  assert_failure
  assert_output --partial "Invalid memory value"
}

@test "validate_stack: accepts lowercase stack names" {
  run validate_stack "base"
  assert_success
}

@test "validate_stack: rejects shell metacharacters" {
  run validate_stack 'base;[SPECTER_CANARY]'
  assert_failure
  assert_output --partial "Invalid stack name"
}

@test "sandbox-start: rejects malicious cpu before sandbox interaction" {
  run "${PROJECT_ROOT}/bin/sandbox-start" "test-validation" --cpu '2;[SPECTER_CANARY]'
  assert_failure
  assert_output --partial "Invalid CPU value"
}

@test "sandbox-start: rejects malicious memory before sandbox interaction" {
  run "${PROJECT_ROOT}/bin/sandbox-start" "test-validation" --memory '8GiB;[SPECTER_CANARY]'
  assert_failure
  assert_output --partial "Invalid memory value"
}

@test "sandbox-start: rejects malicious stack before sandbox interaction" {
  run "${PROJECT_ROOT}/bin/sandbox-start" "test-validation" --stack 'base;[SPECTER_CANARY]'
  assert_failure
  assert_output --partial "Invalid stack name"
}
