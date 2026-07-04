#!/usr/bin/env bash
set -euo pipefail
PREFIX="${PREFIX:-/opt/homebrew/bin}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/folder-server"
ln -sf "$SRC" "$PREFIX/folder-server"
ln -sf "$SRC" "$PREFIX/fs"
echo "Linked folder-server and fs into $PREFIX"

# Trust the mkcert local CA now so *.test HTTPS is valid in browsers (no SSL
# warnings). Safe to run repeatedly; 'fs setup' generates the certificate.
if command -v mkcert >/dev/null 2>&1; then
  echo "Installing the mkcert local CA into your trust store..."
  mkcert -install || true
fi

echo "Run 'fs setup' to finish machine setup."
