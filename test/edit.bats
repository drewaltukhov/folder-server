load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/caddy.sh"
  . "$REPO_ROOT/lib/process.sh"
  . "$REPO_ROOT/lib/commands.sh"
  . "$REPO_ROOT/lib/dashboard.sh"
  fs_ensure_home
  PROJ="$BATS_TEST_TMPDIR/app"
  mkdir -p "$PROJ"
}

@test "edit errors when there is no .folderserver" {
  run fs_cmd_edit "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no .folderserver"* ]]
}

@test "edit errors without an interactive terminal (stdin not a tty in bats)" {
  printf 'domain=app.test\n' >"$PROJ/.folderserver"
  run fs_cmd_edit "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"interactive terminal"* ]]
}

@test "edit dispatches through the real CLI entrypoint" {
  printf 'domain=app.test\n' >"$PROJ/.folderserver"
  run "$FS_BIN" edit "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"interactive terminal"* ]]
}

@test "dash header advertises the edit key" {
  fs_registry_set app.test "$PROJ" 8000 8.4
  run fs_dash_render 0
  [[ "$output" == *"[e]dit"* ]]
}

@test "init non-interactive fallback still writes a minimal config (no db)" {
  install_php_stub 8.4
  mkdir -p "$PROJ/new"
  run fs_cmd_init "$PROJ/new"
  [ "$status" -eq 0 ]
  grep -q '^domain=new.test$' "$PROJ/new/.folderserver"
  grep -q '^php=8.4$' "$PROJ/new/.folderserver"
  run grep -q '^db' "$PROJ/new/.folderserver"
  [ "$status" -ne 0 ]
}
