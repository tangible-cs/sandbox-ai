#!/usr/bin/env bats
load '../test_helper/integration'

# Discover all stacks from stacks/*.sh and verify each can launch a container,
# execute commands, and store correct metadata.

_stacks_file() { echo "${BATS_FILE_TMPDIR}/all_stacks"; }
_prefix() { echo "test-${BATS_ROOT_PID:-$$}-stk"; }

setup_file() {
  local stacks_dir="${PROJECT_ROOT}/stacks"
  local stacks=()
  for f in "${stacks_dir}"/*.sh; do
    stacks+=("$(basename "$f" .sh)")
  done
  printf '%s\n' "${stacks[@]}" > "$(_stacks_file)"

  # Create a container for every stack
  local prefix
  prefix=$(_prefix)
  for stack in "${stacks[@]}"; do
    "${PROJECT_ROOT}/bin/sandbox-start" "${prefix}-${stack}" --stack "$stack"
  done
}

teardown_file() {
  local prefix
  prefix=$(_prefix)
  while IFS= read -r stack; do
    "${PROJECT_ROOT}/bin/sandbox-stop" "${prefix}-${stack}" --rm 2>/dev/null || true
  done < "$(_stacks_file)"
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

# ── Golden images ────────────────────────────────────────────────────

@test "all golden images have a ready snapshot" {
  while IFS= read -r stack; do
    run vm_exec "incus snapshot list golden-${stack} -f csv 2>/dev/null | grep -q ready"
    assert_success
  done < "$(_stacks_file)"
}

# ── Container launch ─────────────────────────────────────────────────

@test "all stack containers are running" {
  local prefix
  prefix=$(_prefix)
  while IFS= read -r stack; do
    run vm_exec "incus info agent-${prefix}-${stack} 2>/dev/null | grep 'Status:' | awk '{print \$2}'"
    assert_success
    assert_output "RUNNING"
  done < "$(_stacks_file)"
}

@test "all stack containers can execute commands" {
  local prefix
  prefix=$(_prefix)
  while IFS= read -r stack; do
    run vm_run incus exec "agent-${prefix}-${stack}" -- echo "ok"
    assert_success
    assert_output "ok"
  done < "$(_stacks_file)"
}

@test "all stack containers have correct stack metadata" {
  local prefix
  prefix=$(_prefix)
  while IFS= read -r stack; do
    run get_metadata "agent-${prefix}-${stack}" "stack"
    assert_success
    assert_output "$stack"
  done < "$(_stacks_file)"
}
