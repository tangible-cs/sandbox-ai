#!/usr/bin/env bats
load '../test_helper/integration'

_name_file() { echo "${BATS_FILE_TMPDIR}/env_resources_name"; }

setup_file() {
  local name="test-${BATS_ROOT_PID:-$$}-envres"
  echo "$name" > "$(_name_file)"

  "${PROJECT_ROOT}/bin/sandbox-start" "$name" --stack base \
    --env MY_TEST_VAR=hello_world \
    --env SECOND_VAR=42 \
    --cpu 2 \
    --memory 512MB
}

teardown_file() {
  local name
  name=$(<"$(_name_file)")
  "${PROJECT_ROOT}/bin/sandbox-stop" "$name" --rm 2>/dev/null || true
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  TEST_CONTAINER_NAME=$(<"$(_name_file)")
}

@test "env: MY_TEST_VAR is set inside container" {
  run vm_run incus exec "agent-${TEST_CONTAINER_NAME}" -- \
    bash -lc 'echo $MY_TEST_VAR'
  assert_success
  assert_output "hello_world"
}

@test "env: SECOND_VAR is set inside container" {
  run vm_run incus exec "agent-${TEST_CONTAINER_NAME}" -- \
    bash -lc 'echo $SECOND_VAR'
  assert_success
  assert_output "42"
}

@test "resources: CPU limit applied" {
  run vm_exec "incus config get agent-${TEST_CONTAINER_NAME} limits.cpu"
  assert_success
  assert_output "2"
}

@test "resources: memory limit applied" {
  run vm_exec "incus config get agent-${TEST_CONTAINER_NAME} limits.memory"
  assert_success
  assert_output "512MB"
}

@test "stop container for restart tests" {
  run "${PROJECT_ROOT}/bin/sandbox-stop" "$TEST_CONTAINER_NAME"
  assert_success
  assert_output --partial "Stopped"
}

@test "restart with additional env var succeeds" {
  run "${PROJECT_ROOT}/bin/sandbox-start" "$TEST_CONTAINER_NAME" \
    --env RESTART_VAR=from_restart
  assert_success
  assert_output --partial "restarted"
}

@test "new env var available after restart" {
  run vm_run incus exec "agent-${TEST_CONTAINER_NAME}" -- \
    bash -lc 'echo $RESTART_VAR'
  assert_success
  assert_output "from_restart"
}

@test "original env vars survive restart" {
  run vm_run incus exec "agent-${TEST_CONTAINER_NAME}" -- \
    bash -lc 'echo $MY_TEST_VAR'
  assert_success
  assert_output "hello_world"
}
