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

@test "serve autodetects a node project and serves its dev server" {
  export FS_NODE_PORT_WAIT=1
  printf '{"scripts":{"dev":"astro dev","build":"astro build"},"dependencies":{"astro":"5"}}\n' \
    >"$PROJ/package.json"
  make_stub npm "$BATS_TEST_TMPDIR/npm.log"
  run fs_cmd_serve "$PROJ"
  [ "$status" -eq 0 ]
  grep -q '^type=node$' "$PROJ/.folderserver"
  grep -q '^mode=dev$' "$PROJ/.folderserver"
  grep -q '^command=npm run dev$' "$PROJ/.folderserver"
  grep -q '^port=4321$' "$PROJ/.folderserver"
  grep -q '^install=on$' "$PROJ/.folderserver"
  run grep -q '^php=' "$PROJ/.folderserver"; [ "$status" -ne 0 ]
  # deps were missing, so install=on ran the package manager …
  grep -q 'install' "$BATS_TEST_TMPDIR/npm.log"
  # … and the dev command was started, then the browser opened
  grep -q 'run dev' "$BATS_TEST_TMPDIR/npm.log"
  grep -q "https://my-site.test" "$BATS_TEST_TMPDIR/open.log"
}

@test "serve picks php over node for a mixed php+node project" {
  printf '{"scripts":{"dev":"vite"}}\n' >"$PROJ/package.json"
  : >"$PROJ/composer.json"
  : >"$PROJ/artisan"
  run fs_cmd_serve "$PROJ"
  [ "$status" -eq 0 ]
  grep -q '^php=8.4$' "$PROJ/.folderserver"
  run grep -q '^type=node$' "$PROJ/.folderserver"; [ "$status" -ne 0 ]
}

@test "serve refuses a node project when the package manager isn't installed" {
  printf '{"scripts":{"dev":"astro dev"}}\n' >"$PROJ/package.json"
  # a PATH with the usual text utilities but no package manager, so detection
  # still works and only the "is npm installed" check fails
  local minbin="$BATS_TEST_TMPDIR/minbin" u
  mkdir -p "$minbin"
  for u in tr grep sed cat head; do ln -sf "$(command -v "$u")" "$minbin/$u"; done
  PATH="$minbin" run fs_cmd_serve "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"npm"* ]]
  [ ! -f "$PROJ/.folderserver" ]   # nothing written
}

@test "serve reuses an existing .folderserver (doesn't overwrite)" {
  printf 'domain=custom.test\nphp=8.4\n' >"$PROJ/.folderserver"
  run fs_cmd_serve "$PROJ"
  [ "$status" -eq 0 ]
  grep -q '^domain=custom.test$' "$PROJ/.folderserver"   # untouched
  grep -q "https://custom.test" "$BATS_TEST_TMPDIR/open.log"
  fs_stop_proc custom.test >/dev/null 2>&1 || true
}
