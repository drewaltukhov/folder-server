load test_helper
setup() { setup_common; }

@test "symlink: lib functions load when entrypoint is a symlink" {
  ln -s "$FS_BIN" "$BATS_TEST_TMPDIR/fs"
  run "$BATS_TEST_TMPDIR/fs" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOMAIN"* ]]
}
