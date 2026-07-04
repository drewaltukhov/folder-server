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
