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
  # Fake php binary that stays alive.
  mkdir -p "$FS_BREW_OPT/php@8.4/bin"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$FS_BREW_OPT/php@8.4/bin/php"
  chmod +x "$FS_BREW_OPT/php@8.4/bin/php"
  PROJ="$BATS_TEST_TMPDIR/site1"; mkdir -p "$PROJ"
}
teardown() { fs_cmd_down "$PROJ" >/dev/null 2>&1 || true; }

@test "up starts php, writes caddy snippet, registers, prints url" {
  run fs_cmd_up "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://site1.test"* ]]
  fs_is_running site1.test
  [ -f "$FS_CADDY_SITES/site1.test.caddy" ]
  run fs_registry_get site1.test
  [ "$status" -eq 0 ]
  grep -q "reload" "$BATS_TEST_TMPDIR/caddy.log"
}

@test "down stops php and removes snippet but keeps registry" {
  fs_cmd_up "$PROJ" >/dev/null
  fs_cmd_down "$PROJ"
  run fs_is_running site1.test
  [ "$status" -ne 0 ]
  [ ! -f "$FS_CADDY_SITES/site1.test.caddy" ]
  run fs_registry_get site1.test
  [ "$status" -eq 0 ]
}

@test "up reuses the stored port on a second up" {
  fs_cmd_up "$PROJ" >/dev/null
  local p1; p1="$(fs_registry_field site1.test 3)"
  fs_cmd_down "$PROJ"
  fs_cmd_up "$PROJ" >/dev/null
  local p2; p2="$(fs_registry_field site1.test 3)"
  [ "$p1" = "$p2" ]
}
