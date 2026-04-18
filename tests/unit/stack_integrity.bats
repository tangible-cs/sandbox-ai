#!/usr/bin/env bats
load '../test_helper/common'

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  source "${PROJECT_ROOT}/stacks/integrity.sh"
  source "${PROJECT_ROOT}/stacks/integrity-manifest.sh"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "verify_file_digest: accepts matching sha256" {
  printf 'sandbox\n' > "${TEST_TMPDIR}/sample.txt"
  run verify_file_digest "sha256" \
    "ea7ec57fa66bf8ac9b1989bc11350cfd42213d5e3f2cd8b4d2155fc53f9ba1b3" \
    "${TEST_TMPDIR}/sample.txt"
  assert_success
}

@test "verify_file_digest: rejects checksum mismatch" {
  printf 'sandbox\n' > "${TEST_TMPDIR}/sample.txt"
  run verify_file_digest "sha256" \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    "${TEST_TMPDIR}/sample.txt"
  assert_failure
}

@test "integrity manifest: includes pinned claude code version" {
  run bash -lc '
    source "'"${PROJECT_ROOT}"'/stacks/integrity-manifest.sh"
    printf "%s|%s\n" "$CLAUDE_CODE_VERSION" "$NODE_VERSION"
  '
  assert_success
  assert_output "2.1.114|v22.22.2"
}
