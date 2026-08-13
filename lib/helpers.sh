# shellcheck shell=bash
# helpers.sh — pure helpers, safe to source. No `set -e` here.
: "${FS_HOME:=$HOME/.folder-server}"

# Homebrew lives at /opt/homebrew on Apple Silicon and /usr/local on Intel, so
# nothing below may hardcode either one. Resolution order, cheapest first:
# HOMEBREW_PREFIX (exported by `brew shellenv`), then the known prefixes, then
# `brew --prefix` as a last resort — it costs ~100ms, so it's the fallback, not
# the default path.
: "${FS_BREW_CANDIDATES:=/opt/homebrew /usr/local}"
fs_brew_prefix() {
  local p
  if [ -n "${HOMEBREW_PREFIX:-}" ]; then printf '%s\n' "$HOMEBREW_PREFIX"; return 0; fi
  for p in $FS_BREW_CANDIDATES; do
    [ -x "$p/bin/brew" ] && { printf '%s\n' "$p"; return 0; }
  done
  if command -v brew >/dev/null 2>&1; then
    p="$(brew --prefix 2>/dev/null)" && [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
  fi
  printf '/opt/homebrew\n'
}
: "${FS_BREW_PREFIX:=$(fs_brew_prefix)}"

: "${FS_BREW_OPT:=$FS_BREW_PREFIX/opt}"
: "${FS_CADDY_SITES:=$FS_BREW_PREFIX/etc/caddy/sites}"
: "${FS_CERT_DIR:=$FS_HOME/certs}"

fs_ensure_home() {
  mkdir -p "$FS_HOME/run" "$FS_HOME/logs" "$FS_CERT_DIR"
  [ -f "$FS_HOME/registry" ] || : >"$FS_HOME/registry"
}

fs_config_get() {
  local file="$1" key="$2" line k v
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) : ;; *) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    # trim leading/trailing whitespace
    k="$(printf '%s' "$k" | awk '{$1=$1;print}')"
    v="$(printf '%s' "$v" | awk '{$1=$1;print}')"
    if [ "$k" = "$key" ]; then printf '%s\n' "$v"; return 0; fi
  done <"$file"
}

fs_default_domain() {
  local dir="$1" base
  base="$(basename "$dir" | tr '[:upper:]' '[:lower:]')"
  printf '%s.test\n' "$base"
}

# A MySQL-safe database name derived from the folder: lowercased, every
# non [a-z0-9] collapsed to a single underscore, trimmed.
fs_default_dbname() {
  local dir="$1" base
  base="$(basename "$dir" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"
  base="$(printf '%s' "$base" | sed -e 's/__*/_/g' -e 's/^_//' -e 's/_$//')"
  [ -n "$base" ] || base="app"
  printf '%s\n' "$base"
}

fs_resolve_config() {
  local dir="$1"
  local file="$dir/.folderserver"
  local domain php docroot rewrite db db_name db_user db_pass
  local type mode command build port install lan
  domain="$(fs_config_get "$file" domain)"; [ -n "$domain" ] || domain="$(fs_default_domain "$dir")"
  php="$(fs_config_get "$file" php)";       [ -n "$php" ] || php="$(fs_pick_php)"
  docroot="$(fs_config_get "$file" docroot)"
  if [ -z "$docroot" ]; then docroot="$dir"
  else case "$docroot" in /*) : ;; *) docroot="$dir/$docroot" ;; esac
  fi
  rewrite="$(fs_config_get "$file" rewrite)"
  db="$(fs_config_get "$file" db)"
  db_name="$(fs_config_get "$file" db_name)"; [ -n "$db_name" ] || db_name="$(fs_default_dbname "$dir")"
  db_user="$(fs_config_get "$file" db_user)"
  db_pass="$(fs_config_get "$file" db_pass)"
  type="$(fs_config_get "$file" type)";     [ -n "$type" ] || type="php"
  mode="$(fs_config_get "$file" mode)";     [ -n "$mode" ] || mode="dev"
  command="$(fs_config_get "$file" command)"; [ -n "$command" ] || command="npm run dev"
  build="$(fs_config_get "$file" build)";   [ -n "$build" ] || build="npm run build"
  port="$(fs_config_get "$file" port)"
  install="$(fs_config_get "$file" install)"
  lan="$(fs_config_get "$file" lan)"
  printf 'domain=%s\nphp=%s\ndocroot=%s\nrewrite=%s\ndb=%s\ndb_name=%s\ndb_user=%s\ndb_pass=%s\ntype=%s\nmode=%s\ncommand=%s\nbuild=%s\nport=%s\ninstall=%s\nlan=%s\n' \
    "$domain" "$php" "$docroot" "$rewrite" "$db" "$db_name" "$db_user" "$db_pass" \
    "$type" "$mode" "$command" "$build" "$port" "$install" "$lan"
}

fs_registry_file() { printf '%s\n' "$FS_HOME/registry"; }

fs_registry_get() {
  local domain="$1"
  local f re
  f="$(fs_registry_file)"
  [ -f "$f" ] || return 1
  re=$(printf '%s' "$domain" | sed 's/[.[\*^$]/\\&/g')
  local line
  line="$(grep -m1 "^${re}|" "$f" 2>/dev/null)" || return 1
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

fs_registry_field() {
  local domain="$1"
  local n="$2"
  local line
  line="$(fs_registry_get "$domain")" || return 1
  printf '%s\n' "$line" | cut -d'|' -f"$n"
}

fs_registry_set() {
  local domain="$1" dir="$2" port="$3" php="$4"
  local f tmp re
  f="$(fs_registry_file)"
  fs_ensure_home
  re=$(printf '%s' "$domain" | sed 's/[.[\*^$]/\\&/g')
  tmp="$(mktemp "${f}.XXXXXX")"
  grep -v "^${re}|" "$f" 2>/dev/null >"$tmp" || true
  printf '%s|%s|%s|%s\n' "$domain" "$dir" "$port" "$php" >>"$tmp"
  mv "$tmp" "$f"
}

fs_registry_remove() {
  local domain="$1"
  local f tmp re
  f="$(fs_registry_file)"
  [ -f "$f" ] || return 0
  re=$(printf '%s' "$domain" | sed 's/[.[\*^$]/\\&/g')
  tmp="$(mktemp "${f}.XXXXXX")"
  grep -v "^${re}|" "$f" 2>/dev/null >"$tmp" || true
  mv "$tmp" "$f"
}

fs_registry_domains() {
  local f
  f="$(fs_registry_file)"
  [ -f "$f" ] || return 0
  cut -d'|' -f1 "$f"
}

fs_port_in_use() {
  local port="$1"
  # In registry?
  if grep -q "|${port}|" "$(fs_registry_file)" 2>/dev/null; then return 0; fi
  # Bound on localhost?
  if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

fs_free_port() {
  local p
  for p in $(seq 8000 8999); do
    if ! fs_port_in_use "$p"; then printf '%s\n' "$p"; return 0; fi
  done
  echo "fs: no free port in 8000-8999" >&2
  return 1
}

fs_php_binary() {
  local ver="$1"
  local path="$FS_BREW_OPT/php@$ver/bin/php"
  if [ -x "$path" ]; then printf '%s\n' "$path"; return 0; fi
  echo "fs: php@$ver not installed (run: brew install php@$ver)" >&2
  return 1
}

# List every installed PHP version, newest first — the single source of truth
# for "what can this machine actually run". Discovered from the brew opt links
# rather than a fixed list, so a new release (8.6) is picked up the day you
# install it and an old one (8.2) is never overlooked.
#
# Sorted numerically by major then minor, so 8.10 correctly outranks 8.5.
fs_php_versions() {
  local p v
  for p in "$FS_BREW_OPT"/php@*/bin/php; do
    [ -x "$p" ] || continue          # no match → the literal glob → skipped
    v="${p#*/php@}"; v="${v%%/*}"
    printf '%s\n' "$v"
  done | sort -t. -k1,1nr -k2,2nr
}

# echo the PHP version to default to — the newest installed. Used for a config
# that doesn't name one, and for the `fs serve` / `fs init` defaults. With no
# PHP at all the runtime default is static (see fs_have_php), so the 8.4 here is
# only a last-resort name for the "install this" error from fs_php_binary.
# Lives here, beside fs_php_binary, so fs_resolve_config can reach it without
# pulling in commands.sh.
fs_pick_php() {
  local newest; newest="$(fs_php_versions | head -1)"
  printf '%s\n' "${newest:-8.4}"
}

# true only if some PHP is actually installed. Distinct from fs_pick_php, which
# always names a version (falling back to 8.4). Used to decide whether the
# zero-config default is PHP or a plain static server.
fs_have_php() {
  [ -n "$(fs_php_versions)" ]
}
