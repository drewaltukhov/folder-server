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

@test "setup_cert invokes mkcert with wildcard when cert missing" {
  make_stub mkcert "$BATS_TEST_TMPDIR/mkcert.log"; export FS_MKCERT_BIN=mkcert
  fs_setup_cert
  grep -q '\*.test' "$BATS_TEST_TMPDIR/mkcert.log"
}

@test "setup_cert is skipped when cert already exists" {
  make_stub mkcert "$BATS_TEST_TMPDIR/mkcert.log"; export FS_MKCERT_BIN=mkcert
  : >"$FS_CERT_DIR/_wildcard.test.pem"
  : >"$FS_CERT_DIR/_wildcard.test-key.pem"
  fs_setup_cert
  [ ! -f "$BATS_TEST_TMPDIR/mkcert.log" ]
}
