#!/usr/bin/env bats
load '../test_helper/common'

@test "runtime_prereqs_for_agents: codex requires bubblewrap in addition to node" {
  run runtime_prereqs_for_agents "codex"

  assert_success
  assert_output "node,bubblewrap"
}

@test "base stack installs bubblewrap for codex sandboxing" {
  run rg -n "bubblewrap" "${PROJECT_ROOT}/stacks/base.sh"

  assert_success
  assert_output --partial "bubblewrap"
}
