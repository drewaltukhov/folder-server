# shellcheck shell=bash
# process.sh — backend process control (start/stop/is_running). Safe to source. No `set -e` here.

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
  local domain="$1" phpbin="$2" port="$3" docroot="$4" router="${5:-}"
  fs_ensure_home
  if fs_is_running "$domain"; then
    echo "fs: $domain already running" >&2; return 1
  fi
  local log pf
  log="$(fs_logfile "$domain")"
  pf="$(fs_pidfile "$domain")"
  if [ -n "$router" ]; then
    nohup "$phpbin" -S "127.0.0.1:$port" -t "$docroot" "$router" >"$log" 2>&1 &
  else
    nohup "$phpbin" -S "127.0.0.1:$port" -t "$docroot" >"$log" 2>&1 &
  fi
  echo "$!" >"$pf"
}

# fs_start_command <domain> <workdir> <port> <command> — run an arbitrary dev
# command (e.g. `npm run dev`) in workdir with PORT exported, backgrounded, and
# tracked by a pidfile. The command is exec'd so the pidfile holds its real PID.
fs_start_command() {
  local domain="$1" workdir="$2" port="$3" command="$4"
  fs_ensure_home
  if fs_is_running "$domain"; then
    echo "fs: $domain already running" >&2; return 1
  fi
  local log pf
  log="$(fs_logfile "$domain")"
  pf="$(fs_pidfile "$domain")"
  nohup bash -c "cd \"\$1\" && export PORT=\"\$2\" && exec \$3" _ "$workdir" "$port" "$command" >"$log" 2>&1 &
  echo "$!" >"$pf"
}

# fs_kill_tree <pid> — kill a process and all its descendants (dev servers spawn
# workers; macOS has no setsid, so we walk the tree with pgrep -P).
fs_kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    fs_kill_tree "$child"
  done
  kill "$pid" >/dev/null 2>&1 || true
}

# fs_stop_proc <domain> — stop a site's backend process (whole tree) and clear
# its pidfile. No-op if not running. Works for php -S (no children) and node.
fs_stop_proc() {
  local domain="$1" pf pid
  pf="$(fs_pidfile "$domain")"
  [ -f "$pf" ] || return 0
  pid="$(cat "$pf" 2>/dev/null)"
  [ -n "$pid" ] && fs_kill_tree "$pid"
  rm -f "$pf"
}

# Back-compat alias — callers may still say fs_stop_php.
fs_stop_php() { fs_stop_proc "$@"; }
