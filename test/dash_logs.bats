load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/process.sh"
  . "$REPO_ROOT/lib/dashboard.sh"
  fs_ensure_home
  # stub pager: ignore flags, print any file argument (stands in for `less +F`)
  cat >"$BATS_TEST_TMPDIR/pager" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ -f "$a" ] && cat "$a"; done
EOF
  chmod +x "$BATS_TEST_TMPDIR/pager"
  export FS_PAGER="$BATS_TEST_TMPDIR/pager"
}

@test "fs_dash_logs pages the selected site's log file" {
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
