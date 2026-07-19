load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/caddy.sh"
  . "$REPO_ROOT/lib/process.sh"
  . "$REPO_ROOT/lib/commands.sh"
  . "$REPO_ROOT/lib/dashboard.sh"
  fs_ensure_home
  make_stub caddy "$BATS_TEST_TMPDIR/caddy.log"
  export FS_CADDY_BIN=caddy
  export FS_CADDY_CONFIG="$BATS_TEST_TMPDIR/Caddyfile"
  PROJ="$BATS_TEST_TMPDIR/app"
  mkdir -p "$PROJ"
  printf 'domain=app.test\n' >"$PROJ/.folderserver"
  # a fake, long-lived php so the site counts as running
  mkdir -p "$FS_BREW_OPT/php@8.4/bin"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$FS_BREW_OPT/php@8.4/bin/php"
  chmod +x "$FS_BREW_OPT/php@8.4/bin/php"
}
teardown() { fs_stop_php app.test >/dev/null 2>&1 || true; }

@test "fs_unbind_domain stops the site, deletes .folderserver, and forgets it" {
  fs_cmd_up "$PROJ" >/dev/null
  fs_is_running app.test
  fs_registry_get app.test
  [ -f "$PROJ/.folderserver" ]

  fs_unbind_domain app.test

  run fs_is_running app.test
  [ "$status" -ne 0 ]
  run fs_registry_get app.test
  [ "$status" -ne 0 ]
  [ ! -f "$PROJ/.folderserver" ]
  [ ! -f "$FS_CADDY_SITES/app.test.caddy" ]
}

@test "fs_unbind_domain deletes the per-site cert and logfile" {
  fs_cmd_up "$PROJ" >/dev/null
  # seed a cert + log the way fs_up/fs_ensure_site_cert would
  { read -r cert; read -r key; } < <(fs_cert_paths app.test)
  : >"$cert"; : >"$key"
  : >"$(fs_logfile app.test)"
  [ -f "$cert" ] && [ -f "$key" ] && [ -f "$(fs_logfile app.test)" ]

  fs_unbind_domain app.test

  [ ! -f "$cert" ]
  [ ! -f "$key" ]
  [ ! -f "$(fs_logfile app.test)" ]
}

@test "fs_unbind_domain on a stopped, never-started site is a clean no-op-ish" {
  fs_registry_set app.test "$PROJ" 8000 8.4
  fs_unbind_domain app.test
  run fs_registry_get app.test
  [ "$status" -ne 0 ]
  [ ! -f "$PROJ/.folderserver" ]
}

@test "dash action u unbinds the selected domain" {
  fs_cmd_up "$PROJ" >/dev/null
  run fs_dash_action u app.test
  [ "$status" -eq 0 ]
  [ "$output" = "unbind" ]
  run fs_registry_get app.test
  [ "$status" -ne 0 ]
  [ ! -f "$PROJ/.folderserver" ]
}

@test "dash header advertises the unbind key" {
  fs_registry_set app.test "$PROJ" 8000 8.4
  run fs_dash_render 0
  [[ "$output" == *"[u]nbind"* ]]
}

@test "fs_cmd_unbind stops the site and deletes its config" {
  fs_cmd_up "$PROJ" >/dev/null
  run fs_cmd_unbind "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unbound app.test"* ]]
  run fs_is_running app.test
  [ "$status" -ne 0 ]
  run fs_registry_get app.test
  [ "$status" -ne 0 ]
  [ ! -f "$PROJ/.folderserver" ]
}

@test "fs_cmd_unbind works on a never-started folder (dir known without registry)" {
  # never up'd: no registry entry, but the CLI knows the dir directly
  run fs_cmd_unbind "$PROJ"
  [ "$status" -eq 0 ]
  [ ! -f "$PROJ/.folderserver" ]
}

@test "unbind --all --yes forgets every site" {
  A="$BATS_TEST_TMPDIR/a"; B="$BATS_TEST_TMPDIR/b"; mkdir -p "$A" "$B"
  printf 'domain=a.test\n' >"$A/.folderserver"
  printf 'domain=b.test\n' >"$B/.folderserver"
  fs_registry_set a.test "$A" 8000 "php 8.4"
  fs_registry_set b.test "$B" 8001 "php 8.4"
  run fs_cmd_unbind --all --yes
  [ "$status" -eq 0 ]
  run fs_registry_get a.test; [ "$status" -ne 0 ]
  run fs_registry_get b.test; [ "$status" -ne 0 ]
  [ ! -f "$A/.folderserver" ]
  [ ! -f "$B/.folderserver" ]
}

@test "unbind --all without --yes aborts non-interactively (nothing removed)" {
  A="$BATS_TEST_TMPDIR/a"; mkdir -p "$A"; printf 'domain=a.test\n' >"$A/.folderserver"
  fs_registry_set a.test "$A" 8000 "php 8.4"
  run fs_cmd_unbind --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted"* ]]
  fs_registry_get a.test            # still registered
  [ -f "$A/.folderserver" ]         # config intact
}

@test "unbind --all on an empty registry is a clean no-op" {
  run fs_cmd_unbind --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sites to unbind"* ]]
}

@test "unbind dispatches through the real CLI entrypoint" {
  fs_cmd_up "$PROJ" >/dev/null
  run "$FS_BIN" unbind "$PROJ"
  [ "$status" -eq 0 ]
  [ ! -f "$PROJ/.folderserver" ]
  run fs_registry_get app.test
  [ "$status" -ne 0 ]
}
