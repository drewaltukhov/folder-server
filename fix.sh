#!/usr/bin/env bash
# fix.sh — audit the folder-server setup and offer to repair what's broken.
#   ./fix.sh            interactive: prompt before each fix
#   ./fix.sh --yes      apply every fix without prompting
#   ./fix.sh --dry-run  report only, never change anything
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/lib/helpers.sh"
# shellcheck source=/dev/null
. "$DIR/lib/deps.sh"
# shellcheck source=/dev/null
. "$DIR/lib/caddy.sh"
# shellcheck source=/dev/null
. "$DIR/lib/commands.sh"

: "${FS_RESOLVER_DIR:=/etc/resolver}"
: "${FS_MYSQL_FORMULA:=mysql}"

MODE=prompt
for a in "$@"; do
  case "$a" in
    --yes|-y) MODE=yes ;;
    --dry-run|-n) MODE=dry ;;
    *) echo "usage: fix.sh [--yes|--dry-run]" >&2; exit 2 ;;
  esac
done

problems=0; fixed=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; problems=$((problems+1)); }
info() { printf '    %s\n' "$1"; }
# Caddy caches certs in memory: a `reload` won't pick up a regenerated cert,
# only a restart does. Needs sudo (caddy runs in the system launchd domain).
restart_caddy() { sudo brew services restart caddy >/dev/null 2>&1 || true; }

# ask <prompt> — true if the user wants the fix applied (respects MODE).
ask() {
  case "$MODE" in
    yes) return 0 ;;
    dry) info "(dry-run) would: $1"; return 1 ;;
  esac
  if command -v gum >/dev/null 2>&1 && [ -t 0 ]; then
    gum confirm "Fix: $1?"
  else
    printf '    Fix: %s? [y/N] ' "$1"
    local r; read -r r
    case "$r" in y|Y) return 0 ;; *) return 1 ;; esac
  fi
}

echo "folder-server — setup check"
echo

# 1. Homebrew dependencies
for pkg in $FS_BREW_DEPS; do
  if brew list "$pkg" >/dev/null 2>&1; then ok "$pkg installed"
  else
    bad "$pkg not installed"
    if ask "brew install $pkg"; then brew install "$pkg" && fixed=$((fixed+1)); fi
  fi
done

# 2. dnsmasq *.test rule
if [ -f "$FS_DNSMASQ_CONF" ] && grep -qF "address=/.test/127.0.0.1" "$FS_DNSMASQ_CONF"; then
  ok "dnsmasq resolves *.test"
else
  bad "dnsmasq missing the *.test rule ($FS_DNSMASQ_CONF)"
  if ask "write the *.test rule"; then fs_setup_dnsmasq && fixed=$((fixed+1)); fi
fi

# 3. /etc/resolver/test
if [ -f "$FS_RESOLVER_DIR/test" ] && grep -qF "127.0.0.1" "$FS_RESOLVER_DIR/test"; then
  ok "resolver $FS_RESOLVER_DIR/test present"
else
  bad "resolver $FS_RESOLVER_DIR/test missing (needs sudo)"
  if ask "create $FS_RESOLVER_DIR/test"; then
    sudo mkdir -p "$FS_RESOLVER_DIR" && echo "nameserver 127.0.0.1" | sudo tee "$FS_RESOLVER_DIR/test" >/dev/null && fixed=$((fixed+1))
  fi
fi

# 4. mkcert local CA installed & trusted by the keychain (what browsers use).
# An untrusted CA is the #1 cause of "your connection is not private". Per-site
# certs are generated on `fs up`; here we only verify the CA.
CAROOT="$(mkcert -CAROOT 2>/dev/null || true)"
if [ -n "$CAROOT" ] && [ -f "$CAROOT/rootCA.pem" ] && security verify-cert -c "$CAROOT/rootCA.pem" >/dev/null 2>&1; then
  ok "mkcert local CA installed and trusted"
else
  bad "mkcert local CA not installed/trusted — browsers will show SSL warnings"
  if ask "run mkcert -install to trust the local CA"; then
    "$FS_MKCERT_BIN" -install && fixed=$((fixed+1))
  fi
fi

# 4b. old wildcard-based snippets (pre per-site certs) — browsers reject *.test.
if ls "$FS_CADDY_SITES"/*.caddy >/dev/null 2>&1 && grep -lF "_wildcard.test" "$FS_CADDY_SITES"/*.caddy >/dev/null 2>&1; then
  bad "some site snippets still use the old *.test wildcard cert (browsers reject it)"
  if ask "regenerate all sites with per-site certs (fs down --all + up --all) and restart Caddy"; then
    fs_cmd_down --all >/dev/null 2>&1 || true
    fs_cmd_up --all >/dev/null 2>&1 || true
    restart_caddy && fixed=$((fixed+1))
  fi
fi

# 5. Caddy import line
if [ -f "$FS_CADDY_CONFIG" ] && grep -qF "import $FS_CADDY_SITES/*.caddy" "$FS_CADDY_CONFIG"; then
  ok "Caddyfile imports site snippets"
else
  bad "Caddyfile missing the site import"
  if ask "add the import line"; then fs_setup_caddy_config && fixed=$((fixed+1)); fi
fi

# 6. dnsmasq + caddy actually running (check the process, not `brew services`
# status — they're started via `sudo brew services` in the system domain, which
# a user-context `brew services list` reports as "none").
for svc in dnsmasq caddy; do
  if pgrep -x "$svc" >/dev/null 2>&1; then ok "$svc running"
  else
    bad "$svc not running"
    if ask "sudo brew services start $svc"; then sudo brew services start "$svc" && fixed=$((fixed+1)); fi
  fi
done

# 7. *.test actually resolves to localhost
if command -v dig >/dev/null 2>&1; then
  if [ "$(dig +short @127.0.0.1 fix-check.test 2>/dev/null | head -1)" = "127.0.0.1" ]; then
    ok "*.test resolves to 127.0.0.1"
  else
    bad "*.test does not resolve (dnsmasq/resolver not active yet)"
    info "usually fixed by the dnsmasq + resolver steps above, then: sudo brew services restart dnsmasq"
  fi
fi

# 7b. a system proxy/VPN that swallows *.test — the classic "loads in Chrome but
# not Safari". Safari/CFNetwork honors the system proxy, which can't reach a local
# loopback site; Chrome and curl bypass loopback, so only Safari breaks. Advisory
# only: the fix lives in the proxy app (editing macOS bypass here gets overwritten).
if scutil --proxy 2>/dev/null | grep -qE '^[[:space:]]*HTTPS?Enable[[:space:]]*:[[:space:]]*1'; then
  if scutil --proxy 2>/dev/null | grep -qiE ':[[:space:]]*(\*\.)?test[[:space:]]*$'; then
    ok "system proxy active, *.test is bypassed"
  else
    bad "a system proxy/VPN is active but *.test is NOT bypassed — Safari won't load .test sites"
    info "Safari obeys the system proxy; Chrome/curl bypass loopback, so they still work."
    info "Add *.test to the proxy's bypass/skip-proxy list (e.g. Shadowrocket → [General] skip-proxy),"
    info "or System Settings → Network → Proxies → 'Bypass proxy settings for these Hosts & Domains'."
    info "Verify: scutil --proxy | grep test"
  fi
fi

# 8. MySQL health (only if installed — it's opt-in)
if command -v "$FS_MYSQL_FORMULA" >/dev/null 2>&1 || brew list "$FS_MYSQL_FORMULA" >/dev/null 2>&1; then
  instances="$(pgrep -f 'mysql/bin/mysqld ' 2>/dev/null | wc -l | tr -d ' ')"
  reachable=no
  "$FS_MYSQL_FORMULA" -uroot -e 'SELECT 1' >/dev/null 2>&1 && reachable=yes
  status="$(brew services list 2>/dev/null | awk '/^mysql /{print $2}')"
  if [ "$reachable" = yes ] && [ "${instances:-0}" -le 1 ] && [ "$status" = started ]; then
    ok "MySQL healthy (started, reachable, single instance)"
  else
    bad "MySQL unhealthy (status=$status, reachable=$reachable, mysqld instances=$instances)"
    info "duplicate/stale mysqld processes are the usual cause of 'error 1' on start"
    if ask "stop all mysqld and start one clean instance"; then
      brew services stop mysql >/dev/null 2>&1 || true
      launchctl bootout "gui/$(id -u)/homebrew.mxcl.mysql" 2>/dev/null || true
      pkill -9 -f mysqld_safe 2>/dev/null || true; sleep 1
      pkill -9 -f 'mysql/bin/mysqld' 2>/dev/null || true; sleep 2
      brew services start mysql && fixed=$((fixed+1))
    fi
  fi
else
  info "MySQL not installed (only needed for projects with db=on): brew install $FS_MYSQL_FORMULA"
fi

# 9. stale site processes (registry says a port, but nothing is serving it)
if [ -s "$(fs_registry_file)" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    pf="$FS_HOME/run/$d.pid"
    if [ -f "$pf" ]; then
      pid="$(cat "$pf" 2>/dev/null)"
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        bad "$d has a stale pidfile (process $pid is gone)"
        if ask "remove the stale pidfile for $d"; then rm -f "$pf" && fixed=$((fixed+1)); fi
      fi
    fi
  done < <(fs_registry_domains)
fi

echo
if [ "$problems" -eq 0 ]; then
  echo "All checks passed — nothing to fix."
else
  echo "Found $problems problem(s); fixed $fixed."
  [ "$MODE" = dry ] && echo "(dry-run — re-run without --dry-run to apply)"
fi
