load test_helper
setup() {
  setup_common
  for l in helpers commands; do . "$REPO_ROOT/lib/$l.sh"; done
  make_stub brew "$BATS_TEST_TMPDIR/brew.log"; export FS_BREW_BIN=brew
  export FS_MYSQL_FORMULA=mysql
}

@test "db start runs brew services start mysql" {
  run fs_cmd_db start
  [ "$status" -eq 0 ]
  grep -q "services start mysql" "$BATS_TEST_TMPDIR/brew.log"
}

@test "db stop runs brew services stop mysql" {
  run fs_cmd_db stop
  grep -q "services stop mysql" "$BATS_TEST_TMPDIR/brew.log"
}

@test "db status maps to brew services list" {
  run fs_cmd_db status
  grep -q "services list" "$BATS_TEST_TMPDIR/brew.log"
}

@test "db with bad action errors" {
  run fs_cmd_db frobnicate
  [ "$status" -eq 2 ]
}
