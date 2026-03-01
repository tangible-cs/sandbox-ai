#!/usr/bin/env bats
load '../test_helper/common'

# Override used_slots() to return empty — avoids Incus dependency
setup() {
  TEST_TMPDIR="$(mktemp -d)"
  used_slots() { echo ""; }
}

@test "validate_slot: accepts slot 1" {
  run validate_slot 1
  assert_success
}

@test "validate_slot: accepts slot 50" {
  run validate_slot 50
  assert_success
}

@test "validate_slot: accepts slot 99" {
  run validate_slot 99
  assert_success
}

@test "validate_slot: rejects slot 0" {
  run validate_slot 0
  assert_failure
  assert_output --partial "must be a number between 1 and 99"
}

@test "validate_slot: rejects slot 100" {
  run validate_slot 100
  assert_failure
  assert_output --partial "must be a number between 1 and 99"
}

@test "validate_slot: rejects negative number" {
  run validate_slot -5
  assert_failure
}

@test "validate_slot: rejects non-numeric input" {
  run validate_slot "abc"
  assert_failure
  assert_output --partial "must be a number between 1 and 99"
}

@test "validate_slot: rejects empty string" {
  run validate_slot ""
  assert_failure
}
