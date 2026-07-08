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

# Simulate the interactive editor non-interactively: force the gum path on and
# feed a config where the domain has been changed to new.test.
_stub_edit_to_new_domain() {
  _fs_have_gum_tty() { return 0; }
  _fs_prompt_config() {
    NC_DOMAIN=new.test NC_PHP=8.4 NC_DOCROOT="" NC_REWRITE=""
    NC_DB=off NC_DB_NAME="" NC_DB_USER="" NC_DB_PASS=""
    NC_TYPE=static NC_MODE=dev NC_COMMAND="" NC_BUILD="" NC_PORT="" NC_INSTALL="" NC_LAN=off
  }
}

@test "edit that changes a running site's domain replaces the row, not duplicates it" {
  printf 'domain=old.test\ntype=static\n' >"$PROJ/.folderserver"
  fs_registry_set old.test "$PROJ" 8000 static
  _stub_edit_to_new_domain
  # pretend the site is running so the restart path runs; stub its side effects.
  fs_is_running() { return 0; }
  fs_stop_php() { :; }
  fs_remove_router() { :; }
  fs_remove_site() { :; }
  fs_caddy_reload() { :; }
  # a real `fs up` registers the (now-new) domain — emulate just that.
  fs_cmd_up() { fs_registry_set new.test "$PROJ" 8000 static; }

  run fs_cmd_edit "$PROJ"
  [ "$status" -eq 0 ]
  run fs_registry_domains
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  [ "$output" = "new.test" ]
}

@test "edit that changes a stopped site's domain re-registers under the new domain" {
  printf 'domain=old.test\ntype=static\n' >"$PROJ/.folderserver"
  fs_registry_set old.test "$PROJ" "" static
  _stub_edit_to_new_domain
  fs_is_running() { return 1; }

  run fs_cmd_edit "$PROJ"
  [ "$status" -eq 0 ]
  run fs_registry_field new.test 2; [ "$output" = "$PROJ" ]
  run fs_registry_field old.test 2; [ "$status" -ne 0 ]
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
