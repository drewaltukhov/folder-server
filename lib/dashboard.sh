# shellcheck shell=bash
# dashboard.sh — live TUI dashboard. Safe to source. No `set -e` here.

fs_dash_render() {
  local sel="${1:-0}"
  local i=0
  local d
  local port
  local runtime
  local status
  local marker
  printf '  folder-server — [s]tart/stop [r]estart [e]dit [o]pen [l]ogs [u]nbind [j/k] move [q]uit\n\n'
  printf '    %-32s %-8s %-6s %-10s\n' DOMAIN STATUS PORT RUNTIME
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    port="$(fs_registry_field "$d" 3 2>/dev/null)"
    runtime="$(fs_registry_field "$d" 4 2>/dev/null)"
    status="$(fs_site_status "$d")"
    if [ "$i" -eq "$sel" ]; then marker=">"; else marker=" "; fi
    printf '  %s %-32s %-8s %-6s %-10s\n' "$marker" "$d" "$status" "$port" "$runtime"
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
    u)
      fs_unbind_domain "$domain"
      echo "unbind"
      ;;
    q)
      echo "quit"
      ;;
    *)
      echo "none"
      ;;
  esac
}

# fs_dash_logs <domain> — open the site's PHP log in a pager (live-follow via
# `less +F`; press Ctrl-C to stop following, q to return to the dashboard).
fs_dash_logs() {
  local domain="$1" log
  log="$(fs_logfile "$domain")"
  if [ -f "$log" ]; then
    "${FS_PAGER:-less}" +F "$log"
  else
    printf '(no log yet for %s — start the site first)\n' "$domain"
  fi
}

fs_cmd_dash() {
  local sel=0
  local key
  local domains
  local n
  local domain
  local dir
  local confirm
  trap 'printf "\033[?25h\033[?1049l"' EXIT INT TERM
  printf '\033[?1049h\033[?25l'
  while true; do
    domains="$(fs_registry_domains)"
    n="$(printf '%s\n' "$domains" | grep -c .)" || n=0
    if [ "$n" -eq 0 ]; then sel=0
    elif [ "$sel" -ge "$n" ]; then sel=$((n-1))
    elif [ "$sel" -lt 0 ]; then sel=0
    fi
    printf '\033[H\033[2J'
    fs_dash_render "$sel"
    IFS= read -rsn1 -t 2 key || key=""
    case "$key" in
      j) [ "$sel" -lt $((n-1)) ] && sel=$((sel+1)) ;;
      k) [ "$sel" -gt 0 ] && sel=$((sel-1)) ;;
      '') : ;;
      q) break ;;
      e)
        domain="$(printf '%s\n' "$domains" | sed -n "$((sel+1))p")"
        [ -n "$domain" ] || continue
        dir="$(fs_registry_field "$domain" 2 2>/dev/null || true)"
        [ -n "$dir" ] || continue
        printf '\033[?25h\033[H\033[2J'   # show cursor + clear for the gum form
        fs_cmd_edit "$dir" || true
        printf '\033[?25l'                # re-hide cursor for the dashboard
        ;;
      l)
        domain="$(printf '%s\n' "$domains" | sed -n "$((sel+1))p")"
        [ -n "$domain" ] || continue
        printf '\033[?25h\033[H\033[2J'   # show cursor + clear for the pager
        fs_dash_logs "$domain" || true
        printf '\033[?25l'                # re-hide cursor for the dashboard
        ;;
      u)
        domain="$(printf '%s\n' "$domains" | sed -n "$((sel+1))p")"
        [ -n "$domain" ] || continue
        printf '\033[H\033[2J'
        printf 'Unbind %s?  Stops it, deletes its .folderserver, removes it from the list. [y/N] ' "$domain"
        IFS= read -rsn1 confirm || confirm=""
        case "$confirm" in y|Y) fs_unbind_domain "$domain" ;; esac
        ;;
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
