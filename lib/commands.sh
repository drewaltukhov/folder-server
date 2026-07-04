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
  while IFS='=' read -r k v; do
    case "$k" in
      install) FS_INSTALL="$v" ;;
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
  fs_caddy_reload || true
  [ -n "$dir" ] && rm -f "$dir/.folderserver"
  fs_registry_remove "$domain"
}

fs_cmd_unbind() {
  local dir="${1:-$PWD}"
  _fs_load_config "$dir"
  fs_unbind_domain "$FS_DOMAIN" "$dir"
  echo "Unbound $FS_DOMAIN (stopped, removed .folderserver, forgot the site)"
}

# _fs_each_site <fn> — run <fn> for every known site, passing its directory.
# One site failing does not stop the rest.
_fs_each_site() {
  local fn="$1" d dir any=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    dir="$(fs_registry_field "$d" 2 2>/dev/null || true)"
    [ -n "$dir" ] || continue
    any=1
    "$fn" "$dir" || echo "fs: '$fn' failed for $d" >&2
  done < <(fs_registry_domains)
  [ "$any" -eq 1 ] || echo "fs: no known sites yet (run 'fs init' + 'fs up' in a project)"
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
  local router=""
  if [ -n "$FS_REWRITE" ]; then
    if [[ ! "$FS_REWRITE" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "fs: invalid rewrite '$FS_REWRITE' (must be a front-controller filename in the docroot, e.g. index.php)" >&2
      return 1
    fi
    fs_write_router "$FS_DOMAIN" "$FS_REWRITE"
    router="$(fs_router_file "$FS_DOMAIN")"
  fi
  local phpbin
  local port
  phpbin="$(fs_php_binary "$FS_PHP")" || return 1
  port="$(fs_registry_field "$FS_DOMAIN" 3 2>/dev/null || true)"
  [ -n "$port" ] || port="$(fs_free_port)" || return 1
  fs_start_php "$FS_DOMAIN" "$phpbin" "$port" "$FS_DOCROOT" "$router" || return 1
  fs_ensure_site_cert "$FS_DOMAIN"
  fs_write_site "$FS_DOMAIN" "$port"
  fs_registry_set "$FS_DOMAIN" "$dir" "$port" "php $FS_PHP"
  fs_caddy_reload || true
  if [ -n "$FS_REWRITE" ]; then
    echo "Serving $dir → https://$FS_DOMAIN (php $FS_PHP, port $port, rewrite → $FS_REWRITE)"
  else
    echo "Serving $dir → https://$FS_DOMAIN (php $FS_PHP, port $port)"
  fi
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
  fs_caddy_reload || true
  echo "Serving $dir → https://$FS_DOMAIN (node dev: $FS_COMMAND, port $actual)"
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
  fs_caddy_reload || true
  echo "Serving $dir → https://$FS_DOMAIN (static from $FS_DOCROOT)"
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
  local d port runtime status
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    port="$(fs_registry_field "$d" 3 2>/dev/null)"; runtime="$(fs_registry_field "$d" 4 2>/dev/null)"
    status="$(fs_site_status "$d")"
    printf '%-32s %-8s %-6s %-10s %s\n' "$d" "$status" "$port" "$runtime" "https://$d"
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

  NC_DOMAIN="$("$FS_GUM_BIN" input --value "$d_domain" --header "Domain")"

  # Runtime — only offered when node is relevant (package.json present, or the
  # project is already node). Detected runtime is the default, but overridable.
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
    NC_PHP="$("$FS_GUM_BIN" choose 8.4 8.5 8.3 --selected "$d_php" --header "PHP version")"
    NC_DOCROOT="$("$FS_GUM_BIN" input --value "$d_docroot" --placeholder "public (blank = folder root)" --header "Docroot")"
    local rw_def=--default=false; [ -n "$d_rewrite" ] && rw_def=--default
    if "$FS_GUM_BIN" confirm "$rw_def" "Front-controller routing (.htaccess-style rewrite)?"; then
      NC_REWRITE="$("$FS_GUM_BIN" input --value "${d_rewrite:-index.php}" --header "Router script")"
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
  local detected=php
  fs_detect_node "$dir" && detected=node

  if _fs_have_gum_tty; then
    _fs_prompt_config "$dir" "$detected" "$(fs_default_domain "$dir")" 8.4 "" "" \
      off "$(fs_default_dbname "$dir")" app "" dev "" "" "" ""
  else
    NC_DOMAIN="$(fs_default_domain "$dir")"; NC_PHP=8.4; NC_DOCROOT=""; NC_REWRITE=""
    NC_DB=off; NC_DB_NAME=""; NC_DB_USER=""; NC_DB_PASS=""
    NC_TYPE=php; NC_MODE=dev; NC_COMMAND=""; NC_BUILD=""; NC_PORT=""; NC_INSTALL=""
    if [ "$detected" = node ]; then
      # non-interactive in a node folder → sensible node-dev defaults, auto-install on
      NC_TYPE=node
      NC_COMMAND="$(fs_detect_command "$dir" dev)"
      NC_BUILD="$(fs_detect_command "$dir" build)"
      NC_PORT="$(fs_detect_port "$dir")"
      NC_INSTALL=on
    fi
  fi
  fs_write_config "$dir" "$NC_DOMAIN" "$NC_PHP" "$NC_DOCROOT" "$NC_REWRITE" \
    "$NC_DB" "$NC_DB_NAME" "$NC_DB_USER" "$NC_DB_PASS" \
    "$NC_TYPE" "$NC_MODE" "$NC_COMMAND" "$NC_BUILD" "$NC_PORT" "$NC_INSTALL"
  echo "Wrote $file"
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
    "$FS_MODE" "$FS_COMMAND" "$FS_PORT" "$FS_BUILD" "$FS_INSTALL"
  fs_write_config "$dir" "$NC_DOMAIN" "$NC_PHP" "$NC_DOCROOT" "$NC_REWRITE" \
    "$NC_DB" "$NC_DB_NAME" "$NC_DB_USER" "$NC_DB_PASS" \
    "$NC_TYPE" "$NC_MODE" "$NC_COMMAND" "$NC_BUILD" "$NC_PORT" "$NC_INSTALL"
  echo "Updated $dir/.folderserver"

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

fs_setup_deps() {
  local pkg
  for pkg in dnsmasq caddy gum fzf; do
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
  echo "==> Generating wildcard certificate"; fs_setup_cert
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
