# folder-server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a brew-based, per-folder local PHP dev environment for macOS that serves any folder at `https://<name>.test`, replacing MAMP Pro with shell scripts plus a live TUI dashboard.

**Architecture:** A single `folder-server` bash CLI (aliased `fs`) composes small, individually-testable helper functions. Each project runs its own `php -S` process; an always-on Caddy service reverse-proxies `<name>.test` to it with mkcert-backed HTTPS; dnsmasq resolves `*.test` to localhost. State lives in `~/.folder-server/`. A pure-shell dashboard reuses the same helpers.

**Tech Stack:** Bash, Caddy, dnsmasq, mkcert, gum, fzf (all Homebrew); `php@8.3/8.4/8.5`; `bats-core` for tests.

## Global Constraints

- **Bash 3.2 compatible** (macOS system bash). No associative arrays, no `${var,,}`/`${var^^}`, no `mapfile`/`readarray`. Lowercase via `tr '[:upper:]' '[:lower:]'`.
- **Shebang** `#!/usr/bin/env bash` on every script; `set -euo pipefail` in the entrypoint (not in sourced libs, so `return 1` works).
- **Testability via overridable env vars**, all with defaults: `FS_HOME` (default `$HOME/.folder-server`), `FS_BREW_OPT` (default `/opt/homebrew/opt`), `FS_CADDY_SITES` (default `/opt/homebrew/etc/caddy/sites`), `FS_CADDY_BIN` (default `caddy`), `FS_BREW_BIN` (default `brew`), `FS_CERT_DIR` (default `$FS_HOME/certs`). Helpers MUST read these, never hardcode paths.
- **TLD** is `.test`. HTTPS cert is a single wildcard `*.test` from mkcert.
- **Registry format:** one line per site, pipe-delimited: `domain|dir|port|php`.
- **shellcheck clean** (`shellcheck -x`).
- **All code lives under** `bin/`, `lib/`, `templates/`; tests under `test/`.

---

## File Structure

```
folder-server/
  bin/folder-server          # entrypoint: set -euo pipefail, sources lib, dispatches subcommands
  lib/helpers.sh             # config, registry, port, php-binary helpers (pure, unit-tested)
  lib/caddy.sh               # site snippet render/write/remove + reload
  lib/process.sh             # php -S start/stop, pidfile, is_running
  lib/commands.sh            # up/down/restart/list/open/logs/init/db/setup subcommand fns
  lib/dashboard.sh           # fs dash live TUI loop
  templates/site.caddy.tmpl  # per-site Caddy snippet template
  install.sh                 # symlink bin/folder-server + create `fs` alias hint
  test/test_helper.bash      # shared bats setup: temp FS_HOME, stub PATH
  test/*.bats                # one .bats file per lib
  README.md
```

---

## Task 1: Project scaffold, entrypoint dispatch, and test harness

**Files:**
- Create: `bin/folder-server`
- Create: `lib/helpers.sh`
- Create: `test/test_helper.bash`
- Create: `test/dispatch.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: `folder-server <subcommand>` dispatch; `fs_lib_dir` resolves the repo `lib/` dir; sourcing convention where `bin/folder-server` sources every `lib/*.sh`.

- [ ] **Step 1: Write the failing test**

`test/test_helper.bash`:
```bash
# Shared setup for all bats files.
setup_common() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  FS_BIN="$REPO_ROOT/bin/folder-server"
  export FS_HOME="$BATS_TEST_TMPDIR/fshome"
  export FS_BREW_OPT="$BATS_TEST_TMPDIR/opt"
  export FS_CADDY_SITES="$BATS_TEST_TMPDIR/caddy-sites"
  export FS_CERT_DIR="$FS_HOME/certs"
  mkdir -p "$FS_HOME" "$FS_BREW_OPT" "$FS_CADDY_SITES"
}
# Put a stub executable named $1 on PATH that echoes its args to $2 log.
make_stub() {
  local name="$1" logfile="${2:-$BATS_TEST_TMPDIR/${1}.log}"
  local dir="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$dir"
  cat >"$dir/$name" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$logfile"
exit 0
EOF
  chmod +x "$dir/$name"
  export PATH="$dir:$PATH"
}
```

`test/dispatch.bats`:
```bash
load test_helper
setup() { setup_common; }

@test "no args prints usage and exits non-zero" {
  run "$FS_BIN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: fs"* ]]
}

@test "help subcommand prints usage and exits zero" {
  run "$FS_BIN" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: fs"* ]]
}

@test "unknown subcommand errors" {
  run "$FS_BIN" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command: bogus"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/dispatch.bats`
Expected: FAIL (`$FS_BIN` does not exist / not executable).

- [ ] **Step 3: Write minimal implementation**

`lib/helpers.sh` (start it — more added later):
```bash
# helpers.sh — pure helpers, safe to source. No `set -e` here.
: "${FS_HOME:=$HOME/.folder-server}"
: "${FS_BREW_OPT:=/opt/homebrew/opt}"
: "${FS_CADDY_SITES:=/opt/homebrew/etc/caddy/sites}"
: "${FS_CERT_DIR:=$FS_HOME/certs}"

fs_ensure_home() {
  mkdir -p "$FS_HOME/run" "$FS_HOME/logs" "$FS_CERT_DIR"
  [ -f "$FS_HOME/registry" ] || : >"$FS_HOME/registry"
}
```

`bin/folder-server`:
```bash
#!/usr/bin/env bash
set -euo pipefail

fs_lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd; }
LIB="$(fs_lib_dir)"
# shellcheck source=/dev/null
for f in helpers caddy process commands dashboard; do
  [ -f "$LIB/$f.sh" ] && . "$LIB/$f.sh"
done

fs_usage() {
  cat <<'EOF'
Usage: fs <command> [args]

  setup             One-time machine setup (dnsmasq, caddy, cert, deps)
  init              Create a .folderserver config in the current folder
  up                Start serving the current folder
  down              Stop serving the current folder
  restart           Restart the current folder
  list              List all known sites and their status
  open              Open the current folder's URL in the browser
  logs              Tail the current folder's PHP log
  db start|stop|status   Control the shared MySQL service
  dash              Live TUI dashboard
  help              Show this help
EOF
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || { fs_usage; return 2; }
  shift || true
  case "$cmd" in
    help|-h|--help) fs_usage ;;
    version|-v|--version) echo "folder-server 0.1.0" ;;
    setup)   fs_cmd_setup "$@" ;;
    init)    fs_cmd_init "$@" ;;
    up)      fs_cmd_up "$@" ;;
    down)    fs_cmd_down "$@" ;;
    restart) fs_cmd_restart "$@" ;;
    list)    fs_cmd_list "$@" ;;
    open)    fs_cmd_open "$@" ;;
    logs)    fs_cmd_logs "$@" ;;
    db)      fs_cmd_db "$@" ;;
    dash)    fs_cmd_dash "$@" ;;
    *) echo "fs: unknown command: $cmd" >&2; fs_usage >&2; return 127 ;;
  esac
}
main "$@"
```

Make it executable: `chmod +x bin/folder-server`. (Only `helpers.sh` exists now; the `for` loop tolerates missing files, and `help`/unknown paths don't call the not-yet-defined command functions.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/dispatch.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
chmod +x bin/folder-server
git add bin/folder-server lib/helpers.sh test/test_helper.bash test/dispatch.bats
git commit -m "feat: scaffold folder-server CLI dispatch + bats harness"
```

---

## Task 2: Config parsing helpers

**Files:**
- Modify: `lib/helpers.sh`
- Create: `test/config.bats`

**Interfaces:**
- Consumes: `helpers.sh` env vars.
- Produces:
  - `fs_config_get <file> <key>` → echoes the value for `key` (trimmed), empty if absent. Ignores blank lines and `#` comments.
  - `fs_default_domain <dir>` → echoes `<basename-lowercased>.test`.
  - `fs_resolve_config <dir>` → echoes three lines `domain=…`, `php=…`, `docroot=…` using `.folderserver` in `<dir>` with defaults (domain=default_domain, php=`8.4`, docroot=`<dir>`).

- [ ] **Step 1: Write the failing test**

`test/config.bats`:
```bash
load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  PROJ="$BATS_TEST_TMPDIR/My-Project"
  mkdir -p "$PROJ"
}

@test "fs_config_get reads a key" {
  printf 'domain=foo.test\nphp=8.5\n' >"$PROJ/.folderserver"
  run fs_config_get "$PROJ/.folderserver" php
  [ "$output" = "8.5" ]
}

@test "fs_config_get ignores comments and blanks and trims spaces" {
  printf '# comment\n\n  domain = bar.test \n' >"$PROJ/.folderserver"
  run fs_config_get "$PROJ/.folderserver" domain
  [ "$output" = "bar.test" ]
}

@test "fs_config_get returns empty for missing key" {
  printf 'domain=foo.test\n' >"$PROJ/.folderserver"
  run fs_config_get "$PROJ/.folderserver" php
  [ -z "$output" ]
}

@test "fs_default_domain lowercases basename and adds .test" {
  run fs_default_domain "$PROJ"
  [ "$output" = "my-project.test" ]
}

@test "fs_resolve_config fills defaults when file absent" {
  run fs_resolve_config "$PROJ"
  [[ "$output" == *"domain=my-project.test"* ]]
  [[ "$output" == *"php=8.4"* ]]
  [[ "$output" == *"docroot=$PROJ"* ]]
}

@test "fs_resolve_config honors file values" {
  printf 'domain=custom.test\nphp=8.5\ndocroot=public\n' >"$PROJ/.folderserver"
  run fs_resolve_config "$PROJ"
  [[ "$output" == *"domain=custom.test"* ]]
  [[ "$output" == *"php=8.5"* ]]
  [[ "$output" == *"docroot=$PROJ/public"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/config.bats`
Expected: FAIL (`fs_config_get: command not found`).

- [ ] **Step 3: Write minimal implementation**

Append to `lib/helpers.sh`:
```bash
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
  local dir="$1" file="$dir/.folderserver" domain php docroot
  domain="$(fs_config_get "$file" domain)"; [ -n "$domain" ] || domain="$(fs_default_domain "$dir")"
  php="$(fs_config_get "$file" php)";       [ -n "$php" ] || php="8.4"
  docroot="$(fs_config_get "$file" docroot)"
  if [ -z "$docroot" ]; then docroot="$dir"
  else case "$docroot" in /*) : ;; *) docroot="$dir/$docroot" ;; esac
  fi
  printf 'domain=%s\nphp=%s\ndocroot=%s\n' "$domain" "$php" "$docroot"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/config.bats`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/helpers.sh test/config.bats
git commit -m "feat: config parsing + resolution helpers"
```

---

## Task 3: Registry helpers

**Files:**
- Modify: `lib/helpers.sh`
- Create: `test/registry.bats`

**Interfaces:**
- Consumes: `FS_HOME`, `fs_ensure_home`.
- Produces (registry file `$FS_HOME/registry`, lines `domain|dir|port|php`):
  - `fs_registry_get <domain>` → echoes the full line; returns 1 if absent.
  - `fs_registry_field <domain> <n>` → echoes field `n` (1=domain,2=dir,3=port,4=php); returns 1 if absent.
  - `fs_registry_set <domain> <dir> <port> <php>` → upsert (replace existing line for domain, else append).
  - `fs_registry_remove <domain>` → delete the line.
  - `fs_registry_domains` → echo each domain, one per line.

- [ ] **Step 1: Write the failing test**

`test/registry.bats`:
```bash
load test_helper
setup() { setup_common; . "$REPO_ROOT/lib/helpers.sh"; fs_ensure_home; }

@test "set then get returns the line" {
  fs_registry_set foo.test /p/foo 8000 8.4
  run fs_registry_get foo.test
  [ "$status" -eq 0 ]
  [ "$output" = "foo.test|/p/foo|8000|8.4" ]
}

@test "get missing returns nonzero" {
  run fs_registry_get nope.test
  [ "$status" -ne 0 ]
}

@test "set upserts (no duplicate lines)" {
  fs_registry_set foo.test /p/foo 8000 8.4
  fs_registry_set foo.test /p/foo 8001 8.5
  run bash -c "grep -c '^foo.test|' \"$FS_HOME/registry\""
  [ "$output" = "1" ]
  run fs_registry_field foo.test 3
  [ "$output" = "8001" ]
}

@test "field extracts the requested column" {
  fs_registry_set bar.test /p/bar 8002 8.3
  run fs_registry_field bar.test 4
  [ "$output" = "8.3" ]
}

@test "remove deletes the line" {
  fs_registry_set foo.test /p/foo 8000 8.4
  fs_registry_remove foo.test
  run fs_registry_get foo.test
  [ "$status" -ne 0 ]
}

@test "domains lists all" {
  fs_registry_set a.test /p/a 8000 8.4
  fs_registry_set b.test /p/b 8001 8.4
  run fs_registry_domains
  [[ "$output" == *"a.test"* ]]
  [[ "$output" == *"b.test"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/registry.bats`
Expected: FAIL (`fs_registry_set: command not found`).

- [ ] **Step 3: Write minimal implementation**

Append to `lib/helpers.sh`:
```bash
fs_registry_file() { printf '%s\n' "$FS_HOME/registry"; }

fs_registry_get() {
  local domain="$1" f; f="$(fs_registry_file)"
  [ -f "$f" ] || return 1
  local line; line="$(grep -m1 "^${domain}|" "$f" 2>/dev/null)" || return 1
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

fs_registry_field() {
  local domain="$1" n="$2" line
  line="$(fs_registry_get "$domain")" || return 1
  printf '%s\n' "$line" | cut -d'|' -f"$n"
}

fs_registry_set() {
  local domain="$1" dir="$2" port="$3" php="$4" f tmp
  f="$(fs_registry_file)"; fs_ensure_home
  tmp="$(mktemp)"
  grep -v "^${domain}|" "$f" 2>/dev/null >"$tmp" || true
  printf '%s|%s|%s|%s\n' "$domain" "$dir" "$port" "$php" >>"$tmp"
  mv "$tmp" "$f"
}

fs_registry_remove() {
  local domain="$1" f tmp; f="$(fs_registry_file)"
  [ -f "$f" ] || return 0
  tmp="$(mktemp)"
  grep -v "^${domain}|" "$f" 2>/dev/null >"$tmp" || true
  mv "$tmp" "$f"
}

fs_registry_domains() {
  local f; f="$(fs_registry_file)"
  [ -f "$f" ] || return 0
  cut -d'|' -f1 "$f"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/registry.bats`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/helpers.sh test/registry.bats
git commit -m "feat: registry helpers (upsert/get/field/remove/list)"
```

---

## Task 4: Port allocation and PHP binary resolution

**Files:**
- Modify: `lib/helpers.sh`
- Create: `test/port_php.bats`

**Interfaces:**
- Consumes: `FS_BREW_OPT`, registry helpers.
- Produces:
  - `fs_port_in_use <port>` → returns 0 if the TCP port is bound OR present in the registry, else 1. (Overridable behavior for tests via the registry check; live check uses `nc -z 127.0.0.1 <port>`.)
  - `fs_free_port` → echoes the first free port in 8000–8999 (skips ports in registry and bound ports).
  - `fs_php_binary <version>` → echoes `$FS_BREW_OPT/php@<version>/bin/php` if it exists (else, if version equals the default `php` formula path, that); returns 1 with a message if not installed.

- [ ] **Step 1: Write the failing test**

`test/port_php.bats`:
```bash
load test_helper
setup() { setup_common; . "$REPO_ROOT/lib/helpers.sh"; fs_ensure_home; }

@test "fs_free_port returns a port in range" {
  run fs_free_port
  [ "$status" -eq 0 ]
  [ "$output" -ge 8000 ]
  [ "$output" -le 8999 ]
}

@test "fs_free_port skips ports already in the registry" {
  # Occupy 8000 via registry; free_port must not return it.
  fs_registry_set a.test /p/a 8000 8.4
  # Force the live check to always say 'free' so only registry matters.
  fs_port_in_use() { fs_registry_domains >/dev/null; grep -q "|$1|" "$(fs_registry_file)"; }
  run fs_free_port
  [ "$output" != "8000" ]
}

@test "fs_php_binary returns path when installed" {
  mkdir -p "$FS_BREW_OPT/php@8.4/bin"
  printf '#!/bin/sh\n' >"$FS_BREW_OPT/php@8.4/bin/php"
  chmod +x "$FS_BREW_OPT/php@8.4/bin/php"
  run fs_php_binary 8.4
  [ "$status" -eq 0 ]
  [ "$output" = "$FS_BREW_OPT/php@8.4/bin/php" ]
}

@test "fs_php_binary errors when not installed" {
  run fs_php_binary 9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"brew install php@9.9"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/port_php.bats`
Expected: FAIL (`fs_free_port: command not found`).

- [ ] **Step 3: Write minimal implementation**

Append to `lib/helpers.sh`:
```bash
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
  local ver="$1" path="$FS_BREW_OPT/php@$ver/bin/php"
  if [ -x "$path" ]; then printf '%s\n' "$path"; return 0; fi
  echo "fs: php@$ver not installed (run: brew install php@$ver)" >&2
  return 1
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/port_php.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/helpers.sh test/port_php.bats
git commit -m "feat: free-port allocation and php binary resolution"
```

---

## Task 5: Caddy site snippet render/write/remove + reload

**Files:**
- Create: `templates/site.caddy.tmpl`
- Create: `lib/caddy.sh`
- Create: `test/caddy.bats`

**Interfaces:**
- Consumes: `FS_CADDY_SITES`, `FS_CERT_DIR`, `FS_CADDY_BIN`, template file.
- Produces:
  - `fs_cert_paths` → echoes two lines: cert path and key path (`$FS_CERT_DIR/_wildcard.test.pem` / `-key.pem`).
  - `fs_render_site <domain> <port>` → echoes the rendered snippet.
  - `fs_write_site <domain> <port>` → writes `$FS_CADDY_SITES/<domain>.caddy`.
  - `fs_remove_site <domain>` → deletes that file.
  - `fs_caddy_reload` → runs `"$FS_CADDY_BIN" reload --config <root>` (root path from `fs_caddy_config_path`, default `/opt/homebrew/etc/Caddyfile`, overridable via `FS_CADDY_CONFIG`).

- [ ] **Step 1: Write the failing test**

`templates/site.caddy.tmpl` uses placeholders `{{DOMAIN}}`, `{{PORT}}`, `{{CERT}}`, `{{KEY}}`.

`test/caddy.bats`:
```bash
load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/caddy.sh"
  export FS_CADDY_CONFIG="$BATS_TEST_TMPDIR/Caddyfile"
}

@test "render substitutes domain, port and cert paths" {
  run fs_render_site foo.test 8000
  [[ "$output" == *"foo.test {"* ]]
  [[ "$output" == *"reverse_proxy 127.0.0.1:8000"* ]]
  [[ "$output" == *"$FS_CERT_DIR/_wildcard.test.pem"* ]]
}

@test "write_site creates a file, remove_site deletes it" {
  fs_write_site bar.test 8001
  [ -f "$FS_CADDY_SITES/bar.test.caddy" ]
  grep -q "127.0.0.1:8001" "$FS_CADDY_SITES/bar.test.caddy"
  fs_remove_site bar.test
  [ ! -f "$FS_CADDY_SITES/bar.test.caddy" ]
}

@test "caddy_reload invokes the caddy binary with reload" {
  make_stub caddy "$BATS_TEST_TMPDIR/caddy.log"
  export FS_CADDY_BIN=caddy
  run fs_caddy_reload
  [ "$status" -eq 0 ]
  grep -q "reload" "$BATS_TEST_TMPDIR/caddy.log"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/caddy.bats`
Expected: FAIL (`lib/caddy.sh` missing).

- [ ] **Step 3: Write minimal implementation**

`templates/site.caddy.tmpl`:
```
{{DOMAIN}} {
	tls {{CERT}} {{KEY}}
	reverse_proxy 127.0.0.1:{{PORT}}
}
```

`lib/caddy.sh`:
```bash
: "${FS_CADDY_BIN:=caddy}"
: "${FS_CADDY_CONFIG:=/opt/homebrew/etc/Caddyfile}"

fs_caddy_template() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../templates" && pwd
}

fs_cert_paths() {
  printf '%s\n%s\n' "$FS_CERT_DIR/_wildcard.test.pem" "$FS_CERT_DIR/_wildcard.test-key.pem"
}

fs_render_site() {
  local domain="$1" port="$2" tmpl cert key
  tmpl="$(fs_caddy_template)/site.caddy.tmpl"
  { read -r cert; read -r key; } < <(fs_cert_paths)
  sed -e "s|{{DOMAIN}}|$domain|g" \
      -e "s|{{PORT}}|$port|g" \
      -e "s|{{CERT}}|$cert|g" \
      -e "s|{{KEY}}|$key|g" "$tmpl"
}

fs_write_site() {
  local domain="$1" port="$2"
  mkdir -p "$FS_CADDY_SITES"
  fs_render_site "$domain" "$port" >"$FS_CADDY_SITES/$domain.caddy"
}

fs_remove_site() {
  rm -f "$FS_CADDY_SITES/$1.caddy"
}

fs_caddy_reload() {
  "$FS_CADDY_BIN" reload --config "$FS_CADDY_CONFIG" >/dev/null 2>&1 \
    || { echo "fs: caddy reload failed" >&2; return 1; }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/caddy.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add templates/site.caddy.tmpl lib/caddy.sh test/caddy.bats
git commit -m "feat: caddy site snippet render/write/remove + reload"
```

---

## Task 6: PHP process control (start/stop/is_running)

**Files:**
- Create: `lib/process.sh`
- Create: `test/process.bats`

**Interfaces:**
- Consumes: `FS_HOME`.
- Produces:
  - `fs_pidfile <domain>` → echoes `$FS_HOME/run/<domain>.pid`.
  - `fs_logfile <domain>` → echoes `$FS_HOME/logs/<domain>.log`.
  - `fs_is_running <domain>` → returns 0 if pidfile exists and the PID is alive.
  - `fs_start_php <domain> <phpbin> <port> <docroot>` → `nohup <phpbin> -S 127.0.0.1:<port> -t <docroot>` in background, writes pidfile, redirects to logfile; returns 1 if already running.
  - `fs_stop_php <domain>` → kills the PID, removes the pidfile; no-op if not running.

- [ ] **Step 1: Write the failing test**

`test/process.bats`:
```bash
load test_helper
setup() { setup_common; . "$REPO_ROOT/lib/helpers.sh"; . "$REPO_ROOT/lib/process.sh"; fs_ensure_home; }

@test "is_running false when no pidfile" {
  run fs_is_running ghost.test
  [ "$status" -ne 0 ]
}

@test "start then is_running true, then stop then false" {
  # Use `sleep` as a stand-in long-running process via a fake php binary.
  local fake="$BATS_TEST_TMPDIR/php"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
exec sleep 30
EOF
  chmod +x "$fake"
  fs_start_php demo.test "$fake" 8123 "$BATS_TEST_TMPDIR"
  run fs_is_running demo.test
  [ "$status" -eq 0 ]
  [ -f "$(fs_pidfile demo.test)" ]
  fs_stop_php demo.test
  run fs_is_running demo.test
  [ "$status" -ne 0 ]
  [ ! -f "$(fs_pidfile demo.test)" ]
}

@test "start refuses if already running" {
  local fake="$BATS_TEST_TMPDIR/php"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$fake"; chmod +x "$fake"
  fs_start_php dup.test "$fake" 8124 "$BATS_TEST_TMPDIR"
  run fs_start_php dup.test "$fake" 8124 "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  fs_stop_php dup.test
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/process.bats`
Expected: FAIL (`lib/process.sh` missing).

- [ ] **Step 3: Write minimal implementation**

`lib/process.sh`:
```bash
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
  local log pf; log="$(fs_logfile "$domain")"; pf="$(fs_pidfile "$domain")"
  nohup "$phpbin" -S "127.0.0.1:$port" -t "$docroot" >"$log" 2>&1 &
  echo "$!" >"$pf"
}

fs_stop_php() {
  local domain="$1" pf pid; pf="$(fs_pidfile "$domain")"
  [ -f "$pf" ] || return 0
  pid="$(cat "$pf" 2>/dev/null)"
  [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
  rm -f "$pf"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/process.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/process.sh test/process.bats
git commit -m "feat: php -S process control with pidfiles"
```

---

## Task 7: `up`, `down`, `restart` commands

**Files:**
- Create: `lib/commands.sh`
- Create: `test/commands_up.bats`

**Interfaces:**
- Consumes: all helpers from Tasks 2–6.
- Produces:
  - `fs_cmd_up [dir]` → resolves config for `dir` (default `$PWD`), resolves php binary, allocates/reuses port from registry, starts php, writes+reloads caddy, upserts registry, prints the URL.
  - `fs_cmd_down [dir]` → stops php, removes site, reloads caddy for the current domain (does not delete the registry entry, so the port stays stable).
  - `fs_cmd_restart [dir]` → down then up.

- [ ] **Step 1: Write the failing test**

`test/commands_up.bats`:
```bash
load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/caddy.sh"
  . "$REPO_ROOT/lib/process.sh"
  . "$REPO_ROOT/lib/commands.sh"
  fs_ensure_home
  make_stub caddy "$BATS_TEST_TMPDIR/caddy.log"; export FS_CADDY_BIN=caddy
  export FS_CADDY_CONFIG="$BATS_TEST_TMPDIR/Caddyfile"
  # Fake php binary that stays alive.
  mkdir -p "$FS_BREW_OPT/php@8.4/bin"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$FS_BREW_OPT/php@8.4/bin/php"
  chmod +x "$FS_BREW_OPT/php@8.4/bin/php"
  PROJ="$BATS_TEST_TMPDIR/site1"; mkdir -p "$PROJ"
}
teardown() { fs_cmd_down "$PROJ" >/dev/null 2>&1 || true; }

@test "up starts php, writes caddy snippet, registers, prints url" {
  run fs_cmd_up "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://site1.test"* ]]
  fs_is_running site1.test
  [ -f "$FS_CADDY_SITES/site1.test.caddy" ]
  run fs_registry_get site1.test
  [ "$status" -eq 0 ]
  grep -q "reload" "$BATS_TEST_TMPDIR/caddy.log"
}

@test "down stops php and removes snippet but keeps registry" {
  fs_cmd_up "$PROJ" >/dev/null
  fs_cmd_down "$PROJ"
  run fs_is_running site1.test
  [ "$status" -ne 0 ]
  [ ! -f "$FS_CADDY_SITES/site1.test.caddy" ]
  run fs_registry_get site1.test
  [ "$status" -eq 0 ]
}

@test "up reuses the stored port on a second up" {
  fs_cmd_up "$PROJ" >/dev/null
  local p1; p1="$(fs_registry_field site1.test 3)"
  fs_cmd_down "$PROJ"
  fs_cmd_up "$PROJ" >/dev/null
  local p2; p2="$(fs_registry_field site1.test 3)"
  [ "$p1" = "$p2" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/commands_up.bats`
Expected: FAIL (`lib/commands.sh` missing).

- [ ] **Step 3: Write minimal implementation**

`lib/commands.sh`:
```bash
# Resolve config for a dir into three vars via eval-safe parsing.
_fs_load_config() {
  local dir="$1" line
  FS_DOMAIN=""; FS_PHP=""; FS_DOCROOT=""
  while IFS='=' read -r k v; do
    case "$k" in
      domain) FS_DOMAIN="$v" ;;
      php) FS_PHP="$v" ;;
      docroot) FS_DOCROOT="$v" ;;
    esac
  done < <(fs_resolve_config "$dir")
}

fs_cmd_up() {
  local dir="${1:-$PWD}"
  _fs_load_config "$dir"
  local phpbin port
  phpbin="$(fs_php_binary "$FS_PHP")" || return 1
  port="$(fs_registry_field "$FS_DOMAIN" 3 2>/dev/null || true)"
  [ -n "$port" ] || port="$(fs_free_port)" || return 1
  fs_start_php "$FS_DOMAIN" "$phpbin" "$port" "$FS_DOCROOT" || return 1
  fs_write_site "$FS_DOMAIN" "$port"
  fs_registry_set "$FS_DOMAIN" "$dir" "$port" "$FS_PHP"
  fs_caddy_reload || true
  echo "Serving $dir → https://$FS_DOMAIN (php $FS_PHP, port $port)"
}

fs_cmd_down() {
  local dir="${1:-$PWD}"
  _fs_load_config "$dir"
  fs_stop_php "$FS_DOMAIN"
  fs_remove_site "$FS_DOMAIN"
  fs_caddy_reload || true
  echo "Stopped $FS_DOMAIN"
}

fs_cmd_restart() {
  fs_cmd_down "$@"
  fs_cmd_up "$@"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/commands_up.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/commands.sh test/commands_up.bats
git commit -m "feat: up/down/restart commands"
```

---

## Task 8: `list`, `open`, `logs` commands

**Files:**
- Modify: `lib/commands.sh`
- Create: `test/commands_list.bats`

**Interfaces:**
- Consumes: registry + process helpers.
- Produces:
  - `fs_cmd_list` → prints a header and one row per registry domain: `domain  status  port  php  url`, where status is `running`/`stopped` from `fs_is_running`.
  - `fs_cmd_open [dir]` → resolves domain for dir, runs `open "https://<domain>"` (via `FS_OPEN_BIN`, default `open`).
  - `fs_cmd_logs [dir]` → `tail -n 50 -f` the logfile (via `FS_TAIL_BIN`, default `tail`); if no logfile, prints a notice and returns 0.

- [ ] **Step 1: Write the failing test**

`test/commands_list.bats`:
```bash
load test_helper
setup() {
  setup_common
  for l in helpers process commands; do . "$REPO_ROOT/lib/$l.sh"; done
  . "$REPO_ROOT/lib/caddy.sh"
  fs_ensure_home
}

@test "list shows registered sites with status" {
  fs_registry_set a.test /p/a 8000 8.4
  run fs_cmd_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"a.test"* ]]
  [[ "$output" == *"stopped"* ]]
  [[ "$output" == *"https://a.test"* ]]
}

@test "open invokes the opener with the url" {
  fs_registry_set a.test /p/a 8000 8.4
  make_stub open "$BATS_TEST_TMPDIR/open.log"; export FS_OPEN_BIN=open
  PROJ="$BATS_TEST_TMPDIR/a"; mkdir -p "$PROJ"
  printf 'domain=a.test\n' >"$PROJ/.folderserver"
  run fs_cmd_open "$PROJ"
  [ "$status" -eq 0 ]
  grep -q "https://a.test" "$BATS_TEST_TMPDIR/open.log"
}

@test "logs notices when no log exists" {
  PROJ="$BATS_TEST_TMPDIR/b"; mkdir -p "$PROJ"
  printf 'domain=b.test\n' >"$PROJ/.folderserver"
  run fs_cmd_logs "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no log"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/commands_list.bats`
Expected: FAIL (`fs_cmd_list: command not found`).

- [ ] **Step 3: Write minimal implementation**

Append to `lib/commands.sh`:
```bash
: "${FS_OPEN_BIN:=open}"
: "${FS_TAIL_BIN:=tail}"

fs_cmd_list() {
  printf '%-24s %-8s %-6s %-4s %s\n' DOMAIN STATUS PORT PHP URL
  local d dir port php status
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    dir="$(fs_registry_field "$d" 2)"; port="$(fs_registry_field "$d" 3)"; php="$(fs_registry_field "$d" 4)"
    if fs_is_running "$d"; then status="running"; else status="stopped"; fi
    printf '%-24s %-8s %-6s %-4s %s\n' "$d" "$status" "$port" "$php" "https://$d"
  done < <(fs_registry_domains)
}

fs_cmd_open() {
  local dir="${1:-$PWD}"; _fs_load_config "$dir"
  "$FS_OPEN_BIN" "https://$FS_DOMAIN"
}

fs_cmd_logs() {
  local dir="${1:-$PWD}"; _fs_load_config "$dir"
  local log; log="$(fs_logfile "$FS_DOMAIN")"
  if [ ! -f "$log" ]; then echo "fs: no log for $FS_DOMAIN yet"; return 0; fi
  "$FS_TAIL_BIN" -n 50 -f "$log"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/commands_list.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/commands.sh test/commands_list.bats
git commit -m "feat: list/open/logs commands"
```

---

## Task 9: `init` command

**Files:**
- Modify: `lib/commands.sh`
- Create: `test/commands_init.bats`

**Interfaces:**
- Consumes: `fs_default_domain`, `gum` (optional; via `FS_GUM_BIN`, default `gum`).
- Produces:
  - `fs_cmd_init [dir]` → writes `.folderserver` in `dir` (default `$PWD`). Interactive with gum when available AND stdin is a TTY; otherwise non-interactive using defaults (domain=default, php=`8.4`, docroot empty). Refuses to overwrite an existing file unless `--force` is passed.

- [ ] **Step 1: Write the failing test**

`test/commands_init.bats`:
```bash
load test_helper
setup() {
  setup_common
  for l in helpers commands; do . "$REPO_ROOT/lib/$l.sh"; done
  PROJ="$BATS_TEST_TMPDIR/My-App"; mkdir -p "$PROJ"
}

@test "init writes defaults non-interactively" {
  run fs_cmd_init "$PROJ"
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.folderserver" ]
  grep -q "domain=my-app.test" "$PROJ/.folderserver"
  grep -q "php=8.4" "$PROJ/.folderserver"
}

@test "init refuses to overwrite without --force" {
  printf 'domain=existing.test\n' >"$PROJ/.folderserver"
  run fs_cmd_init "$PROJ"
  [ "$status" -ne 0 ]
  grep -q "existing.test" "$PROJ/.folderserver"
}

@test "init --force overwrites" {
  printf 'domain=existing.test\n' >"$PROJ/.folderserver"
  run fs_cmd_init "$PROJ" --force
  [ "$status" -eq 0 ]
  grep -q "domain=my-app.test" "$PROJ/.folderserver"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/commands_init.bats`
Expected: FAIL (`fs_cmd_init: command not found`).

- [ ] **Step 3: Write minimal implementation**

Append to `lib/commands.sh`:
```bash
: "${FS_GUM_BIN:=gum}"

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
    echo "fs: $file exists (use --force to overwrite)" >&2; return 1
  fi
  local domain php docroot
  domain="$(fs_default_domain "$dir")"; php="8.4"; docroot=""
  if [ -t 0 ] && command -v "$FS_GUM_BIN" >/dev/null 2>&1; then
    domain="$("$FS_GUM_BIN" input --value "$domain" --prompt "Domain: ")"
    php="$("$FS_GUM_BIN" choose 8.4 8.5 8.3 --header "PHP version")"
    docroot="$("$FS_GUM_BIN" input --placeholder "public (blank = folder root)" --prompt "Docroot: ")"
  fi
  {
    printf 'domain=%s\n' "$domain"
    printf 'php=%s\n' "$php"
    [ -n "$docroot" ] && printf 'docroot=%s\n' "$docroot"
  } >"$file"
  echo "Wrote $file"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/commands_init.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/commands.sh test/commands_init.bats
git commit -m "feat: init command (gum-interactive with non-interactive fallback)"
```

---

## Task 10: `db` command (shared MySQL on demand)

**Files:**
- Modify: `lib/commands.sh`
- Create: `test/commands_db.bats`

**Interfaces:**
- Consumes: `brew` (via `FS_BREW_BIN`, default `brew`); a configurable formula name `FS_MYSQL_FORMULA` (default `mysql`).
- Produces:
  - `fs_cmd_db <start|stop|status>` → runs `brew services <action> <formula>` (mapping `status`→`list`). Unknown action returns 2 with usage.

- [ ] **Step 1: Write the failing test**

`test/commands_db.bats`:
```bash
load test_helper
setup() {
  setup_common
  for l in helpers commands; do . "$REPO_ROOT/lib/$l.sh"; done
  make_stub brew "$BATS_TEST_TMPDIR/brew.log"; export FS_BREW_BIN=brew
  export FS_MYSQL_FORMULA=mysql
}

@test "db start runs brew services start mysql" {
  run fs_cmd_db start
  [ "$status" -eq 0 ]
  grep -q "services start mysql" "$BATS_TEST_TMPDIR/brew.log"
}

@test "db stop runs brew services stop mysql" {
  run fs_cmd_db stop
  grep -q "services stop mysql" "$BATS_TEST_TMPDIR/brew.log"
}

@test "db status maps to brew services list" {
  run fs_cmd_db status
  grep -q "services list" "$BATS_TEST_TMPDIR/brew.log"
}

@test "db with bad action errors" {
  run fs_cmd_db frobnicate
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/commands_db.bats`
Expected: FAIL (`fs_cmd_db: command not found`).

- [ ] **Step 3: Write minimal implementation**

Append to `lib/commands.sh`:
```bash
: "${FS_BREW_BIN:=brew}"
: "${FS_MYSQL_FORMULA:=mysql}"

fs_cmd_db() {
  local action="${1:-}"
  case "$action" in
    start) "$FS_BREW_BIN" services start "$FS_MYSQL_FORMULA" ;;
    stop)  "$FS_BREW_BIN" services stop "$FS_MYSQL_FORMULA" ;;
    status) "$FS_BREW_BIN" services list ;;
    *) echo "Usage: fs db <start|stop|status>" >&2; return 2 ;;
  esac
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/commands_db.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/commands.sh test/commands_db.bats
git commit -m "feat: db command wrapping brew services for MySQL"
```

---

## Task 11: `setup` command (idempotent machine setup)

**Files:**
- Modify: `lib/commands.sh`
- Create: `test/commands_setup.bats`

**Interfaces:**
- Consumes: `brew`, `mkcert`, `dnsmasq`/`caddy` config paths — all overridable: `FS_BREW_BIN`, `FS_MKCERT_BIN` (default `mkcert`), `FS_DNSMASQ_CONF` (default `/opt/homebrew/etc/dnsmasq.d/test.conf`), `FS_RESOLVER_DIR` (default `/etc/resolver`), `FS_CADDY_CONFIG`.
- Produces:
  - `fs_setup_deps` → `brew install` any missing of `dnsmasq caddy gum fzf` (checked via `brew list`).
  - `fs_setup_dnsmasq` → write `address=/.test/127.0.0.1` to `FS_DNSMASQ_CONF` if not already present (idempotent).
  - `fs_setup_cert` → if wildcard cert missing, run `mkcert -cert-file … -key-file … "*.test"` into `FS_CERT_DIR`.
  - `fs_setup_caddy_config` → ensure the root Caddyfile contains an `import <FS_CADDY_SITES>/*.caddy` line (idempotent).
  - `fs_cmd_setup` → runs the above in order, printing progress; the privileged/service steps (`brew services`, writing `/etc/resolver/test`) are printed as instructions when not writable rather than failing.

Note: this task's tests only cover the pure/idempotent file-writing helpers with overridden paths. Service start and `/etc/resolver` creation are guarded and verified manually (see spec Testing).

- [ ] **Step 1: Write the failing test**

`test/commands_setup.bats`:
```bash
load test_helper
setup() {
  setup_common
  for l in helpers caddy commands; do . "$REPO_ROOT/lib/$l.sh"; done
  export FS_DNSMASQ_CONF="$BATS_TEST_TMPDIR/dnsmasq-test.conf"
  export FS_CADDY_CONFIG="$BATS_TEST_TMPDIR/Caddyfile"
  export FS_MKCERT_BIN=mkcert
  fs_ensure_home
}

@test "setup_dnsmasq writes the wildcard line once (idempotent)" {
  fs_setup_dnsmasq
  fs_setup_dnsmasq
  run grep -c "address=/.test/127.0.0.1" "$FS_DNSMASQ_CONF"
  [ "$output" = "1" ]
}

@test "setup_caddy_config adds the import line once" {
  fs_setup_caddy_config
  fs_setup_caddy_config
  run grep -c "import $FS_CADDY_SITES/\*.caddy" "$FS_CADDY_CONFIG"
  [ "$output" = "1" ]
}

@test "setup_cert invokes mkcert with wildcard when cert missing" {
  make_stub mkcert "$BATS_TEST_TMPDIR/mkcert.log"; export FS_MKCERT_BIN=mkcert
  fs_setup_cert
  grep -q '\*.test' "$BATS_TEST_TMPDIR/mkcert.log"
}

@test "setup_cert is skipped when cert already exists" {
  make_stub mkcert "$BATS_TEST_TMPDIR/mkcert.log"; export FS_MKCERT_BIN=mkcert
  : >"$FS_CERT_DIR/_wildcard.test.pem"
  : >"$FS_CERT_DIR/_wildcard.test-key.pem"
  fs_setup_cert
  [ ! -f "$BATS_TEST_TMPDIR/mkcert.log" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/commands_setup.bats`
Expected: FAIL (`fs_setup_dnsmasq: command not found`).

- [ ] **Step 3: Write minimal implementation**

Append to `lib/commands.sh`:
```bash
: "${FS_MKCERT_BIN:=mkcert}"
: "${FS_DNSMASQ_CONF:=/opt/homebrew/etc/dnsmasq.d/test.conf}"
: "${FS_RESOLVER_DIR:=/etc/resolver}"

fs_setup_deps() {
  local pkg
  for pkg in dnsmasq caddy gum fzf; do
    if ! "$FS_BREW_BIN" list "$pkg" >/dev/null 2>&1; then
      echo "Installing $pkg…"; "$FS_BREW_BIN" install "$pkg"
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
  local cert key
  { read -r cert; read -r key; } < <(fs_cert_paths)
  if [ -f "$cert" ] && [ -f "$key" ]; then return 0; fi
  mkdir -p "$FS_CERT_DIR"
  "$FS_MKCERT_BIN" -cert-file "$cert" -key-file "$key" "*.test"
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

Then: cd into a project, run 'fs init' and 'fs up'.
EOF
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/commands_setup.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/commands.sh test/commands_setup.bats
git commit -m "feat: idempotent setup command (deps, dnsmasq, cert, caddy wiring)"
```

---

## Task 12: `dash` live TUI dashboard

**Files:**
- Create: `lib/dashboard.sh`
- Create: `test/dashboard.bats`

**Interfaces:**
- Consumes: registry + process + up/down helpers.
- Produces:
  - `fs_dash_render <selected-index>` → echoes the full frame text (header + one row per site, selected row marked with `>`). Pure/testable — no screen control.
  - `fs_dash_action <key> <domain>` → performs the action for a key on a domain: `s`→toggle up/down, `r`→restart, `o`→open, `l`→logs (returns the action name it took; `q`/unknown → echoes `quit`/`none`).
  - `fs_cmd_dash` → the interactive loop (alt-screen, hide cursor, `read -rsn1 -t 2`, `trap` restore). Not unit-tested (interactive); covered by the two pure functions plus manual smoke test.

- [ ] **Step 1: Write the failing test**

`test/dashboard.bats`:
```bash
load test_helper
setup() {
  setup_common
  for l in helpers caddy process commands dashboard; do . "$REPO_ROOT/lib/$l.sh"; done
  fs_ensure_home
}

@test "render marks the selected row and lists sites" {
  fs_registry_set a.test /p/a 8000 8.4
  fs_registry_set b.test /p/b 8001 8.5
  run fs_dash_render 1
  [[ "$output" == *"a.test"* ]]
  [[ "$output" == *"b.test"* ]]
  # second row (index 1) is selected
  [[ "$output" == *"> b.test"* ]]
}

@test "dash_action open triggers the opener" {
  fs_registry_set a.test /p/a 8000 8.4
  make_stub open "$BATS_TEST_TMPDIR/open.log"; export FS_OPEN_BIN=open
  run fs_dash_action o a.test
  [ "$output" = "open" ]
  grep -q "https://a.test" "$BATS_TEST_TMPDIR/open.log"
}

@test "dash_action q returns quit" {
  run fs_dash_action q a.test
  [ "$output" = "quit" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/dashboard.bats`
Expected: FAIL (`lib/dashboard.sh` missing).

- [ ] **Step 3: Write minimal implementation**

`lib/dashboard.sh`:
```bash
fs_dash_render() {
  local sel="${1:-0}" i=0 d dir port php status marker
  printf '  folder-server — [s]tart/stop [r]estart [o]pen [l]ogs [j/k] move [q]uit\n\n'
  printf '    %-22s %-8s %-6s %-4s\n' DOMAIN STATUS PORT PHP
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    port="$(fs_registry_field "$d" 3)"; php="$(fs_registry_field "$d" 4)"
    if fs_is_running "$d"; then status="running"; else status="stopped"; fi
    if [ "$i" -eq "$sel" ]; then marker=">"; else marker=" "; fi
    printf '  %s %-22s %-8s %-6s %-4s\n' "$marker" "$d" "$status" "$port" "$php"
    i=$((i+1))
  done < <(fs_registry_domains)
}

fs_dash_action() {
  local key="$1" domain="$2" dir
  dir="$(fs_registry_field "$domain" 2 2>/dev/null || true)"
  case "$key" in
    s) if fs_is_running "$domain"; then fs_cmd_down "$dir" >/dev/null 2>&1; else fs_cmd_up "$dir" >/dev/null 2>&1; fi; echo "toggle" ;;
    r) fs_cmd_restart "$dir" >/dev/null 2>&1; echo "restart" ;;
    o) "$FS_OPEN_BIN" "https://$domain" >/dev/null 2>&1; echo "open" ;;
    l) echo "logs" ;;
    q) echo "quit" ;;
    *) echo "none" ;;
  esac
}

fs_cmd_dash() {
  local sel=0 key domains n domain
  trap 'printf "\033[?25h\033[?1049l"' EXIT INT TERM
  printf '\033[?1049h\033[?25l'  # alt screen + hide cursor
  while true; do
    domains="$(fs_registry_domains)"
    n="$(printf '%s\n' "$domains" | grep -c .)"
    printf '\033[H\033[2J'       # home + clear
    fs_dash_render "$sel"
    IFS= read -rsn1 -t 2 key || key=""
    case "$key" in
      j) [ "$sel" -lt $((n-1)) ] && sel=$((sel+1)) ;;
      k) [ "$sel" -gt 0 ] && sel=$((sel-1)) ;;
      '') : ;; # timeout → just refresh
      *)
        domain="$(printf '%s\n' "$domains" | sed -n "$((sel+1))p")"
        [ -n "$domain" ] || continue
        if [ "$(fs_dash_action "$key" "$domain")" = "quit" ]; then break; fi
        ;;
    esac
  done
  printf '\033[?25h\033[?1049l'
  trap - EXIT INT TERM
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/dashboard.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/dashboard.sh test/dashboard.bats
git commit -m "feat: live TUI dashboard (render + action + loop)"
```

---

## Task 13: Install script, README, and full test run

**Files:**
- Create: `install.sh`
- Create: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `install.sh` symlinks `bin/folder-server` into a bin dir and prints the `alias fs=folder-server` hint; README documents install + usage.

- [ ] **Step 1: Write install.sh**

`install.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
PREFIX="${PREFIX:-/opt/homebrew/bin}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/folder-server"
ln -sf "$SRC" "$PREFIX/folder-server"
ln -sf "$SRC" "$PREFIX/fs"
echo "Linked folder-server and fs into $PREFIX"
echo "Run 'fs setup' to finish machine setup."
```

- [ ] **Step 2: Write README.md**

`README.md`:
```markdown
# folder-server

A tiny, brew-based replacement for MAMP Pro on Apple Silicon macOS. Serve any
folder at `https://<name>.test` with a chosen PHP version, MySQL on demand,
and a live terminal dashboard.

## Install

    ./install.sh          # symlinks `folder-server` and `fs` into /opt/homebrew/bin
    fs setup              # installs deps, configures dnsmasq/caddy/cert
    # then run the printed sudo lines once

## Usage

    cd ~/Sites/my-project
    fs init               # writes .folderserver
    fs up                 # serves https://my-project.test
    fs list               # see all sites
    fs dash               # live dashboard
    fs down               # stop
    fs db start           # MySQL when you need it

## Config: `.folderserver`

    domain=my-project.test
    php=8.4
    docroot=public

See `docs/superpowers/specs/2026-07-04-folder-server-design.md` for the design.
```

- [ ] **Step 3: Run the whole test suite**

Run: `bats test/`
Expected: PASS (all tests across all files).

- [ ] **Step 4: Run shellcheck**

Run: `shellcheck -x bin/folder-server lib/*.sh install.sh`
Expected: no errors (fix any warnings before committing).

- [ ] **Step 5: Commit**

```bash
chmod +x install.sh
git add install.sh README.md
git commit -m "docs: install script and README; green test suite"
```

---

## Self-Review Notes

- **Spec coverage:** dnsmasq/Caddy/mkcert wildcard (Tasks 5, 11) · `php -S` per project (6) · per-folder PHP version (2, 4, 7) · `.folderserver` (2, 9) · registry/state in `~/.folder-server` (1, 3) · CLI setup/init/up/down/restart/list/open/logs/db/dash (1, 7–12) · MySQL on demand (10) · live TUI (12) · testing via bats (all). All spec sections map to a task.
- **Placeholders:** none — every code step contains complete code.
- **Type consistency:** helper names (`fs_registry_field`, `fs_cmd_up`, `fs_cmd_down`, `fs_is_running`, `fs_cert_paths`, `_fs_load_config`, `FS_DOMAIN/FS_PHP/FS_DOCROOT`) are used identically across tasks.
