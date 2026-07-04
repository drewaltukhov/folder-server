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
  mkdir -p "$FS_BREW_OPT/php@8.4/bin"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$FS_BREW_OPT/php@8.4/bin/php"
  chmod +x "$FS_BREW_OPT/php@8.4/bin/php"
  A="$BATS_TEST_TMPDIR/site-a"; B="$BATS_TEST_TMPDIR/site-b"
  mkdir -p "$A" "$B"
  printf 'domain=a.test\n' >"$A/.folderserver"
  printf 'domain=b.test\n' >"$B/.folderserver"
}
teardown() { fs_stop_php a.test >/dev/null 2>&1 || true; fs_stop_php b.test >/dev/null 2>&1 || true; }

@test "up --all starts every known site" {
  # register both by bringing them up once (they land in the registry)
  fs_cmd_up "$A" >/dev/null
  fs_cmd_up "$B" >/dev/null
  fs_cmd_down "$A" >/dev/null
  fs_cmd_down "$B" >/dev/null
  run fs_is_running a.test; [ "$status" -ne 0 ]

  fs_cmd_up --all >/dev/null
  fs_is_running a.test
  fs_is_running b.test
}

@test "down --all stops every running site" {
  fs_cmd_up "$A" >/dev/null
  fs_cmd_up "$B" >/dev/null
  fs_is_running a.test
  fs_is_running b.test

  fs_cmd_down --all >/dev/null
  run fs_is_running a.test; [ "$status" -ne 0 ]
  run fs_is_running b.test; [ "$status" -ne 0 ]
}

@test "restart --all cycles every known site (new PIDs, still running)" {
  fs_cmd_up "$A" >/dev/null
  fs_cmd_up "$B" >/dev/null
  local oldA oldB
  oldA="$(cat "$(fs_pidfile a.test)")"; oldB="$(cat "$(fs_pidfile b.test)")"

  fs_cmd_restart --all >/dev/null
  fs_is_running a.test
  fs_is_running b.test
  [ "$(cat "$(fs_pidfile a.test)")" != "$oldA" ]
  [ "$(cat "$(fs_pidfile b.test)")" != "$oldB" ]
}

@test "up --all on an empty registry reports no sites (does not error)" {
  run fs_cmd_up --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"no known sites"* ]]
}
