# shellcheck shell=bash
# helpers.sh — pure helpers, safe to source. No `set -e` here.
: "${FS_HOME:=$HOME/.folder-server}"
: "${FS_BREW_OPT:=/opt/homebrew/opt}"
: "${FS_CADDY_SITES:=/opt/homebrew/etc/caddy/sites}"
: "${FS_CERT_DIR:=$FS_HOME/certs}"

fs_ensure_home() {
  mkdir -p "$FS_HOME/run" "$FS_HOME/logs" "$FS_CERT_DIR"
  [ -f "$FS_HOME/registry" ] || : >"$FS_HOME/registry"
}
