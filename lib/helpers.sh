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

fs_resolve_config() {
  local dir="$1"
  local file="$dir/.folderserver"
  local domain php docroot
  domain="$(fs_config_get "$file" domain)"; [ -n "$domain" ] || domain="$(fs_default_domain "$dir")"
  php="$(fs_config_get "$file" php)";       [ -n "$php" ] || php="8.4"
  docroot="$(fs_config_get "$file" docroot)"
  if [ -z "$docroot" ]; then docroot="$dir"
  else case "$docroot" in /*) : ;; *) docroot="$dir/$docroot" ;; esac
  fi
  printf 'domain=%s\nphp=%s\ndocroot=%s\n' "$domain" "$php" "$docroot"
}

fs_registry_file() { printf '%s\n' "$FS_HOME/registry"; }

fs_registry_get() {
  local domain="$1"
  local f
  f="$(fs_registry_file)"
  [ -f "$f" ] || return 1
  local line
  line="$(grep -m1 "^${domain}|" "$f" 2>/dev/null)" || return 1
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
  local f tmp
  f="$(fs_registry_file)"
  fs_ensure_home
  tmp="$(mktemp)"
  grep -v "^${domain}|" "$f" 2>/dev/null >"$tmp" || true
  printf '%s|%s|%s|%s\n' "$domain" "$dir" "$port" "$php" >>"$tmp"
  mv "$tmp" "$f"
}

fs_registry_remove() {
  local domain="$1"
  local f tmp
  f="$(fs_registry_file)"
  [ -f "$f" ] || return 0
  tmp="$(mktemp)"
  grep -v "^${domain}|" "$f" 2>/dev/null >"$tmp" || true
  mv "$tmp" "$f"
}

fs_registry_domains() {
  local f
  f="$(fs_registry_file)"
  [ -f "$f" ] || return 0
  cut -d'|' -f1 "$f"
}
