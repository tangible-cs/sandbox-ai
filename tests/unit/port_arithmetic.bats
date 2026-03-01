#!/usr/bin/env bats
load '../test_helper/common'

@test "ssh_port: slot 1 returns 2201" {
  run ssh_port 1
  assert_success
  assert_output "2201"
}

@test "ssh_port: slot 99 returns 2299" {
  run ssh_port 99
  assert_success
  assert_output "2299"
}

@test "app_port: slot 1 returns 8001" {
  run app_port 1
  assert_success
  assert_output "8001"
}

@test "app_port: slot 50 returns 8050" {
  run app_port 50
  assert_success
  assert_output "8050"
}

@test "alt_port: slot 1 returns 9001" {
  run alt_port 1
  assert_success
  assert_output "9001"
}

@test "alt_port: slot 99 returns 9099" {
  run alt_port 99
  assert_success
  assert_output "9099"
}

@test "exposed_host_port: port 5432 slot 3 returns 5435" {
  run exposed_host_port 5432 3
  assert_success
  assert_output "5435"
}

@test "exposed_host_port: port 5432 slot 7 returns 5439" {
  run exposed_host_port 5432 7
  assert_success
  assert_output "5439"
}

@test "exposed_host_port: port 3000 slot 1 returns 3001" {
  run exposed_host_port 3000 1
  assert_success
  assert_output "3001"
}

@test "exposed_host_port: port 80 slot 50 returns 130" {
  run exposed_host_port 80 50
  assert_success
  assert_output "130"
}

@test "exposed_host_port: port 443 slot 99 returns 542" {
  run exposed_host_port 443 99
  assert_success
  assert_output "542"
}
