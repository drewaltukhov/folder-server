#!/usr/bin/env bash
# uninstall.sh — stop the services folder-server started and remove its wiring.
# Then (interactively) ask whether to also remove the brew packages it installed.
#   ./uninstall.sh          stop services + remove wiring, then ASK about packages
#   ./uninstall.sh --yes     tear down without prompting; keep all packages/data
#   ./uninstall.sh --purge   also remove the installed deps, cert, and ~/.folder-server
# PHP is never removed. MySQL is only removed if you explicitly confirm it.
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

step() { printf '==> %s\n' "$1"; }
# ask <prompt> — interactive y/N (default No). Non-interactive → No.
ask() {
  if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then gum confirm "$1"; return; fi
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1"; local r; read -r r; case "$r" in y|Y) return 0 ;; *) return 1 ;; esac
}

echo "This stops folder-server's services and removes its system wiring"
echo "(the fs symlinks, the /etc/resolver entry, and the Caddy import line)."
if [ "$ASSUME_YES" -eq 0 ] && [ "$PURGE" -eq 0 ]; then
  ask "Continue?" || { echo "Aborted."; exit 0; }
fi

# --- Core teardown: always reversible, removes no packages or data ---

# 1. Stop running project servers (php -S) and clear their Caddy snippets.
if [ -f "$(fs_registry_file)" ] && [ -s "$(fs_registry_file)" ]; then
  step "Stopping project servers"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    pf="$FS_HOME/run/$d.pid"; pid="$(cat "$pf" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$pf" "$FS_CADDY_SITES/$d.caddy"
    echo "  stopped $d"
  done < <(fs_registry_domains)
fi

# 2. Stop the shared services (does not delete anything).
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

echo
echo "folder-server is uninstalled. Its services are stopped and wiring removed."

# --- Optional removal of packages/data — always opt-in ---

remove_deps()  { step "Removing brew packages folder-server installed (dnsmasq, caddy, gum, fzf)"; brew uninstall dnsmasq caddy gum fzf 2>/dev/null || true; }
remove_state() { step "Removing the *.test certificate, dnsmasq config, and ~/.folder-server"; rm -f "$FS_DNSMASQ_CONF"; rm -rf "$FS_CERT_DIR" "$FS_HOME"; }
remove_mysql() { step "Uninstalling MySQL ($FS_MYSQL_FORMULA) and deleting its databases"; brew uninstall "$FS_MYSQL_FORMULA" 2>/dev/null || true; }

if [ "$PURGE" -eq 1 ]; then
  # --purge removes what folder-server installed — but NOT PHP, and NOT MySQL
  # (your databases). MySQL still requires an explicit interactive confirmation.
  remove_deps
  remove_state
  echo "PHP and MySQL were left installed."
elif [ "$ASSUME_YES" -eq 1 ]; then
  echo "Kept all brew packages, the certificate, and ~/.folder-server (--yes)."
  echo "Re-run with --purge, or interactively, to remove them."
else
  echo
  echo "Optionally remove what folder-server installed (PHP is never touched):"
  ask "Remove the brew packages it installed — dnsmasq, caddy, gum, fzf?" && remove_deps
  ask "Remove the *.test certificate and ~/.folder-server state?" && remove_state
  if ask "Uninstall MySQL too and DELETE all its databases? (you use it — say No to keep it)"; then
    remove_mysql
  else
    echo "  Kept MySQL and its data."
  fi
fi

echo
echo "Done."
