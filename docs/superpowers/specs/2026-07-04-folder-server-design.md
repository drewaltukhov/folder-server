# folder-server — design

**Date:** 2026-07-04
**Status:** Approved design, pending implementation plan

## Purpose

Replace MAMP Pro on macOS with a small, brew-based, per-folder local dev
environment for **simple PHP scripts**. MAMP Pro ships as an Intel app and
macOS is dropping Intel support, so we want a lightweight native replacement
built entirely on Homebrew packages plus a handful of shell scripts.

Each project folder can be served at its own HTTPS `*.test` domain with a
chosen PHP version. MySQL is available on demand. A live terminal dashboard
manages the running servers.

## Goals

- Serve any folder at `https://<name>.test` with a trusted local certificate.
- Per-folder PHP version selection (`php@8.3` / `php@8.4` / `php@8.5`).
- "Mostly one project, occasionally two" running at once — no port juggling.
- MySQL started only when a project needs it (not always-on).
- Brew packages + shell scripts only. No Intel binaries, no heavy framework.
- A simple live TUI dashboard to see and control running servers.

## Non-goals

- Production-grade concurrency or performance (`php -S` is single-request).
- Per-project isolated MySQL instances (shared server, per-project DBs instead).
- Full Laravel Valet / Herd feature set (drivers, park/link, frameworks).
- Automatic PHP-FPM pools (can be added per-project later if ever needed).

## Key design decision: `php -S` instead of PHP-FPM

For simple scripts we use **PHP's built-in web server** (`php -S`), one process
per running project, launched with the project's chosen PHP binary
(e.g. `/opt/homebrew/opt/php@8.4/bin/php`). This makes per-folder PHP versions
trivial — no FPM pools, no socket collisions, no version daemons to juggle.
The tradeoff is that `php -S` serves one request at a time; acceptable for
local development of simple scripts. A single project can be migrated to
PHP-FPM later without changing the rest of the system.

## Architecture

Three always-considered layers plus per-project processes:

1. **dnsmasq** (always-on brew service)
   - Config: `address=/.test/127.0.0.1`
   - macOS resolver: `/etc/resolver/test` pointing at `127.0.0.1#53`
   - Result: every `*.test` hostname resolves to localhost, no `/etc/hosts` edits.
   - Set up once by `fs setup`; never touched again.

2. **Caddy** (always-on brew service, binds `:80` and `:443`)
   - Root config imports per-site snippets: `import <caddy_dir>/sites/*.caddy`
   - Each site snippet: `reverse_proxy 127.0.0.1:<port>` + `tls <cert> <key>`
   - HTTPS uses a single wildcard cert from `mkcert "*.test"` (mkcert CA is
     already installed and trusted → no browser warnings, no second CA).
   - Hot-reloaded with `caddy reload` when snippets change.
   - Runs as root service so it can bind ports 80/443 (one-time
     `sudo brew services start caddy`).

3. **PHP built-in server** — one per running project, on demand
   - `nohup <php-binary> -S 127.0.0.1:<port> -t <docroot>` with output to a log.
   - PID tracked in a pidfile; port assigned from a free-port scan and
     remembered in the registry so it stays stable across restarts.

4. **MySQL** — on demand only
   - `fs db start|stop` toggles a shared brew MySQL service.
   - Projects use their own database name within that shared server.

## Per-folder config: `.folderserver`

Plain `key=value` INI-ish file in the project root:

```ini
domain=my-project.test   # defaults to <folder-name>.test
php=8.4                   # 8.3 | 8.4 | 8.5; defaults to a global default
docroot=public           # optional; defaults to the project folder itself
# port is auto-assigned on first `up` and stored in the registry (not here)
```

Parsing: simple `while IFS='=' read` loop; ignore blank lines and `#` comments.
Unknown keys are ignored. Missing keys fall back to defaults.

## Home directory & state: `~/.folder-server/`

```
~/.folder-server/
  config              # global defaults (default_php, caddy_dir, tld, etc.)
  registry            # one line per known site: domain|dir|port|php
  run/<domain>.pid    # pidfile for the running php -S process
  logs/<domain>.log   # php -S stdout/stderr
```

The registry is the single source of truth for "what sites exist and their
ports." Live running state is derived by checking pidfiles (`kill -0`) and the
port.

## CLI: one script `folder-server`, aliased `fs`

Subcommand dispatch (`case "$1"`), each subcommand a shell function:

- `fs setup` — one-time machine setup (idempotent):
  install `dnsmasq caddy gum fzf` via brew if missing; write dnsmasq `*.test`
  config and start the service; create `/etc/resolver/test`; generate the
  `mkcert "*.test"` wildcard cert; write Caddy root config with the `import`
  line; start Caddy as a root service. Prints what it changed.
- `fs init` — scaffold a `.folderserver` in the current folder. Uses `gum`
  to prompt (domain defaulting to folder name, PHP version chooser, optional
  docroot). Non-interactive fallback writes sensible defaults.
- `fs up` — read `.folderserver` → allocate/reuse port from registry →
  start `php -S` (pidfile) → write `sites/<domain>.caddy` → `caddy reload`.
  Prints `https://<domain>`.
- `fs down` — stop the php process (pidfile), remove the Caddy snippet,
  `caddy reload`.
- `fs restart` — `down` then `up`.
- `fs list` — table of known sites: domain, status, port, PHP version.
- `fs open` — open the current project's URL in the default browser.
- `fs logs` — tail the current project's php log.
- `fs db start|stop|status` — toggle the shared MySQL brew service.
- `fs dash` — launch the live TUI dashboard (below).

Design for isolation: each subcommand is a function with a single job; shared
helpers (`_read_config`, `_registry_get/set`, `_free_port`, `_caddy_reload`,
`_php_binary <ver>`, `_is_running <domain>`) live in one sourced library so
both the CLI and the dashboard reuse them.

## TUI: `fs dash` — live dashboard (pure shell)

A raw-ANSI redraw loop in bash (gum/fzf are used for one-shot prompts
elsewhere, but the live cursor needs direct control):

- On start: hide cursor, switch to alternate screen buffer.
- Loop:
  1. Clear screen; render header + a table of all registry sites with live
     status (running/stopped via pidfile, port, PHP version, URL). Highlight
     the selected row.
  2. `read -rsn1 -t 2 key` — returns on keypress **or** after 2s timeout, so
     the view refreshes live and stays responsive in one loop.
  3. Dispatch keys:
     - `j`/`k` or arrow keys — move selection
     - `s`/`Enter` — toggle selected site up/down
     - `r` — restart selected
     - `l` — view logs (pager) for selected
     - `o` — open selected URL in browser
     - `q` — quit
- On exit (and via `trap`): restore cursor, leave alternate screen.

The dashboard calls the same shared helpers as the CLI, so behavior is
identical whether driven by keypress or subcommand.

Scope note: this is a redraw-on-interval dashboard, not a fully reactive TUI.
It is smooth for the expected handful of sites; a Go/Textual rewrite is the
upgrade path if it ever needs to scale or feel richer.

## Data flow: `fs up`

```
read .folderserver ──▶ resolve php version ──▶ registry lookup/allocate port
        │                                              │
        ▼                                              ▼
  start php -S 127.0.0.1:PORT -t docroot        write sites/<domain>.caddy
  (nohup, save PID, log to logs/<domain>.log)   (reverse_proxy + tls wildcard)
        │                                              │
        └───────────────────┬──────────────────────────┘
                            ▼
                      caddy reload  ──▶  https://<domain> live
```

`fs down` reverses: kill PID, remove snippet, reload.

## Error handling

- `fs up` with no `.folderserver` → hint to run `fs init`.
- Requested PHP version not installed → clear message with the `brew install
  php@X.Y` command.
- Port in registry already in use by something else → pick a new free port,
  update registry.
- `caddy reload` failure → surface Caddy's error, leave php process as-is.
- `setup` steps are idempotent and check-before-write so re-running is safe.
- Dashboard `trap`s `EXIT`/`INT` to always restore the terminal.

## Dependencies (all Homebrew)

Already present: `php@8.3` `php@8.4` `php@8.5`, `mysql*`, `mkcert`,
`brew-php-switcher`.
To install via `fs setup`: `dnsmasq`, `caddy`, `gum`, `fzf`.

## Testing strategy

- Unit-ish: test pure helper functions (`_free_port`, config parsing,
  registry get/set) with `bats` (bash test framework) against temp dirs.
- Integration (manual/scripted): `fs setup` on a clean-ish machine, then
  `fs init` + `fs up` in a throwaway folder with a `index.php` echoing
  `phpversion()`, assert `curl https://test-proj.test` returns it over a
  trusted cert, assert switching `php=8.5` changes the reported version.
- Dashboard: manual smoke test of key actions.

## Open questions / future

- Optional `fs park` to auto-serve every subfolder of a directory (Valet-style)
  — deferred; explicit `init` per project is fine for now.
- Per-project `.env` / MySQL DB auto-creation — deferred until first needed.
