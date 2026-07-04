load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/caddy.sh"
  export FS_CADDY_CONFIG="$BATS_TEST_TMPDIR/Caddyfile"
}

@test "fs_cert_paths are per-site (exact hostname, not a wildcard)" {
  run fs_cert_paths foo.test
  [[ "$output" == *"$FS_CERT_DIR/foo.test.pem"* ]]
  [[ "$output" == *"$FS_CERT_DIR/foo.test-key.pem"* ]]
  [[ "$output" != *"_wildcard"* ]]
}

@test "render substitutes domain, port and the per-site cert path" {
  run fs_render_site foo.test 8000
  [[ "$output" == *"foo.test {"* ]]
  [[ "$output" == *"reverse_proxy 127.0.0.1:8000"* ]]
  [[ "$output" == *"$FS_CERT_DIR/foo.test.pem"* ]]
}

@test "write_site creates a file, remove_site deletes it" {
  fs_write_site bar.test 8001
  [ -f "$FS_CADDY_SITES/bar.test.caddy" ]
  grep -q "127.0.0.1:8001" "$FS_CADDY_SITES/bar.test.caddy"
  fs_remove_site bar.test
  [ ! -f "$FS_CADDY_SITES/bar.test.caddy" ]
}

@test "caddy_reload invokes the caddy binary with reload" {
  make_stub caddy "$BATS_TEST_TMPDIR/caddy.log"
  export FS_CADDY_BIN=caddy
  run fs_caddy_reload
  [ "$status" -eq 0 ]
  grep -q "reload" "$BATS_TEST_TMPDIR/caddy.log"
}
