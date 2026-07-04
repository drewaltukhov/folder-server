load test_helper
setup() {
  setup_common
  for l in helpers caddy commands; do . "$REPO_ROOT/lib/$l.sh"; done
  export FS_DNSMASQ_CONF="$BATS_TEST_TMPDIR/dnsmasq-test.conf"
  export FS_CADDY_CONFIG="$BATS_TEST_TMPDIR/Caddyfile"
  export FS_MKCERT_BIN=mkcert
  fs_ensure_home
}

@test "setup_dnsmasq writes the wildcard line once (idempotent)" {
  fs_setup_dnsmasq
  fs_setup_dnsmasq
  run grep -c "address=/.test/127.0.0.1" "$FS_DNSMASQ_CONF"
  [ "$output" = "1" ]
}

@test "setup_caddy_config adds the import line once" {
  fs_setup_caddy_config
  fs_setup_caddy_config
  run grep -c "import $FS_CADDY_SITES/\*.caddy" "$FS_CADDY_CONFIG"
  [ "$output" = "1" ]
}

@test "setup_cert installs the local CA (mkcert -install)" {
  make_stub mkcert "$BATS_TEST_TMPDIR/mkcert.log"; export FS_MKCERT_BIN=mkcert
  fs_setup_cert
  grep -q -- '-install' "$BATS_TEST_TMPDIR/mkcert.log"
}

@test "ensure_site_cert generates a cert for the exact hostname when missing" {
  make_stub mkcert "$BATS_TEST_TMPDIR/mkcert.log"; export FS_MKCERT_BIN=mkcert
  fs_ensure_site_cert foo.test
  # generated for the exact host, not a wildcard
  grep -q 'foo.test' "$BATS_TEST_TMPDIR/mkcert.log"
  run grep -q '\*.test' "$BATS_TEST_TMPDIR/mkcert.log"
  [ "$status" -ne 0 ]
}

@test "ensure_site_cert is skipped when the per-site cert already exists" {
  make_stub mkcert "$BATS_TEST_TMPDIR/mkcert.log"; export FS_MKCERT_BIN=mkcert
  : >"$FS_CERT_DIR/foo.test.pem"
  : >"$FS_CERT_DIR/foo.test-key.pem"
  fs_ensure_site_cert foo.test
  [ ! -f "$BATS_TEST_TMPDIR/mkcert.log" ]
}
