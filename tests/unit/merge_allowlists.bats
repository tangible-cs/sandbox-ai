#!/usr/bin/env bats
load '../test_helper/common'

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "agent_allowlist_paths: returns configured allowlist files" {
  run agent_allowlist_paths "claude" "codex"
  assert_success
  assert_line "${PROJECT_ROOT}/domains/anthropic-default.txt"
  assert_line "${PROJECT_ROOT}/domains/openai-default.txt"
}

@test "merged_agent_allowlist_domains: includes domains from all selected agents" {
  run merged_agent_allowlist_domains "" "claude" "codex"
  assert_success
  assert_line --partial "anthropic.com"
  assert_line ".openai.com"
}

@test "merged_agent_allowlist_domains: includes custom extra domains" {
  cat > "${TEST_TMPDIR}/extra-domains.txt" <<'EOF'
example.internal
EOF

  run merged_agent_allowlist_domains "${TEST_TMPDIR}/extra-domains.txt" "codex"
  assert_success
  assert_line ".openai.com"
  assert_line "example.internal"
}

@test "merged_agent_allowlist_domains: deduplicates repeated domains" {
  cat > "${TEST_TMPDIR}/extra-domains.txt" <<'EOF'
.openai.com
EOF

  run merged_agent_allowlist_domains "${TEST_TMPDIR}/extra-domains.txt" "codex"
  assert_success

  count=$(printf '%s\n' "${lines[@]}" | grep -c '^\.openai\.com$')
  [ "$count" -eq 1 ]
}
