load test_helper
setup() { setup_common; }

# Regression: `fs setup` must run end-to-end through the real entrypoint
# (which is `#!/usr/bin/env bash` → macOS system bash 3.2) without tripping
# `set -u`. Bash 3.2 misparses `$var` immediately followed by a multibyte
# character, so any progress message like "Installing $pkg…" aborts with
# "unbound variable". The brew stub must FAIL `list` (package "missing") so
# the install/progress branch actually executes.
@test "setup runs end-to-end under bash 3.2 without unbound-variable error" {
  local dir="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$dir"
  cat >"$dir/brew" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$dir/brew"
  export PATH="$dir:$PATH"
  make_stub mkcert
  export FS_DNSMASQ_CONF="$BATS_TEST_TMPDIR/dnsmasq-test.conf"
  export FS_CADDY_CONFIG="$BATS_TEST_TMPDIR/Caddyfile"

  run "$FS_BIN" setup
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"Installing dependencies"* ]]
}
