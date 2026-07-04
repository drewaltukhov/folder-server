# shellcheck shell=bash
# caddy.sh — Caddy site snippet helpers. Safe to source. No `set -e` here.
: "${FS_CADDY_BIN:=caddy}"
: "${FS_CADDY_CONFIG:=/opt/homebrew/etc/Caddyfile}"

fs_caddy_template() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../templates" && pwd
}

fs_cert_paths() {
  printf '%s\n%s\n' "$FS_CERT_DIR/_wildcard.test.pem" "$FS_CERT_DIR/_wildcard.test-key.pem"
}

fs_render_site() {
  local domain="$1"
  local port="$2"
  local tmpl
  local cert
  local key
  tmpl="$(fs_caddy_template)/site.caddy.tmpl"
  { read -r cert; read -r key; } < <(fs_cert_paths)
  sed -e "s|{{DOMAIN}}|$domain|g" \
      -e "s|{{PORT}}|$port|g" \
      -e "s|{{CERT}}|$cert|g" \
      -e "s|{{KEY}}|$key|g" "$tmpl"
}

fs_write_site() {
  local domain="$1"
  local port="$2"
  mkdir -p "$FS_CADDY_SITES"
  fs_render_site "$domain" "$port" >"$FS_CADDY_SITES/$domain.caddy"
}

fs_remove_site() {
  rm -f "$FS_CADDY_SITES/$1.caddy"
}

fs_caddy_reload() {
  "$FS_CADDY_BIN" reload --config "$FS_CADDY_CONFIG" >/dev/null 2>&1 \
    || { echo "fs: caddy reload failed" >&2; return 1; }
}
