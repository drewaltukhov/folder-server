load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/caddy.sh"
  . "$REPO_ROOT/lib/process.sh"
  . "$REPO_ROOT/lib/commands.sh"
  fs_ensure_home
  make_stub caddy "$BATS_TEST_TMPDIR/caddy.log"; export FS_CADDY_BIN=caddy
  export FS_CADDY_CONFIG="$BATS_TEST_TMPDIR/Caddyfile"
  make_stub open "$BATS_TEST_TMPDIR/open.log"; export FS_OPEN_BIN=open
  PROJ="$BATS_TEST_TMPDIR/site1"; mkdir -p "$PROJ"
  printf '<h1>hi</h1>\n' >"$PROJ/index.html"
}
teardown() { fs_cmd_down "$PROJ" >/dev/null 2>&1 || true; }

@test "fs_have_php is false with no php installed, true once one exists" {
  run fs_have_php; [ "$status" -ne 0 ]
  install_php_stub 8.4
  run fs_have_php; [ "$status" -eq 0 ]
}

@test "fs_write_config emits a clean static config" {
  fs_write_config "$PROJ" static-site.test "" "" "" off "" "" "" static dev "" "" "" "" off
  grep -q "^type=static$" "$PROJ/.folderserver"
  # no php/command/build/rewrite noise
  run grep -qE '^(php=|command=|build=|rewrite=|mode=)' "$PROJ/.folderserver"
  [ "$status" -ne 0 ]
}

@test "fs_write_config keeps an explicit docroot for static" {
  fs_write_config "$PROJ" static-site.test "" public "" off "" "" "" static dev "" "" "" "" off
  grep -q "^type=static$" "$PROJ/.folderserver"
  grep -q "^docroot=public$" "$PROJ/.folderserver"
}

@test "up serves a static site with no php process and no php binary" {
  printf 'domain=site1.test\ntype=static\n' >"$PROJ/.folderserver"
  run fs_cmd_up "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://site1.test"* ]]
  [[ "$output" == *"static"* ]]
  # a static site has no backend process
  run fs_is_running site1.test; [ "$status" -ne 0 ]
  # caddy snippet is a file_server rooted at the folder, not a reverse_proxy
  [ -f "$FS_CADDY_SITES/site1.test.caddy" ]
  grep -q "file_server" "$FS_CADDY_SITES/site1.test.caddy"
  grep -q "root \* $PROJ" "$FS_CADDY_SITES/site1.test.caddy"
  run grep -q "reverse_proxy" "$FS_CADDY_SITES/site1.test.caddy"; [ "$status" -ne 0 ]
  grep -q "reload" "$BATS_TEST_TMPDIR/caddy.log"
}

@test "down removes a static site's snippet" {
  printf 'domain=site1.test\ntype=static\n' >"$PROJ/.folderserver"
  fs_cmd_up "$PROJ" >/dev/null
  fs_cmd_down "$PROJ"
  [ ! -f "$FS_CADDY_SITES/site1.test.caddy" ]
}

@test "serve defaults to a static config when no php is installed" {
  run fs_cmd_serve "$PROJ"
  [ "$status" -eq 0 ]
  grep -q "^type=static$" "$PROJ/.folderserver"
  run grep -qE '^(php=|type=node)' "$PROJ/.folderserver"; [ "$status" -ne 0 ]
  grep -q "https://site1.test" "$BATS_TEST_TMPDIR/open.log"
}

@test "serve prefers php when php is installed" {
  install_php_stub 8.4
  run fs_cmd_serve "$PROJ"
  [ "$status" -eq 0 ]
  grep -q "^php=8.4$" "$PROJ/.folderserver"
  run grep -q "^type=static$" "$PROJ/.folderserver"; [ "$status" -ne 0 ]
}
