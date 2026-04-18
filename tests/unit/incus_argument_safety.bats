#!/usr/bin/env bats
load '../test_helper/common'

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  VM_RUN_LOG="${TEST_TMPDIR}/vm_run.log"
  CANARY_PATH="${TEST_TMPDIR}/host-canary"
  vm_run() {
    printf 'call\n' >> "${VM_RUN_LOG}"
    printf '%q\n' "$@" >> "${VM_RUN_LOG}"
    return 0
  }
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "require_container: treats metacharacters as a literal incus argument" {
  local container_name="agent-test;touch ${CANARY_PATH}"

  run require_container "${container_name}"
  assert_success

  run cat "${VM_RUN_LOG}"
  assert_success
  assert_output --partial $'incus\ninfo\n'
  assert_output --partial "agent-test\\;touch\\ ${CANARY_PATH}"
  [ ! -e "${CANARY_PATH}" ]
}

@test "container_exec_shell: passes command to inner bash without host-side execution" {
  local command="echo safe && touch ${CANARY_PATH}"

  run container_exec_shell "agent-test" "${command}" "ubuntu"
  assert_success

  run cat "${VM_RUN_LOG}"
  assert_success
  assert_output --partial $'incus\nexec\nagent-test\n'
  assert_output --partial $'bash\n-lc\n'
  assert_output --partial "echo\\ safe\\ \\&\\&\\ touch\\ ${CANARY_PATH}"
  [ ! -e "${CANARY_PATH}" ]
}
