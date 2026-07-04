<p align="center">
  <img src="docs/logo.svg" alt="folder-server" width="140">
</p>

<h1 align="center">Folder Server v1.0</h1>

<p align="center">
  <em>Serve any folder at <code>https://&lt;name&gt;.test</code> — a tiny, brew-based MAMP&nbsp;Pro replacement for Apple&nbsp;Silicon macOS.</em>
</p>

A tiny, brew-based replacement for MAMP Pro on Apple Silicon macOS. Serve any
folder at `https://<name>.test` with a chosen PHP version, MySQL on demand,
and a live terminal dashboard.

<p align="center">
  <img src="docs/dash.png" alt="fs dash — the live terminal dashboard" width="760">
</p>

## Install

    ./install.sh          # symlinks `folder-server` and `fs` into /opt/homebrew/bin
    fs setup              # installs deps, configures dnsmasq/caddy/cert
    # then run the printed sudo lines once

## Usage

    cd ~/Sites/my-project
    fs init               # interactive setup → writes .folderserver
    fs up                 # serves https://my-project.test
    fs list               # see all sites
    fs dash               # live dashboard (per-site [e]dit, [u]nbind, …)
    fs edit               # change php / routing / MySQL for this folder
    fs down               # stop
    fs db start           # MySQL when you need it

`fs init` (and the dashboard's `[e]dit`) walk you through the PHP version,
optional front-controller routing, and optional MySQL (with a login/password).

## Config: `.folderserver`

    domain=my-project.test
    php=8.4
    docroot=public
    rewrite=index.php     # optional — front-controller routing (see below)
    db=on                 # optional — provision MySQL on `fs up` (see below)
    db_name=my_project
    db_user=app
    db_pass=secret

### Front-controller routing (`rewrite`)

There's no `.htaccess` support (that's Apache-only; this serves via `php -S`).
For apps that need the classic "send unknown URLs to `index.php`" rewrite
(WordPress, Laravel, Symfony, …), set `rewrite` to your front-controller file:

    rewrite=index.php

`fs up` then serves existing files (static assets and real `.php`) directly and
routes every other request to that file — the same behaviour `.htaccess`
`RewriteRule` gives you. Omit `rewrite` for plain static + direct `.php` access.

### MySQL (`db`)

Set `db=on` with a `db_user`/`db_pass` (and optional `db_name`, defaulting to the
folder name) and `fs up` will start MySQL, create the database, and create the
user with full grants on it — so this just works:

```php
$mysqli = mysqli_connect('127.0.0.1', 'app', 'secret', 'my_project');
```

After provisioning, `fs up` prints the exact connection details:

```
  MySQL ready — connect with:
    host      127.0.0.1   (use this, not "localhost")
    port      3306
    database  my_project
    user      app
    password  secret
```

Notes:
- **Use a dedicated `db_user`, not `root`.** `root` is the admin account
  folder-server connects as to provision, so it can't also be your app user.
- **Connect on `127.0.0.1`, not `localhost`** — `localhost` uses the socket and
  matches MySQL's passwordless `root@localhost`; `127.0.0.1` uses TCP.
- Provisioning connects as `root` with no password (the Homebrew default).
- Credentials are stored in plaintext in `.folderserver` — don't commit it if the
  password matters.

See `docs/superpowers/specs/2026-07-04-folder-server-design.md` for the design.
