load test_helper
setup() { setup_common; }

@test "no args prints usage and exits non-zero" {
  run "$FS_BIN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: fs"* ]]
}

@test "help subcommand prints usage and exits zero" {
  run "$FS_BIN" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: fs"* ]]
}

@test "unknown subcommand errors" {
  run "$FS_BIN" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command: bogus"* ]]
}
