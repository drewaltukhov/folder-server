load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/process.sh"
  . "$REPO_ROOT/lib/dashboard.sh"
  fs_ensure_home
}

@test "fs_dash_logs prints the selected site's log when not a tty" {
  printf 'GET /dbtest.php 200\n' >"$(fs_logfile app.test)"
  run fs_dash_logs app.test
  [ "$status" -eq 0 ]
  [[ "$output" == *"GET /dbtest.php 200"* ]]
}

@test "fs_dash_logs reports when no log exists yet" {
  run fs_dash_logs ghost.test
  [ "$status" -eq 0 ]
  [[ "$output" == *"no log yet"* ]]
}
