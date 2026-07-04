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
  # Bonjour name is deterministic in tests.
  stub_scutil test-mac
  # Never touch the real firewall from tests.
  export FS_FIREWALL_BIN="$BATS_TEST_TMPDIR/no-firewall"
  PROJ="$BATS_TEST_TMPDIR/site1"; mkdir -p "$PROJ"
}
teardown() { fs_cmd_down "$PROJ" >/dev/null 2>&1 || true; }

# scutil stub that prints a fixed LocalHostName to stdout.
stub_scutil() {
  local name="$1" dir="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$dir"
  cat >"$dir/scutil" <<EOF
#!/usr/bin/env bash
[ "\$1" = "--get" ] && printf '%s\n' "$name" || exit 1
EOF
  chmod +x "$dir/scutil"; export PATH="$dir:$PATH"
}

# --- config round-trip -------------------------------------------------------

@test "write_config emits lan=on when enabled" {
  fs_write_config "$PROJ" foo.test 8.4 "" "" off "" "" "" php dev "" "" "" "" on
  grep -q '^lan=on$' "$PROJ/.folderserver"
}

@test "write_config omits lan when disabled" {
  fs_write_config "$PROJ" foo.test 8.4 "" "" off "" "" "" php dev "" "" "" "" off
  ! grep -q '^lan=' "$PROJ/.folderserver"
}

@test "load_config reads lan into FS_LAN" {
  printf 'domain=foo.test\nphp=8.4\nlan=on\n' >"$PROJ/.folderserver"
  _fs_load_config "$PROJ"
  [ "$FS_LAN" = on ]
}

# --- Caddy block rendering ---------------------------------------------------

@test "write_lan_site listens on <host>:<port>, proxies backend, rewrites Host" {
  fs_write_lan_site foo.test test-mac.local 8443 51000
  local f="$FS_CADDY_SITES/foo.test.lan.caddy"
  [ -f "$f" ]
  grep -q '^test-mac.local:8443 {' "$f"
  grep -q 'reverse_proxy localhost:51000' "$f"
  grep -q 'header_up Host 127.0.0.1:51000' "$f"
  grep -q "$FS_CERT_DIR/test-mac.local.pem" "$f"
}

@test "write_lan_static_site serves a docroot with file_server" {
  fs_write_lan_static_site foo.test test-mac.local 8444 "$PROJ/dist"
  local f="$FS_CADDY_SITES/foo.test.lan.caddy"
  grep -q '^test-mac.local:8444 {' "$f"
  grep -q "root \* $PROJ/dist" "$f"
  grep -q 'file_server' "$f"
  ! grep -q 'try_files' "$f"
}

@test "write_lan_static_site adds SPA fallback when given" {
  fs_write_lan_static_site foo.test test-mac.local 8444 "$PROJ/dist" index.html
  grep -q 'try_files {path} /index.html' "$FS_CADDY_SITES/foo.test.lan.caddy"
}

@test "remove_site also deletes the .lan.caddy block" {
  fs_write_site foo.test 51000
  fs_write_lan_site foo.test test-mac.local 8443 51000
  [ -f "$FS_CADDY_SITES/foo.test.lan.caddy" ]
  fs_remove_site foo.test
  [ ! -f "$FS_CADDY_SITES/foo.test.caddy" ]
  [ ! -f "$FS_CADDY_SITES/foo.test.lan.caddy" ]
}

# --- per-site LAN port registry ---------------------------------------------

@test "lan_port allocates from the base and persists" {
  run fs_lan_port foo.test
  [ "$output" = "$FS_LAN_PORT_BASE" ]
  grep -q "^foo.test|$FS_LAN_PORT_BASE\$" "$(fs_lan_ports_file)"
}

@test "lan_port is stable for the same domain" {
  local a b; a="$(fs_lan_port foo.test)"; b="$(fs_lan_port foo.test)"
  [ "$a" = "$b" ]
}

@test "lan_port gives distinct ports to distinct sites" {
  local a b; a="$(fs_lan_port foo.test)"; b="$(fs_lan_port bar.test)"
  [ "$a" != "$b" ]
}

@test "lan_port_get returns nothing before assignment" {
  run fs_lan_port_get never.test
  [ -z "$output" ]
}

@test "lan_port_forget drops the assignment" {
  fs_lan_port foo.test >/dev/null
  fs_lan_port_forget foo.test
  run fs_lan_port_get foo.test
  [ -z "$output" ]
}

# --- host + exposure helpers -------------------------------------------------

@test "local_host appends .local to the Bonjour name" {
  run fs_local_host
  [ "$output" = "test-mac.local" ]
}

@test "lan_expose (proxy) writes the block and sets FS_LAN_URL" {
  fs_lan_expose foo.test proxy 51000
  [ -f "$FS_CADDY_SITES/foo.test.lan.caddy" ]
  [[ "$FS_LAN_URL" == "https://test-mac.local:"* ]]
}

@test "lan_expose (static) serves the docroot" {
  fs_lan_expose foo.test static "$PROJ/dist" index.html
  grep -q 'file_server' "$FS_CADDY_SITES/foo.test.lan.caddy"
  grep -q 'try_files {path} /index.html' "$FS_CADDY_SITES/foo.test.lan.caddy"
}

@test "lan_expose skips gracefully when no Bonjour hostname" {
  # scutil that fails -> no hostname
  printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/stubbin/scutil"
  chmod +x "$BATS_TEST_TMPDIR/stubbin/scutil"
  run fs_lan_expose foo.test proxy 51000
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]]
  [ ! -f "$FS_CADDY_SITES/foo.test.lan.caddy" ]
}

# --- integration: fs up honours lan=on --------------------------------------

setup_php_stub() {
  mkdir -p "$FS_BREW_OPT/php@8.4/bin"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$FS_BREW_OPT/php@8.4/bin/php"
  chmod +x "$FS_BREW_OPT/php@8.4/bin/php"
}

@test "up with lan=on publishes the LAN block and prints the network url" {
  setup_php_stub
  printf 'domain=site1.test\nphp=8.4\nlan=on\n' >"$PROJ/.folderserver"
  run fs_cmd_up "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"network: https://test-mac.local:"* ]]
  [ -f "$FS_CADDY_SITES/site1.test.lan.caddy" ]
}

@test "up without lan does not publish a LAN block" {
  setup_php_stub
  printf 'domain=site1.test\nphp=8.4\n' >"$PROJ/.folderserver"
  run fs_cmd_up "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" != *"network:"* ]]
  [ ! -f "$FS_CADDY_SITES/site1.test.lan.caddy" ]
}

@test "lan port stays stable across a restart" {
  setup_php_stub
  printf 'domain=site1.test\nphp=8.4\nlan=on\n' >"$PROJ/.folderserver"
  fs_cmd_up "$PROJ" >/dev/null
  local p1; p1="$(fs_lan_port_get site1.test)"
  fs_cmd_down "$PROJ" >/dev/null
  fs_cmd_up "$PROJ" >/dev/null
  local p2; p2="$(fs_lan_port_get site1.test)"
  [ -n "$p1" ] && [ "$p1" = "$p2" ]
}

@test "down removes the LAN block but keeps the port assignment" {
  setup_php_stub
  printf 'domain=site1.test\nphp=8.4\nlan=on\n' >"$PROJ/.folderserver"
  fs_cmd_up "$PROJ" >/dev/null
  fs_cmd_down "$PROJ" >/dev/null
  [ ! -f "$FS_CADDY_SITES/site1.test.lan.caddy" ]
  run fs_lan_port_get site1.test
  [ -n "$output" ]
}

@test "unbind forgets the LAN port assignment" {
  setup_php_stub
  printf 'domain=site1.test\nphp=8.4\nlan=on\n' >"$PROJ/.folderserver"
  fs_cmd_up "$PROJ" >/dev/null
  fs_unbind_domain site1.test "$PROJ"
  run fs_lan_port_get site1.test
  [ -z "$output" ]
}
