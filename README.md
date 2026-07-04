<p align="center">
  <img src="docs/logo.svg" alt="folder-server" width="500">
</p>

<h1 align="center">Folder Server v1.0</h1>

<p align="center">
  <em>Serve any folder at <code>https://&lt;name&gt;.test</code> — a tiny, brew-based MAMP&nbsp;Pro replacement for Apple&nbsp;Silicon macOS.</em>
</p>

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
