#!/bin/sh
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Run this command on macOS." >&2
  exit 1
fi

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALL_DIR="$HOME/.local/share/opencode/mac-screen-mcp"
mkdir -p "$INSTALL_DIR"
cp "$SOURCE_DIR/server.py" "$INSTALL_DIR/server.py"
chmod 700 "$INSTALL_DIR/server.py"

opencode mcp add mac-screen --global -- python3 "$INSTALL_DIR/server.py"
opencode mcp list
