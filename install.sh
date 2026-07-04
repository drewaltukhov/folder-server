#!/usr/bin/env bash
set -euo pipefail
PREFIX="${PREFIX:-/opt/homebrew/bin}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO/bin/folder-server"
ln -sf "$SRC" "$PREFIX/folder-server"
ln -sf "$SRC" "$PREFIX/fs"
echo "Linked folder-server and fs into $PREFIX"

# Shell completion (zsh + bash), into Homebrew's standard completion dirs.
# uninstall.sh removes these. Harmless if the target dirs don't exist yet.
HB="${PREFIX%/bin}"
ZSH_COMP="$HB/share/zsh/site-functions/_fs"
BASH_COMP="$HB/etc/bash_completion.d/fs"
mkdir -p "$(dirname "$ZSH_COMP")" "$(dirname "$BASH_COMP")" 2>/dev/null || true
ln -sf "$REPO/completions/fs.zsh" "$ZSH_COMP" 2>/dev/null && echo "Installed zsh completion → $ZSH_COMP" || true
ln -sf "$REPO/completions/fs.bash" "$BASH_COMP" 2>/dev/null && echo "Installed bash completion → $BASH_COMP" || true

# Trust the mkcert local CA now so *.test HTTPS is valid in browsers (no SSL
# warnings). Safe to run repeatedly; 'fs setup' generates the certificate.
if command -v mkcert >/dev/null 2>&1; then
  echo "Installing the mkcert local CA into your trust store..."
  mkcert -install || true
fi

echo "Run 'fs setup' to finish machine setup."
