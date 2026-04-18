#!/usr/bin/env bats
load '../test_helper/common'

@test "user-facing CLIs: --help prints usage and examples" {
  local script
  local path
  for script in \
    sandbox \
    sandbox-start \
    sandbox-stop \
    sandbox-list \
    sandbox-expose \
    sandbox-setup \
    sandbox-linux-prereqs \
    sandbox-nuke
  do
    path="${PROJECT_ROOT}/bin/${script}"
    run "$path" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "Examples:"
  done
}

@test "user-facing CLIs: unknown flags point users to --help" {
  local script
  local path
  for script in \
    sandbox \
    sandbox-start \
    sandbox-stop \
    sandbox-list \
    sandbox-expose \
    sandbox-setup \
    sandbox-linux-prereqs \
    sandbox-nuke
  do
    path="${PROJECT_ROOT}/bin/${script}"
    run "$path" --definitely-invalid
    assert_failure
    assert_output --partial "Try '${script} --help'"
  done
}
