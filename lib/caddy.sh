# shellcheck shell=bash
# caddy.sh — Caddy site snippet helpers. Safe to source. No `set -e` here.
: "${FS_CADDY_BIN:=caddy}"
: "${FS_CADDY_CONFIG:=/opt/homebrew/etc/Caddyfile}"

fs_caddy_template() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../templates" && pwd
}

# Per-site cert paths. Browsers reject a `*.test` wildcard (it spans a whole
# TLD → NET::ERR_CERT_COMMON_NAME_INVALID), so every site gets a cert with its
# exact hostname instead.
fs_cert_paths() {
  local domain="$1"
  printf '%s\n%s\n' "$FS_CERT_DIR/$domain.pem" "$FS_CERT_DIR/$domain-key.pem"
}

fs_render_site() {
  local domain="$1"
  local port="$2"
  local tmpl
  local cert
  local key
  tmpl="$(fs_caddy_template)/site.caddy.tmpl"
  { read -r cert; read -r key; } < <(fs_cert_paths "$domain")
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

# fs_write_devproxy_site <domain> <port> — like fs_write_site but for node dev
# servers. Two tweaks matter:
#   • dial the upstream as `localhost:<port>`, not `127.0.0.1:<port>` — many dev
#     servers (Vite/react-router bind `localhost`, which resolves to ::1 first)
#     end up listening on IPv6 loopback only; an IPv4-only dial gets connection
#     refused → 502. `localhost` lets Caddy try both families.
#   • rewrite the upstream Host to a loopback address — dev servers reject
#     proxied hostnames they don't recognise ("Blocked request … not allowed").
fs_write_devproxy_site() {
  local domain="$1" port="$2" cert key
  { read -r cert; read -r key; } < <(fs_cert_paths "$domain")
  mkdir -p "$FS_CADDY_SITES"
  {
    printf '%s {\n\ttls %s %s\n' "$domain" "$cert" "$key"
    printf '\treverse_proxy localhost:%s {\n\t\theader_up Host 127.0.0.1:%s\n\t}\n' "$port" "$port"
    printf '}\n'
  } >"$FS_CADDY_SITES/$domain.caddy"
}

# fs_render_static_site <domain> <docroot> [spa-fallback] — a snippet that serves
# a folder as static files (for `type=node, mode=build`). With a fallback file
# (e.g. index.html) it does SPA client-side routing via try_files.
fs_render_static_site() {
  local domain="$1" docroot="$2" fallback="${3:-}" cert key
  { read -r cert; read -r key; } < <(fs_cert_paths "$domain")
  printf '%s {\n\ttls %s %s\n\troot * %s\n' "$domain" "$cert" "$key" "$docroot"
  [ -n "$fallback" ] && printf '\ttry_files {path} /%s\n' "$fallback"
  printf '\tfile_server\n}\n'
}

fs_write_static_site() {
  local domain="$1" docroot="$2" fallback="${3:-}"
  mkdir -p "$FS_CADDY_SITES"
  fs_render_static_site "$domain" "$docroot" "$fallback" >"$FS_CADDY_SITES/$domain.caddy"
}

fs_remove_site() {
  rm -f "$FS_CADDY_SITES/$1.caddy" "$FS_CADDY_SITES/$1.lan.caddy"
}

# fs_write_lan_site <domain> <localhost> <lanport> <backend-port> — a second
# snippet that exposes a running site to the LAN over mDNS. It listens on
# <mac>.local:<lanport> with a cert trusted (once the mkcert CA is installed on
# the device) and proxies to the SAME loopback backend the .test block targets.
# The Host is rewritten to loopback so node dev servers accept the request.
# File name is keyed on the domain so `fs lan off` can remove just this block.
fs_write_lan_site() {
  local domain="$1" host="$2" lanport="$3" backend="$4" cert key
  { read -r cert; read -r key; } < <(fs_cert_paths "$host")
  mkdir -p "$FS_CADDY_SITES"
  {
    printf '%s:%s {\n\ttls %s %s\n' "$host" "$lanport" "$cert" "$key"
    printf '\treverse_proxy localhost:%s {\n\t\theader_up Host 127.0.0.1:%s\n\t}\n' "$backend" "$backend"
    printf '}\n'
  } >"$FS_CADDY_SITES/$domain.lan.caddy"
}

# fs_write_lan_static_site <domain> <localhost> <lanport> <docroot> [fallback] —
# LAN counterpart of fs_write_static_site: serve a built folder statically over
# mDNS (for type=node, mode=build, which has no loopback backend to proxy).
fs_write_lan_static_site() {
  local domain="$1" host="$2" lanport="$3" docroot="$4" fallback="${5:-}" cert key
  { read -r cert; read -r key; } < <(fs_cert_paths "$host")
  mkdir -p "$FS_CADDY_SITES"
  {
    printf '%s:%s {\n\ttls %s %s\n\troot * %s\n' "$host" "$lanport" "$cert" "$key" "$docroot"
    [ -n "$fallback" ] && printf '\ttry_files {path} /%s\n' "$fallback"
    printf '\tfile_server\n}\n'
  } >"$FS_CADDY_SITES/$domain.lan.caddy"
}

fs_remove_lan_site() {
  rm -f "$FS_CADDY_SITES/$1.lan.caddy"
}

fs_caddy_reload() {
  "$FS_CADDY_BIN" reload --config "$FS_CADDY_CONFIG" >/dev/null 2>&1 \
    || { echo "fs: caddy reload failed" >&2; return 1; }
}
