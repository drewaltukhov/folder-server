load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/caddy.sh"
  . "$REPO_ROOT/lib/process.sh"
  . "$REPO_ROOT/lib/commands.sh"
  fs_ensure_home
  make_stub caddy "$BATS_TEST_TMPDIR/caddy.log"
  export FS_CADDY_BIN=caddy
  export FS_CADDY_CONFIG="$BATS_TEST_TMPDIR/Caddyfile"
  PROJ="$BATS_TEST_TMPDIR/app"
  mkdir -p "$PROJ"
}
teardown() {
  [ -n "${PROJ:-}" ] && fs_cmd_down "$PROJ" >/dev/null 2>&1 || true
}

# Fake php that records its argv then stays alive (so fs_is_running is true).
_fake_php() {
  mkdir -p "$FS_BREW_OPT/php@8.4/bin"
  cat >"$FS_BREW_OPT/php@8.4/bin/php" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$BATS_TEST_TMPDIR/php-argv.log"
exec sleep 30
EOF
  chmod +x "$FS_BREW_OPT/php@8.4/bin/php"
}

@test "resolve_config omits rewrite value when unset, includes it when set" {
  run fs_resolve_config "$PROJ"
  [[ "$output" == *"rewrite="* ]]
  printf 'rewrite=index.php\n' >"$PROJ/.folderserver"
  run fs_resolve_config "$PROJ"
  [[ "$output" == *"rewrite=index.php"* ]]
}

@test "_fs_load_config sets FS_REWRITE" {
  printf 'domain=app.test\nrewrite=index.php\n' >"$PROJ/.folderserver"
  _fs_load_config "$PROJ"
  [ "$FS_REWRITE" = "index.php" ]
}

@test "fs_router_render substitutes the front controller" {
  run fs_router_render index.php
  [[ "$output" == *"require \$root . '/index.php';"* ]]
  [[ "$output" == *"return false;"* ]]
}

@test "fs_write_router writes a router file for the domain" {
  fs_write_router app.test index.php
  [ -f "$(fs_router_file app.test)" ]
  grep -q "require \$root . '/index.php';" "$(fs_router_file app.test)"
}

@test "up with rewrite generates a router and passes it to php" {
  _fake_php
  printf 'domain=app.test\nrewrite=index.php\n' >"$PROJ/.folderserver"
  run fs_cmd_up "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rewrite → index.php"* ]]
  [ -f "$(fs_router_file app.test)" ]
  grep -q "router.php" "$BATS_TEST_TMPDIR/php-argv.log"
}

@test "up without rewrite does not pass a router" {
  _fake_php
  printf 'domain=app.test\n' >"$PROJ/.folderserver"
  run fs_cmd_up "$PROJ"
  [ "$status" -eq 0 ]
  [ ! -f "$(fs_router_file app.test)" ]
  run grep -q "router.php" "$BATS_TEST_TMPDIR/php-argv.log"
  [ "$status" -ne 0 ]
}

@test "down removes the router file" {
  _fake_php
  printf 'domain=app.test\nrewrite=index.php\n' >"$PROJ/.folderserver"
  fs_cmd_up "$PROJ" >/dev/null
  [ -f "$(fs_router_file app.test)" ]
  fs_cmd_down "$PROJ"
  [ ! -f "$(fs_router_file app.test)" ]
}

@test "up rejects an unsafe rewrite value" {
  _fake_php
  printf 'domain=app.test\nrewrite=../../etc/passwd\n' >"$PROJ/.folderserver"
  run fs_cmd_up "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid rewrite"* ]]
}

@test "integration: real php -S serves static files directly and routes the rest to the front controller" {
  local php
  php="$(command -v php || true)"
  [ -n "$php" ] || skip "no real php on PATH"
  command -v curl >/dev/null 2>&1 || skip "no curl"

  local root="$BATS_TEST_TMPDIR/docroot"
  mkdir -p "$root"
  printf 'STATIC-OK' >"$root/asset.txt"
  printf '<?php echo "ROUTED:" . parse_url($_SERVER["REQUEST_URI"], PHP_URL_PATH);' >"$root/index.php"
  fs_write_router int.test index.php
  local router
  router="$(fs_router_file int.test)"

  local port=8767
  "$php" -S "127.0.0.1:$port" -t "$root" "$router" >/dev/null 2>&1 &
  local pid=$!

  # wait until the server answers (bounded)
  local i=0
  while [ "$i" -lt 40 ]; do
    if curl -s "http://127.0.0.1:$port/asset.txt" >/dev/null 2>&1; then break; fi
    i=$((i+1)); sleep 0.1
  done

  local static routed
  static="$(curl -s "http://127.0.0.1:$port/asset.txt")"
  routed="$(curl -s "http://127.0.0.1:$port/pretty/url/here")"
  kill "$pid" >/dev/null 2>&1 || true

  [ "$static" = "STATIC-OK" ]
  [ "$routed" = "ROUTED:/pretty/url/here" ]
}
