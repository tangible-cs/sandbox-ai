#!/usr/bin/env bats
load '../test_helper/common'

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "cli_config_path: resolves known agent config" {
  run cli_config_path "claude"
  assert_success
  assert_output "${PROJECT_ROOT}/agents/claude.conf"
}

@test "cli_config_path: fails for unknown agent" {
  run cli_config_path "unknown-agent"
  assert_failure
  assert_output --partial "Unknown agent"
}

@test "list_agent_ids: lists known agents" {
  run list_agent_ids
  assert_success
  assert_line "claude"
  assert_line "codex"
}

@test "load_cli_config: loads required fields for claude" {
  run bash -lc '
    set -euo pipefail
    PROJECT_ROOT="'"${PROJECT_ROOT}"'"
    SCRIPT_DIR="${PROJECT_ROOT}/bin"
    source "${PROJECT_ROOT}/lib/sandbox-common.sh"
    load_cli_config claude
    printf "%s|%s|%s|%s|%s\n" \
      "${CLI_ID}" "${CLI_BINARY_NAME}" "${CLI_INSTALL_STRATEGY}" "${CLI_REQUIRES_NODE}" "${CLI_ALLOWLIST_FILE}"
  '
  assert_success
  assert_output "claude|claude|script|no|${PROJECT_ROOT}/domains/anthropic-default.txt"
}

@test "validate_cli_config_file: fails when a required field is missing" {
  cat > "${TEST_TMPDIR}/broken.conf" <<'EOF'
CLI_ID="broken"
CLI_DISPLAY_NAME="Broken"
CLI_BINARY_NAME="broken"
EOF

  run validate_cli_config_file "${TEST_TMPDIR}/broken.conf"
  assert_failure
  assert_output --partial "missing required field"
}

@test "validate_cli_config_file: accepts a complete config" {
  cat > "${TEST_TMPDIR}/ok.conf" <<'EOF'
CLI_ID="ok"
CLI_DISPLAY_NAME="Okay"
CLI_BINARY_NAME="ok"
CLI_INSTALL_STRATEGY="custom"
CLI_INSTALL_REF="ok-installer"
CLI_INSTALL_COMMAND="install ok"
CLI_INSTALL_USER="root"
CLI_LAUNCH_COMMAND="ok"
CLI_VERSION_CHECK_COMMAND="ok --version"
CLI_AUTH_STRATEGY="either"
CLI_AUTH_COMMAND="ok login"
CLI_AUTH_CHECK_COMMAND="test -d ~/.ok"
CLI_ALLOWLIST_FILE=""
CLI_REQUIRES_NODE="no"
CLI_REQUIRES_PYTHON="no"
CLI_REQUIRES_UV_OR_PIPX="no"
CLI_RUNTIME_PREREQS=""
CLI_CACHE_STRATEGY="none"
CLI_CACHE_KEY="ok"
CLI_SESSION_HOME_SUBDIR=".ok"
CLI_STATUS_LABEL="OK"
CLI_PATH_LINK_SOURCE=""
CLI_PATH_LINK_TARGET=""
CLI_DEFAULT_FLAGS=""
EOF

  run validate_cli_config_file "${TEST_TMPDIR}/ok.conf"
  assert_success
}

@test "validate_cli_config_file: rejects unknown fields without executing them" {
  local canary_path="${TEST_TMPDIR}/config-canary"

  cat > "${TEST_TMPDIR}/malicious.conf" <<EOF
CLI_ID="malicious"
CLI_DISPLAY_NAME="Malicious"
CLI_BINARY_NAME="malicious"
CLI_INSTALL_STRATEGY="custom"
CLI_INSTALL_REF="ref"
CLI_INSTALL_COMMAND="install"
CLI_INSTALL_USER="root"
CLI_LAUNCH_COMMAND="malicious"
CLI_VERSION_CHECK_COMMAND="malicious --version"
CLI_AUTH_STRATEGY="either"
CLI_AUTH_COMMAND="malicious login"
CLI_AUTH_CHECK_COMMAND="test -d ~/.malicious"
CLI_ALLOWLIST_FILE=""
CLI_REQUIRES_NODE="no"
CLI_REQUIRES_PYTHON="no"
CLI_REQUIRES_UV_OR_PIPX="no"
CLI_RUNTIME_PREREQS=""
CLI_CACHE_STRATEGY="none"
CLI_CACHE_KEY="malicious"
CLI_SESSION_HOME_SUBDIR=".malicious"
CLI_STATUS_LABEL="MAL"
CLI_PATH_LINK_SOURCE=""
CLI_PATH_LINK_TARGET=""
CLI_DEFAULT_FLAGS=""
MAL="\$(touch ${canary_path})"
EOF

  run validate_cli_config_file "${TEST_TMPDIR}/malicious.conf"
  assert_failure
  assert_output --partial "unknown field 'MAL'"
  [ ! -e "${canary_path}" ]
}
