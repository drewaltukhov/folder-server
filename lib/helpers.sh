# shellcheck shell=bash
# helpers.sh — pure helpers, safe to source. No `set -e` here.
: "${FS_HOME:=$HOME/.folder-server}"
: "${FS_BREW_OPT:=/opt/homebrew/opt}"
: "${FS_CADDY_SITES:=/opt/homebrew/etc/caddy/sites}"
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
  domain="$(fs_config_get "$file" domain)"; [ -n "$domain" ] || domain="$(fs_default_domain "$dir")"
  php="$(fs_config_get "$file" php)";       [ -n "$php" ] || php="8.4"
  docroot="$(fs_config_get "$file" docroot)"
  if [ -z "$docroot" ]; then docroot="$dir"
  else case "$docroot" in /*) : ;; *) docroot="$dir/$docroot" ;; esac
  fi
  rewrite="$(fs_config_get "$file" rewrite)"
  db="$(fs_config_get "$file" db)"
  db_name="$(fs_config_get "$file" db_name)"; [ -n "$db_name" ] || db_name="$(fs_default_dbname "$dir")"
  db_user="$(fs_config_get "$file" db_user)"
  db_pass="$(fs_config_get "$file" db_pass)"
  printf 'domain=%s\nphp=%s\ndocroot=%s\nrewrite=%s\ndb=%s\ndb_name=%s\ndb_user=%s\ndb_pass=%s\n' \
    "$domain" "$php" "$docroot" "$rewrite" "$db" "$db_name" "$db_user" "$db_pass"
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
