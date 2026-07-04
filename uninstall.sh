#!/usr/bin/env bash
# uninstall.sh — stop the services folder-server started and remove its wiring.
#   ./uninstall.sh           stop services, remove resolver/Caddy import/symlinks
#   ./uninstall.sh --purge   also: brew uninstall deps, remove cert + ~/.folder-server
#   ./uninstall.sh --yes     don't prompt for confirmation
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/lib/helpers.sh"
# shellcheck source=/dev/null
. "$DIR/lib/caddy.sh"

: "${FS_RESOLVER_DIR:=/etc/resolver}"
: "${FS_MYSQL_FORMULA:=mysql}"
: "${PREFIX:=/opt/homebrew/bin}"

PURGE=0 ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    *) echo "usage: uninstall.sh [--purge] [--yes]" >&2; exit 2 ;;
  esac
done

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then gum confirm "$1"; return; fi
  printf '%s [y/N] ' "$1"; local r; read -r r; case "$r" in y|Y) return 0 ;; *) return 1 ;; esac
}
step() { printf '==> %s\n' "$1"; }

echo "This will stop folder-server's services and remove its system wiring."
[ "$PURGE" -eq 1 ] && echo "--purge: also removing brew packages, the certificate, and ~/.folder-server."
confirm "Continue?" || { echo "Aborted."; exit 0; }

# 1. Stop any running project servers (php -S) and clear their Caddy snippets.
if [ -s "$(fs_registry_file)" ]; then
  step "Stopping project servers"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    pf="$FS_HOME/run/$d.pid"; pid="$(cat "$pf" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$pf" "$FS_CADDY_SITES/$d.caddy"
    echo "  stopped $d"
  done < <(fs_registry_domains)
fi

# 2. Stop the shared services.
step "Stopping services (caddy, dnsmasq, mysql)"
sudo brew services stop caddy 2>/dev/null || true
sudo brew services stop dnsmasq 2>/dev/null || true
brew services stop mysql 2>/dev/null || true

# 3. Remove the DNS resolver entry.
if [ -f "$FS_RESOLVER_DIR/test" ]; then
  step "Removing $FS_RESOLVER_DIR/test (needs sudo)"
  sudo rm -f "$FS_RESOLVER_DIR/test"
fi

# 4. Remove the Caddy import line (leave the rest of the Caddyfile intact).
if [ -f "$FS_CADDY_CONFIG" ] && grep -qF "import $FS_CADDY_SITES/*.caddy" "$FS_CADDY_CONFIG"; then
  step "Removing the Caddy import line"
  tmp="$(mktemp)"
  grep -vF "import $FS_CADDY_SITES/*.caddy" "$FS_CADDY_CONFIG" >"$tmp" && mv "$tmp" "$FS_CADDY_CONFIG"
fi

# 5. Remove the CLI symlinks.
step "Removing $PREFIX/fs and $PREFIX/folder-server"
rm -f "$PREFIX/fs" "$PREFIX/folder-server"

if [ "$PURGE" -eq 1 ]; then
  step "Purging brew packages"
  brew uninstall dnsmasq caddy gum fzf 2>/dev/null || true
  if confirm "Also uninstall MySQL ($FS_MYSQL_FORMULA) and delete its data?"; then
    brew uninstall "$FS_MYSQL_FORMULA" 2>/dev/null || true
  fi
  step "Removing dnsmasq config, certificate, and ~/.folder-server"
  rm -f "$FS_DNSMASQ_CONF"
  rm -rf "$FS_CERT_DIR"
  rm -rf "$FS_HOME"
fi

echo
echo "Done. folder-server's services are stopped and its wiring removed."
[ "$PURGE" -eq 0 ] && echo "(brew packages, the certificate, and ~/.folder-server were kept — re-run with --purge to remove them.)"
