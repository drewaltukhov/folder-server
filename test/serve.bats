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
  mkdir -p "$FS_BREW_OPT/php@8.4/bin"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$FS_BREW_OPT/php@8.4/bin/php"
  chmod +x "$FS_BREW_OPT/php@8.4/bin/php"
  PROJ="$BATS_TEST_TMPDIR/My-Site"; mkdir -p "$PROJ"
}
teardown() { fs_stop_proc my-site.test >/dev/null 2>&1 || true; }

@test "fs_pick_php returns an installed version" {
  [ "$(fs_pick_php)" = 8.4 ]
}

@test "serve creates a default php config, serves, and opens the browser" {
  run fs_cmd_serve "$PROJ"
  [ "$status" -eq 0 ]
  # wrote a minimal PHP config (no node, no db, no rewrite)
  grep -q '^domain=my-site.test$' "$PROJ/.folderserver"
  grep -q '^php=8.4$' "$PROJ/.folderserver"
  run grep -qE '^(type=node|db=|rewrite=)' "$PROJ/.folderserver"; [ "$status" -ne 0 ]
  # it's serving
  fs_is_running my-site.test
  # and it opened the browser at the site URL
  grep -q "https://my-site.test" "$BATS_TEST_TMPDIR/open.log"
}

@test "serve reuses an existing .folderserver (doesn't overwrite)" {
  printf 'domain=custom.test\nphp=8.4\n' >"$PROJ/.folderserver"
  run fs_cmd_serve "$PROJ"
  [ "$status" -eq 0 ]
  grep -q '^domain=custom.test$' "$PROJ/.folderserver"   # untouched
  grep -q "https://custom.test" "$BATS_TEST_TMPDIR/open.log"
  fs_stop_proc custom.test >/dev/null 2>&1 || true
}
