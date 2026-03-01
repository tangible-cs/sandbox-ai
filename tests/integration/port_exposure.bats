#!/usr/bin/env bats
load '../test_helper/integration'

_name_file() { echo "${BATS_FILE_TMPDIR}/port_exposure_name"; }

setup_file() {
  TEST_CONTAINER_PREFIX="test-${BATS_ROOT_PID:-$$}"
  create_test_container
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

@test "sandbox-expose: adds proxy device for TCP port" {
  run "${PROJECT_ROOT}/bin/sandbox-expose" "$TEST_CONTAINER_NAME" 5432
  assert_success
}

@test "sandbox-expose: proxy connects to correct port" {
  # Device was created in previous test; verify connect address
  run vm_exec "incus config device get agent-${TEST_CONTAINER_NAME} port-5432-tcp connect 2>/dev/null"
  assert_success
  assert_output --partial ":5432"
}

@test "sandbox-expose: adds iptables FORWARD rule" {
  local container_ip
  container_ip=$(get_container_ip)
  run vm_exec "sudo iptables -S FORWARD 2>/dev/null | grep '\\-s ${container_ip}/32.*dport 5432'"
  assert_success
}

@test "sandbox-expose: rejects non-numeric port" {
  run "${PROJECT_ROOT}/bin/sandbox-expose" "$TEST_CONTAINER_NAME" abc
  assert_failure
  assert_output --partial "must be a number"
}

@test "sandbox-expose: rejects invalid protocol" {
  run "${PROJECT_ROOT}/bin/sandbox-expose" "$TEST_CONTAINER_NAME" 3000 ftp
  assert_failure
  assert_output --partial "must be tcp, udp, or both"
}

@test "sandbox-expose: supports UDP protocol" {
  run "${PROJECT_ROOT}/bin/sandbox-expose" "$TEST_CONTAINER_NAME" 5353 udp
  assert_success
  # Verify UDP device exists
  run vm_exec "incus config device get agent-${TEST_CONTAINER_NAME} port-5353-udp connect 2>/dev/null"
  assert_success
  assert_output --partial ":5353"
}

@test "sandbox-expose: 'both' creates TCP and UDP devices" {
  run "${PROJECT_ROOT}/bin/sandbox-expose" "$TEST_CONTAINER_NAME" 6000 both
  assert_success
  # Verify both devices exist
  run vm_exec "incus config device get agent-${TEST_CONTAINER_NAME} port-6000-tcp connect 2>/dev/null"
  assert_success
  run vm_exec "incus config device get agent-${TEST_CONTAINER_NAME} port-6000-udp connect 2>/dev/null"
  assert_success
}
