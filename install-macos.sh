#!/bin/sh
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Run this command on macOS." >&2
  exit 1
fi

INSTALL_DIR="$HOME/.local/share/opencode/mac-screen-mcp"
mkdir -p "$INSTALL_DIR"
curl -fsSL "https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main/server.py" -o "$INSTALL_DIR/server.py"
chmod 700 "$INSTALL_DIR/server.py"

opencode mcp add mac-screen --global -- python3 "$INSTALL_DIR/server.py"
opencode mcp list
