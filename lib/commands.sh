# shellcheck shell=bash
# commands.sh — up/down/restart commands. Safe to source. No `set -e` here.

# _fs_load_config <dir>
# Reads fs_resolve_config output and sets the FS_* config globals.
_fs_load_config() {
  local dir="$1"
  local k v
  FS_DOMAIN=""; FS_PHP=""; FS_DOCROOT=""; FS_REWRITE=""
  FS_DB=""; FS_DB_NAME=""; FS_DB_USER=""; FS_DB_PASS=""
  FS_TYPE=""; FS_MODE=""; FS_COMMAND=""; FS_BUILD=""; FS_PORT=""; FS_INSTALL=""
  FS_LAN=""
  while IFS='=' read -r k v; do
    case "$k" in
      install) FS_INSTALL="$v" ;;
      lan)     FS_LAN="$v" ;;
      domain)  FS_DOMAIN="$v" ;;
      php)     FS_PHP="$v" ;;
      docroot) FS_DOCROOT="$v" ;;
      rewrite) FS_REWRITE="$v" ;;
      db)      FS_DB="$v" ;;
      db_name) FS_DB_NAME="$v" ;;
      db_user) FS_DB_USER="$v" ;;
      db_pass) FS_DB_PASS="$v" ;;
      type)    FS_TYPE="$v" ;;
      mode)    FS_MODE="$v" ;;
      command) FS_COMMAND="$v" ;;
      build)   FS_BUILD="$v" ;;
      port)    FS_PORT="$v" ;;
    esac
  done < <(fs_resolve_config "$dir")
}

# fs_write_config <dir> <domain> <php> <docroot> <rewrite> <db> <db_name> <db_user> <db_pass>
# Writes a .folderserver from explicit values. Optional keys are omitted when
# empty; the db_* block is written only when db is "on". Used by init and edit.
fs_write_config() {
  local dir="$1" domain="$2" php="$3" docroot="$4" rewrite="$5"
  local db="$6" db_name="$7" db_user="$8" db_pass="$9"
  local type="${10:-php}" mode="${11:-dev}" command="${12:-}" build="${13:-}" port="${14:-}" install="${15:-}"
  local lan="${16:-}"
  {
    printf 'domain=%s\n' "$domain"
    if [ "$type" = node ]; then
      printf 'type=node\n'
      printf 'mode=%s\n' "$mode"
      if [ "$mode" = build ]; then
        [ -n "$build" ] && printf 'build=%s\n' "$build"
        [ -n "$docroot" ] && printf 'docroot=%s\n' "$docroot"
        [ -n "$rewrite" ] && printf 'rewrite=%s\n' "$rewrite"
      else
        [ -n "$command" ] && printf 'command=%s\n' "$command"
        [ -n "$port" ] && printf 'port=%s\n' "$port"
      fi
      fs_db_enabled "$install" && printf 'install=on\n'
    elif [ "$type" = static ]; then
      printf 'type=static\n'
      [ -n "$docroot" ] && printf 'docroot=%s\n' "$docroot"
    else
      printf 'php=%s\n' "$php"
      [ -n "$docroot" ] && printf 'docroot=%s\n' "$docroot"
      [ -n "$rewrite" ] && printf 'rewrite=%s\n' "$rewrite"
    fi
    if fs_db_enabled "$db"; then
      printf 'db=on\n'
      printf 'db_name=%s\n' "$db_name"
      printf 'db_user=%s\n' "$db_user"
      printf 'db_pass=%s\n' "$db_pass"
    fi
    if fs_db_enabled "$lan"; then printf 'lan=on\n'; fi
  } >"$dir/.folderserver"
}

# --- Node project detection (used by fs init) ---
fs_detect_node() { [ -f "$1/package.json" ]; }

fs_detect_pm() {
  local dir="$1"
  if [ -f "$dir/pnpm-lock.yaml" ]; then echo pnpm
  elif [ -f "$dir/yarn.lock" ]; then echo yarn
  elif [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then echo bun
  else echo npm
  fi
}

# echo the dev (or build) command for the folder's package manager.
fs_detect_command() {
  local dir="$1" script="${2:-dev}" pm
  pm="$(fs_detect_pm "$dir")"
  case "$pm" in
    npm)  echo "npm run $script" ;;
    pnpm) echo "pnpm $script" ;;
    yarn) echo "yarn $script" ;;
    bun)  echo "bun run $script" ;;
  esac
}

# best-effort default dev-server port from the framework in package.json.
fs_detect_port() {
  local pkg="$1/package.json"
  [ -f "$pkg" ] || { echo 3000; return; }
  if grep -q '"vite"' "$pkg"; then echo 5173
  elif grep -q '"astro"' "$pkg"; then echo 4321
  else echo 3000
  fi
}

# best-effort default build output folder.
fs_detect_output() {
  local pkg="$1/package.json"
  if [ -f "$pkg" ] && grep -q '"react-scripts"' "$pkg"; then echo build
  else echo dist
  fi
}

fs_db_enabled() {
  case "$1" in on|1|true|yes|ON|Yes|True) return 0 ;; *) return 1 ;; esac
}

: "${FS_MYSQL_BIN:=mysql}"
: "${FS_MYSQL_ADMIN:=root}"
: "${FS_MYSQL_HOST:=127.0.0.1}"
: "${FS_MYSQL_PORT:=3306}"

# fs_db_creds_banner <db> <user> <pass> — print the connection details a
# developer needs after their database is provisioned.
fs_db_creds_banner() {
  local db="$1" user="$2" pass="$3"
  printf '  MySQL ready — connect with:\n'
  printf '    host      %s   (use this, not "localhost")\n' "$FS_MYSQL_HOST"
  printf '    port      %s\n' "$FS_MYSQL_PORT"
  printf '    database  %s\n' "$db"
  printf '    user      %s\n' "$user"
  printf '    password  %s\n' "$pass"
}

# fs_db_provision <name> <user> <pass>
# Starts the shared MySQL, waits for readiness, then (idempotently) creates the
# database and a user with full grants on it — so mysqli_connect(127.0.0.1,
# user, pass, name) works. Connects as the admin account (default: root, no
# password — the Homebrew MySQL default). Overridable: FS_MYSQL_BIN,
# FS_MYSQL_ADMIN, FS_MYSQL_FORMULA, FS_BREW_BIN.
fs_db_provision() {
  local name="$1" user="$2" pass="$3"
  if [[ ! "$name" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "fs: invalid db name '$name' (allowed: letters, digits, _)" >&2; return 1
  fi
  if [[ ! "$user" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "fs: invalid db user '$user' (allowed: letters, digits, _)" >&2; return 1
  fi
  if [ "$user" = "$FS_MYSQL_ADMIN" ]; then
    echo "fs: db_user cannot be '$FS_MYSQL_ADMIN' — that's the MySQL admin account folder-server uses to provision, and it can't also be a password-protected app user. Use a dedicated user (e.g. the project name)." >&2
    return 1
  fi
  case "$pass" in
    *\\*|*\`*) echo "fs: db password may not contain a backslash or backtick" >&2; return 1 ;;
  esac
  if ! command -v "$FS_MYSQL_BIN" >/dev/null 2>&1; then
    echo "fs: MySQL not installed — run: brew install $FS_MYSQL_FORMULA" >&2
    return 1
  fi
  local pesc
  pesc="$(printf '%s' "$pass" | sed "s/'/''/g")"
  "$FS_BREW_BIN" services start "$FS_MYSQL_FORMULA" >/dev/null 2>&1 || true
  local i=0
  until "$FS_MYSQL_BIN" -u"$FS_MYSQL_ADMIN" -e 'SELECT 1' >/dev/null 2>&1; do
    i=$((i+1))
    if [ "$i" -ge 30 ]; then echo "fs: MySQL did not become ready" >&2; return 1; fi
    sleep 0.5
  done
  # CREATE makes the user if absent; ALTER guarantees the configured password is
  # applied even when the user already existed (e.g. after `fs edit`). Grants for
  # both @'%' (TCP) and @'localhost' (socket / 127.0.0.1 via name resolution).
  "$FS_MYSQL_BIN" -u"$FS_MYSQL_ADMIN" <<SQL
CREATE DATABASE IF NOT EXISTS \`$name\`;
CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$pesc';
CREATE USER IF NOT EXISTS '$user'@'localhost' IDENTIFIED BY '$pesc';
ALTER USER '$user'@'%' IDENTIFIED BY '$pesc';
ALTER USER '$user'@'localhost' IDENTIFIED BY '$pesc';
GRANT ALL PRIVILEGES ON \`$name\`.* TO '$user'@'%';
GRANT ALL PRIVILEGES ON \`$name\`.* TO '$user'@'localhost';
FLUSH PRIVILEGES;
SQL
}

# Front-controller router support (the .htaccess "route unknown URLs to
# index.php" pattern, implemented as a `php -S` router script).
fs_router_file() { printf '%s\n' "$FS_HOME/run/$1.router.php"; }

fs_router_render() {
  local fc="$1" tmpl
  tmpl="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates" && pwd)/router.php.tmpl"
  sed -e "s|{{FRONT_CONTROLLER}}|$fc|g" "$tmpl"
}

fs_write_router() {
  local domain="$1" fc="$2"
  fs_ensure_home
  fs_router_render "$fc" >"$(fs_router_file "$domain")"
}

fs_remove_router() {
  rm -f "$(fs_router_file "$1")"
}

# Fully forget a site: stop it, tear down its Caddy snippet + router, delete the
# project's .folderserver, and drop it from the registry (so it leaves `fs list`
# and the dashboard). The inverse of `fs init` + `fs up`. The dir is passed
# explicitly by the CLI (which knows it), or looked up in the registry when the
# dashboard only has the domain.
fs_unbind_domain() {
  local domain="$1" dir="${2:-}"
  [ -n "$dir" ] || dir="$(fs_registry_field "$domain" 2 2>/dev/null || true)"
  fs_stop_php "$domain"
  fs_remove_router "$domain"
  fs_remove_site "$domain"
  fs_lan_port_forget "$domain"
  fs_caddy_reload || true
  [ -n "$dir" ] && rm -f "$dir/.folderserver"
  fs_registry_remove "$domain"
}

# _fs_confirm <prompt> — interactive y/N. gum when available, else read.
# Non-interactive (no TTY) returns No, so destructive bulk actions never run
# unattended without an explicit --yes.
_fs_confirm() {
  if [ -t 0 ] && command -v "$FS_GUM_BIN" >/dev/null 2>&1; then
    "$FS_GUM_BIN" confirm "$1"; return
  fi
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1"; local r; read -r r; case "$r" in y|Y) return 0 ;; *) return 1 ;; esac
}

fs_cmd_unbind() {
  if [ "${1:-}" = "--all" ]; then
    local yes=0
    case "${2:-}" in --yes|-y) yes=1 ;; esac
    local domains d dir n
    domains="$(fs_registry_domains)"
    if [ -z "$domains" ]; then echo "fs: no sites to unbind"; return 0; fi
    n="$(printf '%s\n' "$domains" | grep -c .)"
    if [ "$yes" -ne 1 ] && ! _fs_confirm "Unbind all $n site(s)? Stops them and deletes each .folderserver."; then
      echo "Aborted."; return 0
    fi
    # snapshot the list first — unbinding removes registry entries as we go
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      dir="$(fs_registry_field "$d" 2 2>/dev/null || true)"
      fs_unbind_domain "$d" "$dir"
      echo "Unbound $d"
    done <<<"$domains"
    return 0
  fi
  local dir="${1:-$PWD}"
  _fs_load_config "$dir"
  fs_unbind_domain "$FS_DOMAIN" "$dir"
  echo "Unbound $FS_DOMAIN (stopped, removed .folderserver, forgot the site)"
}

# _fs_each_site <fn> — run <fn> for every known site, passing its directory.
# One site failing does not stop the rest.
_fs_each_site() {
  local fn="$1" d dir any=0 seen=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    seen=1
    dir="$(fs_registry_field "$d" 2 2>/dev/null || true)"
    if [ -z "$dir" ]; then
      # A registry entry with no directory can't be run — but don't drop it
      # silently, or '--all' looks like it skipped a site it knows about.
      echo "fs: skipping '$d' — no directory on record (run 'fs up' in it, or 'fs unbind $d')" >&2
      continue
    fi
    any=1
    "$fn" "$dir" || echo "fs: '$fn' failed for $d" >&2
  done < <(fs_registry_domains)
  if [ "$any" -ne 1 ]; then
    if [ "$seen" -eq 1 ]; then
      echo "fs: no runnable sites — every known site is missing its directory (see warnings above)" >&2
    else
      echo "fs: no known sites yet (run 'fs init' + 'fs up' in a project)"
    fi
  fi
}

# Provision MySQL if the project opts in (shared by every runtime).
_fs_maybe_provision_db() {
  fs_db_enabled "$FS_DB" || return 0
  if fs_db_provision "$FS_DB_NAME" "$FS_DB_USER" "$FS_DB_PASS"; then
    fs_db_creds_banner "$FS_DB_NAME" "$FS_DB_USER" "$FS_DB_PASS"
  else
    echo "fs: DB setup failed — site is still served" >&2
  fi
}

fs_cmd_up() {
  if [ "${1:-}" = "--all" ]; then _fs_each_site fs_cmd_up; return 0; fi
  local dir="${1:-$PWD}"
  _fs_load_config "$dir"
  if [[ ! "$FS_DOMAIN" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "fs: invalid domain '$FS_DOMAIN' (allowed: letters, digits, . _ -)" >&2
    return 1
  fi
  case "$FS_TYPE" in
    node)
      if [ -f "$dir/package.json" ] && [ ! -d "$dir/node_modules" ]; then
        local ins; ins="$(fs_node_install_hint "$dir")"
        if fs_db_enabled "$FS_INSTALL"; then
          echo "Installing dependencies ($ins)…"
          if ! ( cd "$dir" && eval "$ins" ); then
            echo "fs: dependency install failed ($ins)" >&2; return 1
          fi
        else
          echo "fs: dependencies not installed — run '$ins' in $dir first (or set install=on to auto-install)" >&2
          return 1
        fi
      fi
      case "$FS_MODE" in
        build) fs_up_node_build "$dir" ;;
        *)     fs_up_node_dev "$dir" ;;
      esac ;;
    static) fs_up_static "$dir" ;;
    *) fs_up_php "$dir" ;;
  esac
}

# the install command for the folder's package manager (npm/pnpm/yarn/bun).
fs_node_install_hint() {
  local pm; pm="$(fs_detect_pm "$1")"
  case "$pm" in
    yarn) echo "yarn" ;;
    *)    echo "$pm install" ;;
  esac
}

# --- PHP (default): php -S behind Caddy ---
fs_up_php() {
  local dir="$1"
  # Every PHP site runs behind a router so that *.html files are executed as
  # PHP (see templates/router.php.tmpl). The front controller is optional —
  # empty unless a rewrite is configured.
  local fc=""
  if [ -n "$FS_REWRITE" ]; then
    if [[ ! "$FS_REWRITE" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "fs: invalid rewrite '$FS_REWRITE' (must be a front-controller filename in the docroot, e.g. index.php)" >&2
      return 1
    fi
    fc="$FS_REWRITE"
  fi
  fs_write_router "$FS_DOMAIN" "$fc"
  local router; router="$(fs_router_file "$FS_DOMAIN")"
  local phpbin
  local port
  phpbin="$(fs_php_binary "$FS_PHP")" || return 1
  port="$(fs_registry_field "$FS_DOMAIN" 3 2>/dev/null || true)"
  [ -n "$port" ] || port="$(fs_free_port)" || return 1
  fs_start_php "$FS_DOMAIN" "$phpbin" "$port" "$FS_DOCROOT" "$router" || return 1
  fs_ensure_site_cert "$FS_DOMAIN"
  fs_write_site "$FS_DOMAIN" "$port"
  fs_registry_set "$FS_DOMAIN" "$dir" "$port" "php $FS_PHP"
  _fs_publish_lan_if_on "$FS_DOMAIN"
  fs_caddy_reload || true
  if [ -n "$FS_REWRITE" ]; then
    echo "Serving $dir → https://$FS_DOMAIN (php $FS_PHP, port $port, rewrite → $FS_REWRITE)"
  else
    echo "Serving $dir → https://$FS_DOMAIN (php $FS_PHP, port $port)"
  fi
  fs_lan_report
  _fs_maybe_provision_db
}

# fs_detect_running_port <domain> <fallback> — read the port the dev server
# actually bound from its startup log ("Local http://localhost:PORT/"). Dev
# servers often override the port in their own config, so we proxy to where it
# really listens instead of guessing. Falls back after a short wait.
: "${FS_NODE_PORT_WAIT:=20}"   # × 0.5s
fs_detect_running_port() {
  local domain="$1" fallback="$2" log port i=0
  log="$(fs_logfile "$domain")"
  while [ "$i" -lt "$FS_NODE_PORT_WAIT" ]; do
    port="$(grep -oE '(localhost|127\.0\.0\.1):[0-9]+' "$log" 2>/dev/null | grep -oE '[0-9]+$' | head -1)"
    [ -n "$port" ] && { printf '%s\n' "$port"; return 0; }
    i=$((i+1)); sleep 0.5
  done
  printf '%s\n' "$fallback"
}

# --- Node · dev: run the dev command, proxy Caddy to it (HMR works) ---
fs_up_node_dev() {
  local dir="$1"
  local port
  port="$FS_PORT"                                            # config-pinned target / PORT hint
  [ -n "$port" ] || port="$(fs_registry_field "$FS_DOMAIN" 3 2>/dev/null || true)"
  [ -n "$port" ] || port="$(fs_free_port)" || return 1
  fs_start_command "$FS_DOMAIN" "$dir" "$port" "$FS_COMMAND" || return 1
  fs_ensure_site_cert "$FS_DOMAIN"
  # proxy to the port the server actually bound (it may override our hint)
  local actual; actual="$(fs_detect_running_port "$FS_DOMAIN" "$port")"
  fs_write_devproxy_site "$FS_DOMAIN" "$actual"
  fs_registry_set "$FS_DOMAIN" "$dir" "$actual" "node dev"
  _fs_publish_lan_if_on "$FS_DOMAIN"
  fs_caddy_reload || true
  echo "Serving $dir → https://$FS_DOMAIN (node dev: $FS_COMMAND, port $actual)"
  fs_lan_report
  _fs_maybe_provision_db
}

# --- Node · build: run the build, Caddy serves the output folder statically ---
fs_up_node_build() {
  local dir="$1"
  fs_ensure_site_cert "$FS_DOMAIN"
  echo "Building $dir ($FS_BUILD)…"
  if ! ( cd "$dir" && eval "$FS_BUILD" ); then
    echo "fs: build failed ($FS_BUILD)" >&2
    return 1
  fi
  fs_write_static_site "$FS_DOMAIN" "$FS_DOCROOT" "$FS_REWRITE"
  fs_registry_set "$FS_DOMAIN" "$dir" "-" "node build"
  _fs_publish_lan_if_on "$FS_DOMAIN"
  fs_caddy_reload || true
  echo "Serving $dir → https://$FS_DOMAIN (static from $FS_DOCROOT)"
  fs_lan_report
  _fs_maybe_provision_db
}

# --- Static: Caddy file_server on a folder, no PHP/node/process ---
fs_up_static() {
  local dir="$1"
  fs_ensure_site_cert "$FS_DOMAIN"
  fs_write_static_site "$FS_DOMAIN" "$FS_DOCROOT"
  fs_registry_set "$FS_DOMAIN" "$dir" "-" "static"
  _fs_publish_lan_if_on "$FS_DOMAIN"
  fs_caddy_reload || true
  echo "Serving $dir → https://$FS_DOMAIN (static from ${FS_DOCROOT:-$dir})"
  fs_lan_report
  _fs_maybe_provision_db
}

fs_cmd_down() {
  if [ "${1:-}" = "--all" ]; then _fs_each_site fs_cmd_down; return 0; fi
  local dir="${1:-$PWD}"
  _fs_load_config "$dir"
  fs_stop_php "$FS_DOMAIN"
  fs_remove_router "$FS_DOMAIN"
  fs_remove_site "$FS_DOMAIN"
  fs_caddy_reload || true
  echo "Stopped $FS_DOMAIN"
}

fs_cmd_restart() {
  fs_cmd_down "$@"
  fs_cmd_up "$@"
}

# --- LAN exposure ----------------------------------------------------------
# When a site's .folderserver has `lan=on`, `fs up` also publishes it to the
# local network over mDNS at https://<mac>.local:<port> with trusted HTTPS
# (after the mkcert CA is installed on the device once — see `fs lan ca`).
: "${FS_LAN_PORT_BASE:=8443}"   # per-site LAN ports are assigned from here up

# per-site LAN port registry — "$FS_HOME/lan-ports", lines "<domain>|<port>".
fs_lan_ports_file() { printf '%s\n' "$FS_HOME/lan-ports"; }

# fs_lan_port_get <domain> — echo the site's assigned LAN port, or nothing.
fs_lan_port_get() {
  local f re; f="$(fs_lan_ports_file)"; [ -f "$f" ] || return 0
  re=$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')
  grep "^${re}|" "$f" 2>/dev/null | head -1 | cut -d'|' -f2
}

# fs_lan_port <domain> — echo a STABLE LAN port for the site, allocating and
# persisting one from FS_LAN_PORT_BASE up on first call (skipping ports already
# assigned to another site or otherwise in use). Stable ⇒ the phone URL doesn't
# change between restarts.
fs_lan_port() {
  local domain="$1" f used p port
  port="$(fs_lan_port_get "$domain")"
  [ -n "$port" ] && { printf '%s\n' "$port"; return 0; }
  f="$(fs_lan_ports_file)"; fs_ensure_home; [ -f "$f" ] || : >"$f"
  used="$(cut -d'|' -f2 "$f" 2>/dev/null || true)"
  for p in $(seq "$FS_LAN_PORT_BASE" $((FS_LAN_PORT_BASE + 200))); do
    printf '%s\n' "$used" | grep -qx "$p" && continue
    fs_port_in_use "$p" && continue
    port="$p"; break
  done
  [ -n "$port" ] || { echo "fs: no free LAN port near $FS_LAN_PORT_BASE" >&2; return 1; }
  printf '%s|%s\n' "$domain" "$port" >>"$f"
  printf '%s\n' "$port"
}

# fs_lan_port_forget <domain> — drop the site's LAN port assignment (on unbind).
fs_lan_port_forget() {
  local f tmp re; f="$(fs_lan_ports_file)"; [ -f "$f" ] || return 0
  re=$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')
  tmp="$(mktemp "${f}.XXXXXX")"; grep -v "^${re}|" "$f" 2>/dev/null >"$tmp" || true; mv "$tmp" "$f"
}

# echo the Mac's Bonjour name, e.g. "users-mac.local".
fs_local_host() {
  local h; h="$(scutil --get LocalHostName 2>/dev/null || true)"
  [ -n "$h" ] || { echo "fs: no Bonjour hostname set (System Settings → General → Sharing → Local hostname)" >&2; return 1; }
  printf '%s.local\n' "$h"
}

# print a comprehensive, one-time root-CA install guide for a new device.
# Trusting this CA once makes every https://<mac>.local site load without any
# warning on that device. It only needs doing once per device.
fs_lan_ca() {
  local caroot ca
  caroot="$("$FS_MKCERT_BIN" -CAROOT 2>/dev/null || true)"
  ca="$caroot/rootCA.pem"
  cat <<EOF
Trust the local certificate authority on your phone/tablet — do this ONCE per
device, and every https://<mac>.local site loads with a green padlock.

The CA file to send to the device:
  $ca

──────────────────────────────────────────────────────────────────────────────
 iPhone / iPad
──────────────────────────────────────────────────────────────────────────────
  1. Get the file onto the device:
       • AirDrop rootCA.pem from this Mac (fastest), or
       • email it to yourself / drop it in iCloud Drive and open it in Files.
  2. Install the profile:
       Settings → "Profile Downloaded" (near the top) → Install
       → enter your passcode → Install → Install.
  3. ⚠️ TURN ON FULL TRUST — the step everyone forgets, and without it you
     still get a certificate warning:
       Settings → General → About → Certificate Trust Settings
       → enable the switch next to "mkcert …".
  4. Done. Open the site's https://…local URL in Safari or Chrome — green lock.

──────────────────────────────────────────────────────────────────────────────
 Android
──────────────────────────────────────────────────────────────────────────────
  1. Send rootCA.pem to the device (AirDrop equivalent / email / Files).
  2. Settings → Security → More → Encryption & credentials
       → Install a certificate → CA certificate → pick rootCA.pem.
     (Wording varies by Android version; search Settings for "CA certificate".)
  Note: Chrome on Android trusts user-installed CAs; some apps do not.

──────────────────────────────────────────────────────────────────────────────
 Another Mac
──────────────────────────────────────────────────────────────────────────────
  Copy rootCA.pem over and run:  mkcert -install
  (or double-click it in Keychain Access → set "Always Trust").

Tip: this file is only a *trust anchor* — it lets the device verify certs this
Mac issues. Keep rootCA-key.pem (next to it) private; never send that one.
EOF
}

# warn if the macOS application firewall might block incoming LAN connections.
: "${FS_FIREWALL_BIN:=/usr/libexec/ApplicationFirewall/socketfilterfw}"
fs_lan_firewall_hint() {
  local fw="$FS_FIREWALL_BIN"
  [ -x "$fw" ] || return 0
  if "$fw" --getglobalstate 2>/dev/null | grep -qi "enabled"; then
    echo
    echo "Note: the macOS firewall is on. If the phone can't connect, allow incoming"
    echo "connections for caddy (System Settings → Network → Firewall → Options)."
  fi
}

# fs_lan_expose <domain> <kind> <args...> — publish an already-up site to the
# LAN over mDNS and set FS_LAN_URL to https://<mac>.local:<port>. Writes the
# Caddy block but does NOT reload (the caller's single reload covers it).
#   kind=proxy  <backend-port>       kind=static <docroot> [fallback]
# Best-effort: on any problem it warns, leaves FS_LAN_URL empty, and never fails
# the primary serve.
fs_lan_expose() {
  local domain="$1" kind="$2"; shift 2
  local host lanport
  FS_LAN_URL=""
  if ! host="$(fs_local_host 2>/dev/null)"; then
    echo "fs: network exposure skipped — no Bonjour hostname (System Settings → General → Sharing)" >&2; return 0
  fi
  lanport="$(fs_lan_port "$domain")" || { echo "fs: network exposure skipped — no free LAN port" >&2; return 0; }
  fs_ensure_site_cert "$host" || { echo "fs: network exposure skipped — cert for $host failed" >&2; return 0; }
  case "$kind" in
    proxy)  [ -n "${1:-}" ] || { echo "fs: network exposure skipped — no backend port" >&2; return 0; }
            fs_write_lan_site "$domain" "$host" "$lanport" "$1" ;;
    static) fs_write_lan_static_site "$domain" "$host" "$lanport" "$1" "${2:-}" ;;
    *)      echo "fs: network exposure skipped — unknown kind '$kind'" >&2; return 0 ;;
  esac
  FS_LAN_URL="https://$host:$lanport"
}

# _fs_publish_lan_if_on <domain> — if FS_LAN is on, publish the current (already
# registered, block-written) site to the LAN, picking proxy vs static from the
# loaded FS_TYPE/FS_MODE. Sets FS_LAN_URL. Assumes the caller reloads Caddy.
_fs_publish_lan_if_on() {
  local domain="$1" backend
  FS_LAN_URL=""
  fs_db_enabled "$FS_LAN" || return 0
  if [ "$FS_TYPE" = static ] || { [ "$FS_TYPE" = node ] && [ "$FS_MODE" = build ]; }; then
    fs_lan_expose "$domain" static "$FS_DOCROOT" "$FS_REWRITE"
  else
    backend="$(fs_registry_field "$domain" 3 2>/dev/null || true)"
    fs_lan_expose "$domain" proxy "$backend"
  fi
}

# print the LAN URL line after a "Serving …" message, when one was published.
fs_lan_report() {
  [ -n "${FS_LAN_URL:-}" ] || return 0
  printf '  \xe2\x86\xb3 network: %s   (open on your phone — first device? run: fs lan ca)\n' "$FS_LAN_URL"
  fs_lan_firewall_hint
}

# _fs_set_lan_flag <dir> <on|off> — rewrite .folderserver with lan flipped,
# preserving every other setting.
_fs_set_lan_flag() {
  local dir="$1" flag="$2" raw_docroot
  _fs_load_config "$dir"
  raw_docroot="$(fs_config_get "$dir/.folderserver" docroot)"
  fs_write_config "$dir" "$FS_DOMAIN" "$FS_PHP" "$raw_docroot" "$FS_REWRITE" \
    "$FS_DB" "$FS_DB_NAME" "$FS_DB_USER" "$FS_DB_PASS" \
    "$FS_TYPE" "$FS_MODE" "$FS_COMMAND" "$FS_BUILD" "$FS_PORT" "$FS_INSTALL" "$flag"
}

# fs_cmd_lan [on|off|status|ca] — manage LAN exposure for the current site.
#   ca      show the one-time per-device CA-trust guide (no site needed)
#   on      set lan=on; publish now if the site is up
#   off     set lan=off; remove the LAN block now
#   status  (default) report whether this site is exposed, and its URL
fs_cmd_lan() {
  local sub="${1:-status}" dir="$PWD"
  [ "$sub" = ca ] && { fs_lan_ca; return 0; }

  [ -f "$dir/.folderserver" ] || { echo "fs: no .folderserver in $dir (run 'fs init' first)" >&2; return 1; }
  _fs_load_config "$dir"
  local host lp
  host="$(fs_local_host 2>/dev/null || true)"
  lp="$(fs_lan_port_get "$FS_DOMAIN")"

  case "$sub" in
    on)
      _fs_set_lan_flag "$dir" on; FS_LAN=on
      echo "lan=on for $FS_DOMAIN"
      if [ -f "$FS_CADDY_SITES/$FS_DOMAIN.caddy" ]; then
        _fs_publish_lan_if_on "$FS_DOMAIN"; fs_caddy_reload || true
        fs_lan_report
      else
        echo "Run 'fs up' to publish it to the network."
      fi ;;
    off)
      _fs_set_lan_flag "$dir" off
      fs_remove_lan_site "$FS_DOMAIN"; fs_caddy_reload || true
      echo "lan=off for $FS_DOMAIN (removed from the network)" ;;
    status)
      if [ -f "$FS_CADDY_SITES/$FS_DOMAIN.lan.caddy" ] && [ -n "$host" ] && [ -n "$lp" ]; then
        echo "$FS_DOMAIN is on the network:  https://$host:$lp"
      elif fs_db_enabled "$FS_LAN"; then
        echo "$FS_DOMAIN has lan=on but isn't published yet — run 'fs up'."
      else
        echo "$FS_DOMAIN is not on the network (run 'fs lan on', then 'fs up')."
      fi ;;
    *) echo "fs: usage: fs lan [on|off|status|ca]" >&2; return 2 ;;
  esac
}

# echo an installed PHP version (prefers 8.4) — for zero-config `fs serve`.
fs_pick_php() {
  local v
  for v in 8.4 8.5 8.3; do
    [ -x "$FS_BREW_OPT/php@$v/bin/php" ] && { printf '%s\n' "$v"; return 0; }
  done
  printf '8.4\n'
}

# true only if some php@8.x is actually installed. Distinct from fs_pick_php,
# which always names a version (falling back to 8.4). Used to decide whether the
# zero-config default is PHP or a plain static server.
fs_have_php() {
  local v
  for v in 8.4 8.5 8.3; do
    [ -x "$FS_BREW_OPT/php@$v/bin/php" ] && return 0
  done
  return 1
}

# fs_cmd_serve [dir] — zero-config quick serve: if there's no .folderserver,
# write a minimal one (default domain, no MySQL/routing) and bring it up. Uses
# PHP when installed, otherwise a plain static server. `fs serve` → see the page.
fs_cmd_serve() {
  local dir="${1:-$PWD}" phpv
  if [ ! -f "$dir/.folderserver" ]; then
    if fs_have_php; then
      phpv="$(fs_pick_php)"
      fs_write_config "$dir" "$(fs_default_domain "$dir")" "$phpv" "" "" off "" "" "" php dev "" "" "" ""
      echo "Created $dir/.folderserver (php $phpv)"
    else
      fs_write_config "$dir" "$(fs_default_domain "$dir")" "" "" "" off "" "" "" static dev "" "" "" ""
      echo "Created $dir/.folderserver (static)"
    fi
  fi
  fs_cmd_up "$dir" || return 1
  _fs_load_config "$dir"
  "$FS_OPEN_BIN" "https://$FS_DOMAIN" >/dev/null 2>&1 || true
}

: "${FS_OPEN_BIN:=open}"
: "${FS_TAIL_BIN:=tail}"

# fs_site_status <domain> — running (live process) | served (static, no process)
# | stopped. A build (static) site has no process but is up while its snippet exists.
fs_site_status() {
  local d="$1"
  if fs_is_running "$d"; then echo running
  elif [ -f "$FS_CADDY_SITES/$d.caddy" ]; then echo served
  else echo stopped
  fi
}

fs_cmd_list() {
  printf '%-32s %-8s %-6s %-10s %s\n' DOMAIN STATUS PORT RUNTIME URL
  local d port runtime status host lp
  host="$(fs_local_host 2>/dev/null || true)"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    port="$(fs_registry_field "$d" 3 2>/dev/null)"; runtime="$(fs_registry_field "$d" 4 2>/dev/null)"
    status="$(fs_site_status "$d")"
    printf '%-32s %-8s %-6s %-10s %s\n' "$d" "$status" "$port" "$runtime" "https://$d"
    if [ -f "$FS_CADDY_SITES/$d.lan.caddy" ] && [ -n "$host" ]; then
      lp="$(fs_lan_port_get "$d")"
      [ -n "$lp" ] && printf '%-32s %s\n' "" "↳ network: https://$host:$lp"
    fi
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

# _fs_have_gum_tty — true only when we can run an interactive gum form.
_fs_have_gum_tty() { [ -t 0 ] && command -v "$FS_GUM_BIN" >/dev/null 2>&1; }

# _fs_prompt_config <domain> <php> <docroot> <rewrite> <db> <db_name> <db_user> <db_pass>
# Interactive gum form (domain, php, docroot, optional routing, optional MySQL).
# Prefilled from the given current values. Sets NC_DOMAIN, NC_PHP, NC_DOCROOT,
# NC_REWRITE, NC_DB, NC_DB_NAME, NC_DB_USER, NC_DB_PASS. Caller ensures TTY+gum.
_fs_prompt_config() {
  local dir="$1" cur_type="$2" d_domain="$3" d_php="$4" d_docroot="$5" d_rewrite="$6"
  local d_db="$7" d_dbname="$8" d_dbuser="$9" d_dbpass="${10}"
  local d_mode="${11:-dev}" d_command="${12:-}" d_port="${13:-}" d_build="${14:-}" d_install="${15:-}"
  local d_lan="${16:-}"

  NC_DOMAIN="$("$FS_GUM_BIN" input --value "$d_domain" --header "Domain")"

  # Runtime — node is offered only when relevant (package.json present or the
  # project is already node). For everything else the PHP-version prompt below
  # doubles as the runtime picker: choosing "static" means serve files, no PHP.
  NC_TYPE=php
  if fs_detect_node "$dir" || [ "$cur_type" = node ]; then
    NC_TYPE="$("$FS_GUM_BIN" choose node php --selected "${cur_type:-node}" --header "Runtime")"
  fi

  NC_PHP="$d_php"; NC_DOCROOT=""; NC_REWRITE=""
  NC_MODE=dev; NC_COMMAND=""; NC_BUILD=""; NC_PORT=""; NC_INSTALL=""

  if [ "$NC_TYPE" = node ]; then
    NC_MODE="$("$FS_GUM_BIN" choose dev build --selected "$d_mode" --header "Mode (dev server or static build)")"
    if [ "$NC_MODE" = build ]; then
      NC_BUILD="$("$FS_GUM_BIN" input --value "${d_build:-$(fs_detect_command "$dir" build)}" --header "Build command")"
      NC_DOCROOT="$("$FS_GUM_BIN" input --value "${d_docroot:-$(fs_detect_output "$dir")}" --header "Output folder to serve")"
      if "$FS_GUM_BIN" confirm --default=false "SPA fallback to index.html (client-side routing)?"; then
        NC_REWRITE="${d_rewrite:-index.html}"
      fi
    else
      NC_COMMAND="$("$FS_GUM_BIN" input --value "${d_command:-$(fs_detect_command "$dir" dev)}" --header "Dev command")"
      NC_PORT="$("$FS_GUM_BIN" input --value "$d_port" --placeholder "$(fs_detect_port "$dir") (blank = auto-assign)" --header "Dev server port")"
    fi
    local inst_def=--default; fs_db_enabled "$d_install" || [ -z "$d_install" ] || inst_def=--default=false
    NC_INSTALL=off
    if "$FS_GUM_BIN" confirm "$inst_def" "Auto-install dependencies on 'fs up' when missing?"; then NC_INSTALL=on; fi
  else
    # PHP version — or "static" (no PHP, just serve the folder). Preselect
    # static when the project already is static.
    local php_sel="$d_php"; [ "$cur_type" = static ] && php_sel=static
    NC_PHP="$("$FS_GUM_BIN" choose 8.4 8.5 8.3 static --selected "$php_sel" --header "PHP version (or 'static' for no PHP)")"
    if [ "$NC_PHP" = static ]; then
      NC_TYPE=static; NC_PHP=""
      NC_DOCROOT="$("$FS_GUM_BIN" input --value "$d_docroot" --placeholder "public/dist (blank = folder root)" --header "Folder to serve")"
    else
      NC_DOCROOT="$("$FS_GUM_BIN" input --value "$d_docroot" --placeholder "public (blank = folder root)" --header "Docroot")"
      local rw_def=--default=false; [ -n "$d_rewrite" ] && rw_def=--default
      if "$FS_GUM_BIN" confirm "$rw_def" "Front-controller routing (.htaccess-style rewrite)?"; then
        NC_REWRITE="$("$FS_GUM_BIN" input --value "${d_rewrite:-index.php}" --header "Router script")"
      fi
    fi
  fi

  # MySQL — available for either runtime.
  NC_DB=off; NC_DB_NAME=""; NC_DB_USER=""; NC_DB_PASS=""
  local db_def=--default=false; fs_db_enabled "$d_db" && db_def=--default
  if "$FS_GUM_BIN" confirm "$db_def" "Enable MySQL for this project?"; then
    NC_DB=on
    NC_DB_NAME="$("$FS_GUM_BIN" input --value "${d_dbname:-$(fs_default_dbname "$dir")}" --header "Database name")"
    NC_DB_USER="$("$FS_GUM_BIN" input --value "${d_dbuser:-app}" --header "Database user")"
    NC_DB_PASS="$("$FS_GUM_BIN" input --password --value "$d_dbpass" --header "Database password")"
  fi

  # LAN exposure — available for either runtime.
  NC_LAN=off
  local lan_def=--default=false; fs_db_enabled "$d_lan" && lan_def=--default
  if "$FS_GUM_BIN" confirm "$lan_def" "Expose to the local network (open on phones/tablets)?"; then
    NC_LAN=on
  fi
}

# _fs_runtime_label <type> <mode> <php> — the registry's runtime column, matching
# what each `fs up` path records: "php <ver>" / "node dev" / "node build" / "static".
_fs_runtime_label() {
  case "$1" in
    static) echo "static" ;;
    node)   [ "$2" = build ] && echo "node build" || echo "node dev" ;;
    *)      echo "php $3" ;;
  esac
}

# _fs_register_from_config <dir> — add a site to the registry from its existing
# .folderserver, without rewriting config or starting it. Directory is stored
# absolute; port is left blank (assigned on the first `fs up`). Shared by init
# and scan so a registered site looks the same however it got there.
_fs_register_from_config() {
  local dir; dir="$(cd "$1" 2>/dev/null && pwd)" || return 1
  _fs_load_config "$dir"
  [ -n "$FS_DOMAIN" ] || return 1
  fs_registry_set "$FS_DOMAIN" "$dir" "" "$(_fs_runtime_label "$FS_TYPE" "$FS_MODE" "$FS_PHP")"
}

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
  # On a --force re-init, remember the prior domain so we can drop its stale
  # registry row if the domain changes.
  local old_domain=""
  [ -f "$file" ] && old_domain="$(fs_config_get "$file" domain 2>/dev/null || true)"
  # node folder → node; else a PHP-free machine → static; else php.
  local detected=php
  if fs_detect_node "$dir"; then detected=node
  elif ! fs_have_php; then detected=static
  fi

  if _fs_have_gum_tty; then
    _fs_prompt_config "$dir" "$detected" "$(fs_default_domain "$dir")" 8.4 "" "" \
      off "$(fs_default_dbname "$dir")" app "" dev "" "" "" "" off
  else
    NC_DOMAIN="$(fs_default_domain "$dir")"; NC_PHP=8.4; NC_DOCROOT=""; NC_REWRITE=""
    NC_DB=off; NC_DB_NAME=""; NC_DB_USER=""; NC_DB_PASS=""
    NC_TYPE=php; NC_MODE=dev; NC_COMMAND=""; NC_BUILD=""; NC_PORT=""; NC_INSTALL=""
    NC_LAN=off
    if [ "$detected" = node ]; then
      # non-interactive in a node folder → sensible node-dev defaults, auto-install on
      NC_TYPE=node
      NC_COMMAND="$(fs_detect_command "$dir" dev)"
      NC_BUILD="$(fs_detect_command "$dir" build)"
      NC_PORT="$(fs_detect_port "$dir")"
      NC_INSTALL=on
    elif [ "$detected" = static ]; then
      # non-interactive with no PHP installed → plain static server
      NC_TYPE=static
    fi
  fi
  fs_write_config "$dir" "$NC_DOMAIN" "$NC_PHP" "$NC_DOCROOT" "$NC_REWRITE" \
    "$NC_DB" "$NC_DB_NAME" "$NC_DB_USER" "$NC_DB_PASS" \
    "$NC_TYPE" "$NC_MODE" "$NC_COMMAND" "$NC_BUILD" "$NC_PORT" "$NC_INSTALL" "$NC_LAN"
  # Register the site immediately so it shows in `fs list` and is picked up by
  # `fs up --all` even before its first `fs up`. On a --force re-init that changed
  # the domain, drop the stale row first.
  [ -n "$old_domain" ] && [ "$old_domain" != "$NC_DOMAIN" ] && fs_registry_remove "$old_domain"
  _fs_register_from_config "$dir"
  echo "Wrote $file"
}

# fs_cmd_scan [dir] — walk dir (default $PWD) for .folderserver files and add each
# discovered site to the registry, without rewriting config or starting anything.
# Handy after cloning a repo or reinstalling: recover the site list in one shot.
fs_cmd_scan() {
  local root="${1:-$PWD}"
  if [ ! -d "$root" ]; then echo "fs: not a directory: $root" >&2; return 1; fi
  local f dir domain existing added=0 unchanged=0 conflicts=0 found=0
  while IFS= read -r f; do
    found=$((found + 1))
    dir="$(cd "$(dirname "$f")" 2>/dev/null && pwd)" || continue
    domain="$(fs_config_get "$f" domain 2>/dev/null || true)"
    if [ -z "$domain" ] || [[ ! "$domain" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "fs: skipping $f — missing or invalid domain" >&2
      continue
    fi
    existing="$(fs_registry_field "$domain" 2 2>/dev/null || true)"
    if [ -n "$existing" ]; then
      if [ "$existing" = "$dir" ]; then
        unchanged=$((unchanged + 1)); echo "unchanged  $domain"
      else
        conflicts=$((conflicts + 1))
        echo "fs: conflict — '$domain' already registered at $existing (found $dir); skipping" >&2
      fi
      continue
    fi
    if _fs_register_from_config "$dir"; then
      added=$((added + 1)); echo "added      $domain → $dir"
    fi
  done < <(find "$root" -type d \( -name node_modules -o -name .git -o -name vendor \) -prune \
             -o -type f -name .folderserver -print)
  if [ "$found" -eq 0 ]; then
    echo "fs: no .folderserver files under $root"
    return 0
  fi
  echo "Scanned: $added added, $unchanged unchanged, $conflicts conflict(s)."
}

# fs_cmd_edit [dir] — interactive editor for an existing .folderserver: change
# PHP version, toggle routing + script name, toggle MySQL + credentials. If the
# site is running, it is restarted afterward so the changes take effect.
fs_cmd_edit() {
  local dir="${1:-$PWD}"
  if [ ! -f "$dir/.folderserver" ]; then
    echo "fs: no .folderserver in $dir (run 'fs init' first)" >&2
    return 1
  fi
  if ! _fs_have_gum_tty; then
    echo "fs: edit needs an interactive terminal with gum installed" >&2
    return 1
  fi
  _fs_load_config "$dir"
  local old_domain="$FS_DOMAIN" was_running=no raw_docroot
  fs_is_running "$FS_DOMAIN" && was_running=yes
  raw_docroot="$(fs_config_get "$dir/.folderserver" docroot)"

  _fs_prompt_config "$dir" "$FS_TYPE" "$FS_DOMAIN" "$FS_PHP" "$raw_docroot" "$FS_REWRITE" \
    "$FS_DB" "$FS_DB_NAME" "$FS_DB_USER" "$FS_DB_PASS" \
    "$FS_MODE" "$FS_COMMAND" "$FS_PORT" "$FS_BUILD" "$FS_INSTALL" "$FS_LAN"
  fs_write_config "$dir" "$NC_DOMAIN" "$NC_PHP" "$NC_DOCROOT" "$NC_REWRITE" \
    "$NC_DB" "$NC_DB_NAME" "$NC_DB_USER" "$NC_DB_PASS" \
    "$NC_TYPE" "$NC_MODE" "$NC_COMMAND" "$NC_BUILD" "$NC_PORT" "$NC_INSTALL" "$NC_LAN"
  echo "Updated $dir/.folderserver"

  # Reconcile the registry with the edited config. The registry is keyed by
  # domain, so a changed domain must drop the old row (or it lingers as a
  # duplicate) and re-register under the new one — matching `fs init --force`.
  # Re-registering also keeps a stopped site's row in sync; the restart path
  # below re-sets it with a live port when the site is running.
  [ "$old_domain" != "$NC_DOMAIN" ] && fs_registry_remove "$old_domain"
  _fs_register_from_config "$dir"

  if [ "$was_running" = yes ]; then
    fs_stop_php "$old_domain"
    fs_remove_router "$old_domain"
    fs_remove_site "$old_domain"
    fs_caddy_reload || true
    fs_cmd_up "$dir" >/dev/null 2>&1 && echo "Restarted to apply changes."
  fi
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

: "${FS_AUTOSTART_PLIST:=$HOME/Library/LaunchAgents/com.folderserver.restore.plist}"
: "${FS_AUTOSTART_LABEL:=com.folderserver.restore}"
: "${FS_LAUNCHCTL_BIN:=launchctl}"

# fs_autostart_render — write the launchd agent plist that runs `fs up --all`
# at login. Split out from fs_cmd_autostart so it's testable without launchctl.
fs_autostart_render() {
  local self
  self="${FS_SELF:-$(command -v fs 2>/dev/null || echo /opt/homebrew/bin/fs)}"
  mkdir -p "$(dirname "$FS_AUTOSTART_PLIST")"
  cat >"$FS_AUTOSTART_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$FS_AUTOSTART_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$self</string>
    <string>up</string>
    <string>--all</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$FS_HOME/log/autostart.log</string>
  <key>StandardErrorPath</key><string>$FS_HOME/log/autostart.log</string>
</dict>
</plist>
EOF
}

fs_cmd_autostart() {
  local action="${1:-status}" domain
  domain="gui/$(id -u)"
  case "$action" in
    on)
      fs_autostart_render
      "$FS_LAUNCHCTL_BIN" bootout "$domain" "$FS_AUTOSTART_PLIST" >/dev/null 2>&1 || true
      "$FS_LAUNCHCTL_BIN" bootstrap "$domain" "$FS_AUTOSTART_PLIST" || true
      echo "autostart on — every known site will start at login (fs up --all)"
      ;;
    off)
      "$FS_LAUNCHCTL_BIN" bootout "$domain" "$FS_AUTOSTART_PLIST" >/dev/null 2>&1 || true
      rm -f "$FS_AUTOSTART_PLIST"
      echo "autostart off"
      ;;
    status)
      if [ -f "$FS_AUTOSTART_PLIST" ]; then echo "autostart: on"; else echo "autostart: off"; fi
      ;;
    *) echo "Usage: fs autostart <on|off|status>" >&2; return 2 ;;
  esac
}

fs_setup_deps() {
  local pkg
  for pkg in $FS_BREW_DEPS; do
    if ! "$FS_BREW_BIN" list "$pkg" >/dev/null 2>&1; then
      echo "Installing $pkg..."; "$FS_BREW_BIN" install "$pkg"
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
  # Install the mkcert local CA into the system trust store so browsers trust
  # the per-site certificates (without this, every site shows an SSL warning).
  # The certs themselves are generated per site on `fs up` (see fs_ensure_site_cert).
  "$FS_MKCERT_BIN" -install || true
}

# fs_ensure_site_cert <domain> — generate a cert for the exact hostname (if it
# doesn't already exist). Browsers reject a shared *.test wildcard, so each site
# gets its own cert.
fs_ensure_site_cert() {
  local domain="$1" cert key
  { read -r cert; read -r key; } < <(fs_cert_paths "$domain")
  [ -f "$cert" ] && [ -f "$key" ] && return 0
  mkdir -p "$FS_CERT_DIR"
  "$FS_MKCERT_BIN" -cert-file "$cert" -key-file "$key" "$domain" >/dev/null 2>&1
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
  echo "==> Installing the mkcert local CA"; fs_setup_cert
  echo "==> Wiring Caddy import"; fs_setup_caddy_config
  cat <<EOF

Almost done. Run these once (they need sudo / your password):

  sudo mkdir -p $FS_RESOLVER_DIR
  echo "nameserver 127.0.0.1" | sudo tee $FS_RESOLVER_DIR/test
  sudo brew services start dnsmasq
  sudo brew services start caddy

PHP: install any versions you need, e.g.  brew install php   (or php@8.3 / php@8.4)
MySQL (only if a project uses db=on):     brew install $FS_MYSQL_FORMULA

Then: cd into a project, run 'fs init' and 'fs up'.
EOF
}
