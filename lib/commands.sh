# shellcheck shell=bash
# commands.sh — up/down/restart commands. Safe to source. No `set -e` here.

# _fs_load_config <dir>
# Reads fs_resolve_config output and sets FS_DOMAIN, FS_PHP, FS_DOCROOT globals.
_fs_load_config() {
  local dir="$1"
  local k v
  FS_DOMAIN=""; FS_PHP=""; FS_DOCROOT=""
  while IFS='=' read -r k v; do
    case "$k" in
      domain)  FS_DOMAIN="$v" ;;
      php)     FS_PHP="$v" ;;
      docroot) FS_DOCROOT="$v" ;;
    esac
  done < <(fs_resolve_config "$dir")
}

fs_cmd_up() {
  local dir="${1:-$PWD}"
  _fs_load_config "$dir"
  if [[ ! "$FS_DOMAIN" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "fs: invalid domain '$FS_DOMAIN' (allowed: letters, digits, . _ -)" >&2
    return 1
  fi
  local phpbin
  local port
  phpbin="$(fs_php_binary "$FS_PHP")" || return 1
  port="$(fs_registry_field "$FS_DOMAIN" 3 2>/dev/null || true)"
  [ -n "$port" ] || port="$(fs_free_port)" || return 1
  fs_start_php "$FS_DOMAIN" "$phpbin" "$port" "$FS_DOCROOT" || return 1
  fs_write_site "$FS_DOMAIN" "$port"
  fs_registry_set "$FS_DOMAIN" "$dir" "$port" "$FS_PHP"
  fs_caddy_reload || true
  echo "Serving $dir → https://$FS_DOMAIN (php $FS_PHP, port $port)"
}

fs_cmd_down() {
  local dir="${1:-$PWD}"
  _fs_load_config "$dir"
  fs_stop_php "$FS_DOMAIN"
  fs_remove_site "$FS_DOMAIN"
  fs_caddy_reload || true
  echo "Stopped $FS_DOMAIN"
}

fs_cmd_restart() {
  fs_cmd_down "$@"
  fs_cmd_up "$@"
}

: "${FS_OPEN_BIN:=open}"
: "${FS_TAIL_BIN:=tail}"

fs_cmd_list() {
  printf '%-24s %-8s %-6s %-4s %s\n' DOMAIN STATUS PORT PHP URL
  local d port php status
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    port="$(fs_registry_field "$d" 3 2>/dev/null)"; php="$(fs_registry_field "$d" 4 2>/dev/null)"
    if fs_is_running "$d"; then status="running"; else status="stopped"; fi
    printf '%-24s %-8s %-6s %-4s %s\n' "$d" "$status" "$port" "$php" "https://$d"
  done < <(fs_registry_domains)
}

fs_cmd_open() {
  local dir="${1:-$PWD}"
  _fs_load_config "$dir"
  "$FS_OPEN_BIN" "https://$FS_DOMAIN"
}

fs_cmd_logs() {
  local dir="${1:-$PWD}"
  _fs_load_config "$dir"
  local log
  log="$(fs_logfile "$FS_DOMAIN")"
  if [ ! -f "$log" ]; then echo "fs: no log for $FS_DOMAIN yet"; return 0; fi
  "$FS_TAIL_BIN" -n 50 -f "$log"
}

: "${FS_GUM_BIN:=gum}"

fs_cmd_init() {
  local dir="$PWD" force=0 a
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      *) dir="$a" ;;
    esac
  done
  local file="$dir/.folderserver"
  if [ -f "$file" ] && [ "$force" -ne 1 ]; then
    echo "fs: $file exists (use --force to overwrite)" >&2
    return 1
  fi
  local domain php docroot
  domain="$(fs_default_domain "$dir")"
  php="8.4"
  docroot=""
  if [ -t 0 ] && command -v "$FS_GUM_BIN" >/dev/null 2>&1; then
    domain="$("$FS_GUM_BIN" input --value "$domain" --prompt "Domain: ")"
    php="$("$FS_GUM_BIN" choose 8.4 8.5 8.3 --header "PHP version")"
    docroot="$("$FS_GUM_BIN" input --placeholder "public (blank = folder root)" --prompt "Docroot: ")"
  fi
  {
    printf 'domain=%s\n' "$domain"
    printf 'php=%s\n' "$php"
    [ -n "$docroot" ] && printf 'docroot=%s\n' "$docroot"
  } >"$file"
  echo "Wrote $file"
}

: "${FS_BREW_BIN:=brew}"
: "${FS_MYSQL_FORMULA:=mysql}"
: "${FS_MKCERT_BIN:=mkcert}"
: "${FS_DNSMASQ_CONF:=/opt/homebrew/etc/dnsmasq.d/test.conf}"
: "${FS_RESOLVER_DIR:=/etc/resolver}"

fs_cmd_db() {
  local action="${1:-}"
  case "$action" in
    start) "$FS_BREW_BIN" services start "$FS_MYSQL_FORMULA" ;;
    stop)  "$FS_BREW_BIN" services stop "$FS_MYSQL_FORMULA" ;;
    status) "$FS_BREW_BIN" services list ;;
    *) echo "Usage: fs db <start|stop|status>" >&2; return 2 ;;
  esac
}

fs_setup_deps() {
  local pkg
  for pkg in dnsmasq caddy gum fzf; do
    if ! "$FS_BREW_BIN" list "$pkg" >/dev/null 2>&1; then
      echo "Installing $pkg…"; "$FS_BREW_BIN" install "$pkg"
    fi
  done
}

fs_setup_dnsmasq() {
  mkdir -p "$(dirname "$FS_DNSMASQ_CONF")"
  local line="address=/.test/127.0.0.1"
  if [ -f "$FS_DNSMASQ_CONF" ] && grep -qF "$line" "$FS_DNSMASQ_CONF"; then return 0; fi
  printf '%s\n' "$line" >>"$FS_DNSMASQ_CONF"
}

fs_setup_cert() {
  local cert
  local key
  { read -r cert; read -r key; } < <(fs_cert_paths)
  if [ -f "$cert" ] && [ -f "$key" ]; then return 0; fi
  mkdir -p "$FS_CERT_DIR"
  "$FS_MKCERT_BIN" -cert-file "$cert" -key-file "$key" "*.test"
}

fs_setup_caddy_config() {
  local imp="import $FS_CADDY_SITES/*.caddy"
  mkdir -p "$(dirname "$FS_CADDY_CONFIG")" "$FS_CADDY_SITES"
  if [ -f "$FS_CADDY_CONFIG" ] && grep -qF "$imp" "$FS_CADDY_CONFIG"; then return 0; fi
  printf '%s\n' "$imp" >>"$FS_CADDY_CONFIG"
}

fs_cmd_setup() {
  fs_ensure_home
  echo "==> Installing dependencies"; fs_setup_deps
  echo "==> Configuring dnsmasq for *.test"; fs_setup_dnsmasq
  echo "==> Generating wildcard certificate"; fs_setup_cert
  echo "==> Wiring Caddy import"; fs_setup_caddy_config
  cat <<EOF

Almost done. Run these once (they need sudo / your password):

  sudo mkdir -p $FS_RESOLVER_DIR
  echo "nameserver 127.0.0.1" | sudo tee $FS_RESOLVER_DIR/test
  sudo brew services start dnsmasq
  sudo brew services start caddy

Then: cd into a project, run 'fs init' and 'fs up'.
EOF
}
