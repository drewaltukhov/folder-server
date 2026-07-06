# Shared setup for all bats files.
setup_common() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  FS_BIN="$REPO_ROOT/bin/folder-server"
  export FS_HOME="$BATS_TEST_TMPDIR/fshome"
  export FS_BREW_OPT="$BATS_TEST_TMPDIR/opt"
  export FS_CADDY_SITES="$BATS_TEST_TMPDIR/caddy-sites"
  export FS_CERT_DIR="$FS_HOME/certs"
  mkdir -p "$FS_HOME" "$FS_BREW_OPT" "$FS_CADDY_SITES"
  # Stub mkcert by default so `fs up` never invokes the real one (per-site cert
  # generation). Tests that assert on mkcert re-stub it with their own log.
  make_stub mkcert
}
# Install a fake php@VER binary under FS_BREW_OPT so fs_have_php / fs_pick_php
# see PHP as installed. Defaults to 8.4. The binary sleeps so `fs up` can treat
# it as a long-running server.
install_php_stub() {
  local ver="${1:-8.4}"
  mkdir -p "$FS_BREW_OPT/php@$ver/bin"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$FS_BREW_OPT/php@$ver/bin/php"
  chmod +x "$FS_BREW_OPT/php@$ver/bin/php"
}

# Put a stub executable named $1 on PATH that echoes its args to $2 log.
make_stub() {
  local name="$1" logfile="${2:-$BATS_TEST_TMPDIR/${1}.log}"
  local dir="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$dir"
  cat >"$dir/$name" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$logfile"
exit 0
EOF
  chmod +x "$dir/$name"
  export PATH="$dir:$PATH"
}
