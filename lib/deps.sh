# shellcheck shell=bash
# lib/deps.sh — the single source of truth for the Homebrew packages
# folder-server installs and manages. Sourced by commands.sh (fs_setup_deps),
# fix.sh, and uninstall.sh so the list can never drift between them.
#
# PHP and MySQL are intentionally NOT here: they are user-managed (installed and
# removed on the user's terms), so folder-server never auto-installs or removes
# them. This is only the always-safe support tooling.
: "${FS_BREW_DEPS:=dnsmasq caddy gum fzf mkcert}"
