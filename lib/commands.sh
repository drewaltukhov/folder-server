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
  local d dir port php status
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    dir="$(fs_registry_field "$d" 2)"; port="$(fs_registry_field "$d" 3)"; php="$(fs_registry_field "$d" 4)"
    if fs_is_running "$d"; then status="running"; else status="stopped"; fi
    printf '%-24s %-8s %-6s %-4s %s\n' "$d" "$status" "$port" "$php" "https://$d"
  done < <(fs_registry_domains)
}

fs_cmd_open() {
  local dir="${1:-$PWD}"; _fs_load_config "$dir"
  "$FS_OPEN_BIN" "https://$FS_DOMAIN"
}

fs_cmd_logs() {
  local dir="${1:-$PWD}"; _fs_load_config "$dir"
  local log; log="$(fs_logfile "$FS_DOMAIN")"
  if [ ! -f "$log" ]; then echo "fs: no log for $FS_DOMAIN yet"; return 0; fi
  "$FS_TAIL_BIN" -n 50 -f "$log"
}
