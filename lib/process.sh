# shellcheck shell=bash
# process.sh — PHP process control (start/stop/is_running). Safe to source. No `set -e` here.

fs_pidfile() { printf '%s\n' "$FS_HOME/run/$1.pid"; }
fs_logfile() { printf '%s\n' "$FS_HOME/logs/$1.log"; }

fs_is_running() {
  local pf; pf="$(fs_pidfile "$1")"
  [ -f "$pf" ] || return 1
  local pid; pid="$(cat "$pf" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

fs_start_php() {
  local domain="$1" phpbin="$2" port="$3" docroot="$4"
  fs_ensure_home
  if fs_is_running "$domain"; then
    echo "fs: $domain already running" >&2; return 1
  fi
  local log pf
  log="$(fs_logfile "$domain")"
  pf="$(fs_pidfile "$domain")"
  nohup "$phpbin" -S "127.0.0.1:$port" -t "$docroot" >"$log" 2>&1 &
  echo "$!" >"$pf"
}

fs_stop_php() {
  local domain="$1" pf pid
  pf="$(fs_pidfile "$domain")"
  [ -f "$pf" ] || return 0
  pid="$(cat "$pf" 2>/dev/null)"
  [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
  rm -f "$pf"
}
