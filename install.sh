#!/usr/bin/env bash
set -euo pipefail
PREFIX="${PREFIX:-/opt/homebrew/bin}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/folder-server"
ln -sf "$SRC" "$PREFIX/folder-server"
ln -sf "$SRC" "$PREFIX/fs"
echo "Linked folder-server and fs into $PREFIX"
echo "Run 'fs setup' to finish machine setup."
