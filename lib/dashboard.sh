# shellcheck shell=bash
# dashboard.sh — live TUI dashboard. Safe to source. No `set -e` here.

# fs_dash_colors — populate the palette used by the renderer. Every var is set
# to an empty string (a no-op in printf) when color is unwanted: NO_COLOR is
# set, stdout isn't a TTY (piped / under tests), or the terminal is dumb. The
# renderer stays identical either way — it just emits no escape sequences, so
# non-interactive output is byte-for-byte the plain layout.
fs_dash_colors() {
  C_RESET='' C_BOLD='' C_DIM='' C_GREEN='' C_AMBER='' C_REV=''
  [ -n "${NO_COLOR:-}" ] && return 0
  [ -t 1 ] || return 0
  case "${TERM:-}" in ''|dumb) return 0 ;; esac
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'
  C_AMBER=$'\033[33m'
  C_REV=$'\033[7m'
}

fs_dash_render() {
  local sel="${1:-0}"
  local i=0
  local d port runtime status
  local dot glyph word rowplain pad cols
  local running=0 served=0 stopped=0 total=0
  local rst="${C_RESET:-}"

  cols="$(tput cols 2>/dev/null)" || cols=""
  [ -n "$cols" ] || cols=80

  # Topbar: bold title, dim keybind hints.
  printf '  %sfolder-server%s  %s[s]tart/stop [r]estart [e]dit [o]pen [l]ogs [u]nbind [j/k] move [q]uit%s\n\n' \
    "${C_BOLD:-}" "$rst" "${C_DIM:-}" "$rst"
  # Column headers, bold. STATUS is 9 wide: dot(1) + space(1) + word(7).
  printf '    %s%-32s %-9s %-6s %-10s%s\n' "${C_BOLD:-}" DOMAIN STATUS PORT RUNTIME "$rst"

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    port="$(fs_registry_field "$d" 3 2>/dev/null)"
    runtime="$(fs_registry_field "$d" 4 2>/dev/null)"
    status="$(fs_site_status "$d")"
    total=$((total+1))
    case "$status" in
      running) glyph='●'; word=running; dot="${C_GREEN:-}${glyph}${rst}"; running=$((running+1)) ;;
      served)  glyph='●'; word=served;  dot="${C_AMBER:-}${glyph}${rst}"; served=$((served+1)) ;;
      *)       glyph='○'; word=stopped; dot="${C_DIM:-}${glyph}${rst}";   stopped=$((stopped+1)) ;;
    esac

    if [ "$i" -eq "$sel" ]; then
      # Selected row: a full-width reverse-video bar (the "cursor"). Build the
      # plain text first so its display width is measurable, then pad to the
      # terminal width before wrapping the whole thing in reverse video.
      rowplain="$(printf '  > %-32s %s %-7s %-6s %-10s' "$d" "$glyph" "$word" "$port" "$runtime")"
      pad=$((cols - ${#rowplain}))
      [ "$pad" -lt 0 ] && pad=0
      printf '%s%s%*s%s\n' "${C_REV:-}" "$rowplain" "$pad" '' "$rst"
    else
      printf '    %-32s %s %-7s %-6s %-10s\n' "$d" "$dot" "$word" "$port" "$runtime"
    fi
    i=$((i+1))
  done < <(fs_registry_domains)

  # Bottom status bar: a thin rule and live counts.
  local summary="$total sites · $running running"
  [ "$served" -gt 0 ] && summary="$summary · $served served"
  summary="$summary · $stopped stopped"
  printf '\n  %s────────────────────────────────────────────────────────────%s\n' "${C_DIM:-}" "$rst"
  printf '  %s%s%s\n' "${C_DIM:-}" "$summary" "$rst"
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

# fs_dash_logs <domain> — live-tail the site's PHP log with a one-key exit.
# The log streams below a sticky header; press `q` or `Esc` to return to the
# dashboard. We roll our own follow loop rather than `less +F` because in
# `less` the first keypress only stops following (you land at `(END)` and must
# press `q` again) — a two-step, hint-less exit that reads like a stuck editor.
fs_dash_logs() {
  local domain="$1" log tail_pid key
  log="$(fs_logfile "$domain")"

  # No TTY on stdin (piped, or under tests) — there's no keyboard to drive the
  # live viewer, so just print the recent log and return instead of blocking on
  # a follow loop that could never be exited.
  if [ ! -t 0 ]; then
    if [ -f "$log" ]; then
      tail -n 200 "$log"
    else
      printf '(no log yet for %s — start the site first)\n' "$domain"
    fi
    return
  fi

  if [ ! -f "$log" ]; then
    printf '(no log yet for %s — start the site first)\n' "$domain"
    printf 'Press any key to return to the dashboard…'
    IFS= read -rsn1 key || true
    return
  fi

  printf '\033[1mLogs for %s\033[0m — press \033[1mq\033[0m or \033[1mEsc\033[0m to return to the dashboard\n' "$domain"
  printf '%s\n' '────────────────────────────────────────────────────────────'

  # Stream the log to the terminal in the background; read keys in the
  # foreground so a single q/Esc exits immediately.
  tail -n 200 -f "$log" &
  tail_pid=$!

  while kill -0 "$tail_pid" 2>/dev/null; do
    key=""
    IFS= read -rsn1 -t 1 key || true
    case "$key" in
      q|Q|$'\e') break ;;
    esac
  done

  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
}

fs_cmd_dash() {
  local sel=0
  local key
  local domains
  local n
  local domain
  local dir
  local confirm
  fs_dash_colors
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
