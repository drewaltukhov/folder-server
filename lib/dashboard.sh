# shellcheck shell=bash
# dashboard.sh — live TUI dashboard. Safe to source. No `set -e` here.

fs_dash_render() {
  local sel="${1:-0}"
  local i=0
  local d
  local port
  local php
  local status
  local marker
  printf '  folder-server — [s]tart/stop [r]estart [o]pen [l]ogs [j/k] move [q]uit\n\n'
  printf '    %-22s %-8s %-6s %-4s\n' DOMAIN STATUS PORT PHP
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    port="$(fs_registry_field "$d" 3)"
    php="$(fs_registry_field "$d" 4)"
    if fs_is_running "$d"; then status="running"; else status="stopped"; fi
    if [ "$i" -eq "$sel" ]; then marker=">"; else marker=" "; fi
    printf '  %s %-22s %-8s %-6s %-4s\n' "$marker" "$d" "$status" "$port" "$php"
    i=$((i+1))
  done < <(fs_registry_domains)
}

fs_dash_action() {
  local key="$1"
  local domain="$2"
  local dir
  dir="$(fs_registry_field "$domain" 2 2>/dev/null || true)"
  case "$key" in
    s)
      if fs_is_running "$domain"; then
        fs_cmd_down "$dir" >/dev/null 2>&1
      else
        fs_cmd_up "$dir" >/dev/null 2>&1
      fi
      echo "toggle"
      ;;
    r)
      fs_cmd_restart "$dir" >/dev/null 2>&1
      echo "restart"
      ;;
    o)
      "$FS_OPEN_BIN" "https://$domain" >/dev/null 2>&1
      echo "open"
      ;;
    l)
      echo "logs"
      ;;
    q)
      echo "quit"
      ;;
    *)
      echo "none"
      ;;
  esac
}

fs_cmd_dash() {
  local sel=0
  local key
  local domains
  local n
  local domain
  trap 'printf "\033[?25h\033[?1049l"' EXIT INT TERM
  printf '\033[?1049h\033[?25l'
  while true; do
    domains="$(fs_registry_domains)"
    n="$(printf '%s\n' "$domains" | grep -c .)"
    printf '\033[H\033[2J'
    fs_dash_render "$sel"
    IFS= read -rsn1 -t 2 key || key=""
    case "$key" in
      j) [ "$sel" -lt $((n-1)) ] && sel=$((sel+1)) ;;
      k) [ "$sel" -gt 0 ] && sel=$((sel-1)) ;;
      '') : ;;
      *)
        domain="$(printf '%s\n' "$domains" | sed -n "$((sel+1))p")"
        [ -n "$domain" ] || continue
        if [ "$(fs_dash_action "$key" "$domain")" = "quit" ]; then break; fi
        ;;
    esac
  done
  printf '\033[?25h\033[?1049l'
  trap - EXIT INT TERM
}
