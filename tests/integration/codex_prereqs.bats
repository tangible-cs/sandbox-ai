#!/usr/bin/env bats
load '../test_helper/integration'

_name_file() { echo "${BATS_FILE_TMPDIR}/codex_prereqs_name"; }

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

@test "base sandbox image includes bubblewrap for codex sandboxing" {
  run container_exec bwrap --version
  assert_success
  assert_output --regexp 'bubblewrap|bwrap'
}

@test "codex launches help output without sandbox prerequisite warnings" {
  run container_exec codex --help
  assert_success
  refute_output --partial "Codex could not find bubblewrap on PATH"
  refute_output --partial "kernel.apparmor_restrict_unprivileged_userns=0"
}
