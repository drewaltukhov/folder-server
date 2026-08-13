load test_helper

# folder-server must work on both Apple Silicon (/opt/homebrew) and Intel
# (/usr/local) Macs, so every Homebrew-derived path hangs off FS_BREW_PREFIX
# instead of a hardcoded /opt/homebrew.

setup() {
  setup_common
}

# Source the libs in a clean env — test_helper exports FS_BREW_OPT and friends,
# which would mask the defaults we're asserting on.
srcvars() {
  env -u FS_BREW_PREFIX -u FS_BREW_OPT -u FS_CADDY_SITES -u FS_CADDY_CONFIG \
      -u FS_DNSMASQ_CONF -u HOMEBREW_PREFIX "$@" \
      bash -c '
        . "'"$REPO_ROOT"'/lib/helpers.sh"
        . "'"$REPO_ROOT"'/lib/caddy.sh"
        . "'"$REPO_ROOT"'/lib/commands.sh"
        echo "prefix=$FS_BREW_PREFIX"
        echo "opt=$FS_BREW_OPT"
        echo "sites=$FS_CADDY_SITES"
        echo "config=$FS_CADDY_CONFIG"
        echo "dnsmasq=$FS_DNSMASQ_CONF"
      '
}

@test "FS_BREW_PREFIX follows HOMEBREW_PREFIX when brew has set it" {
  run srcvars HOMEBREW_PREFIX=/fake/brew
  [ "$status" -eq 0 ]
  [[ "$output" == *"prefix=/fake/brew"* ]]
}

@test "Homebrew-derived paths all hang off the prefix" {
  run srcvars HOMEBREW_PREFIX=/fake/brew
  [ "$status" -eq 0 ]
  [[ "$output" == *"opt=/fake/brew/opt"* ]]
  [[ "$output" == *"sites=/fake/brew/etc/caddy/sites"* ]]
  [[ "$output" == *"config=/fake/brew/etc/Caddyfile"* ]]
  [[ "$output" == *"dnsmasq=/fake/brew/etc/dnsmasq.d/test.conf"* ]]
}

@test "prefix falls back to the tree that actually contains brew" {
  local fake="$BATS_TEST_TMPDIR/usrlocal"
  mkdir -p "$fake/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fake/bin/brew"
  chmod +x "$fake/bin/brew"
  run srcvars "FS_BREW_CANDIDATES=$fake"
  [ "$status" -eq 0 ]
  [[ "$output" == *"prefix=$fake"* ]]
}

@test "an explicit FS_BREW_OPT still overrides the derived default" {
  run srcvars HOMEBREW_PREFIX=/fake/brew FS_BREW_OPT=/custom/opt
  [ "$status" -eq 0 ]
  [[ "$output" == *"opt=/custom/opt"* ]]
  # the others are untouched by the override
  [[ "$output" == *"sites=/fake/brew/etc/caddy/sites"* ]]
}

@test "the autostart plist PATH uses the prefix, not a hardcoded one" {
  export HOMEBREW_PREFIX=/fake/brew
  export FS_BREW_PREFIX=/fake/brew
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/commands.sh"
  fs_ensure_home
  export FS_AUTOSTART_PLIST="$BATS_TEST_TMPDIR/autostart.plist"
  export FS_SELF="/fake/brew/bin/fs"
  fs_autostart_render
  grep -q "<string>/fake/brew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>" "$FS_AUTOSTART_PLIST"
}

# helpers.sh names the prefixes on purpose (candidate list + last-resort
# fallback); every other lib must go through FS_BREW_PREFIX.
@test "no lib outside the prefix resolver hardcodes a Homebrew prefix" {
  run grep -rn -e "/opt/homebrew" -e "/usr/local" \
    "$REPO_ROOT/lib/caddy.sh" "$REPO_ROOT/lib/commands.sh" \
    "$REPO_ROOT/lib/process.sh" "$REPO_ROOT/lib/dashboard.sh" "$REPO_ROOT/lib/deps.sh"
  [ "$status" -ne 0 ]
}

@test "the autostart self-path fallback uses the prefix" {
  export FS_BREW_PREFIX=/fake/brew
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/commands.sh"
  fs_ensure_home
  export FS_AUTOSTART_PLIST="$BATS_TEST_TMPDIR/autostart2.plist"
  # no FS_SELF and no `fs` on PATH → falls back to the prefix
  unset FS_SELF
  PATH="/usr/bin:/bin" fs_autostart_render
  grep -q "<string>/fake/brew/bin/fs</string>" "$FS_AUTOSTART_PLIST"
}
