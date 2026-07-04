load test_helper
setup() { setup_common; . "$REPO_ROOT/lib/helpers.sh"; . "$REPO_ROOT/lib/process.sh"; fs_ensure_home; }

@test "is_running false when no pidfile" {
  run fs_is_running ghost.test
  [ "$status" -ne 0 ]
}

@test "start then is_running true, then stop then false" {
  # Use `sleep` as a stand-in long-running process via a fake php binary.
  local fake="$BATS_TEST_TMPDIR/php"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
exec sleep 30
EOF
  chmod +x "$fake"
  fs_start_php demo.test "$fake" 8123 "$BATS_TEST_TMPDIR"
  run fs_is_running demo.test
  [ "$status" -eq 0 ]
  [ -f "$(fs_pidfile demo.test)" ]
  fs_stop_php demo.test
  run fs_is_running demo.test
  [ "$status" -ne 0 ]
  [ ! -f "$(fs_pidfile demo.test)" ]
}

@test "start refuses if already running" {
  local fake="$BATS_TEST_TMPDIR/php"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$fake"; chmod +x "$fake"
  fs_start_php dup.test "$fake" 8124 "$BATS_TEST_TMPDIR"
  run fs_start_php dup.test "$fake" 8124 "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  fs_stop_php dup.test
}
