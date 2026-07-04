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

@test "fs_start_command detaches stdin (Vite-style dev servers don't crash with read EIO)" {
  # The launched command copies whatever it receives on stdin to a file. We pipe
  # content into fs_start_command; with stdin redirected from /dev/null the
  # command must see EOF (empty capture) — proving it never inherits the
  # caller's stdin/terminal, which is what causes the EIO crash otherwise.
  # tee copies stdin to the file (as an argument — no shell redirection, which
  # `exec $cmd` wouldn't re-parse). BATS_TEST_TMPDIR has no spaces.
  local out="$BATS_TEST_TMPDIR/captured-stdin"
  printf 'LEAKED\n' | fs_start_command stdin.test "$BATS_TEST_TMPDIR" 8199 "tee $out"
  local pid; pid="$(cat "$(fs_pidfile stdin.test)")"
  local i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  [ -f "$out" ]
  run cat "$out"
  [ -z "$output" ]
  fs_stop_proc stdin.test >/dev/null 2>&1 || true
}

@test "start refuses if already running" {
  local fake="$BATS_TEST_TMPDIR/php"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$fake"; chmod +x "$fake"
  fs_start_php dup.test "$fake" 8124 "$BATS_TEST_TMPDIR"
  run fs_start_php dup.test "$fake" 8124 "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  fs_stop_php dup.test
}
