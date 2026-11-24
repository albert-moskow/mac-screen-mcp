#!/bin/sh
set -eu

BASE="https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main"
DIR="$HOME/.local/share/opencode/mac-screen-mcp"
NWID=${1:?Usage: install-macos.sh ZEROTIER_NETWORK_ID}

[ "$(uname -s)" = Darwin ] || { echo "Run on macOS." >&2; exit 1; }
for bin in curl python3; do command -v "$bin" >/dev/null || { echo "Missing $bin." >&2; exit 1; }; done

if command -v zerotier-cli >/dev/null 2>&1; then
  ZT=zerotier-cli
elif [ -x /usr/local/bin/zerotier-cli ]; then
  ZT=/usr/local/bin/zerotier-cli
elif command -v brew >/dev/null 2>&1; then
  echo "Installing ZeroTier via Homebrew..."
  brew install --cask zerotier-one
  ZT=/usr/local/bin/zerotier-cli
else
  echo "Install ZeroTier first (brew install --cask zerotier-one or https://www.zerotier.com/download/)." >&2
  exit 1
fi

sudo "$ZT" join "$NWID" >/dev/null
MAC_NODE=$(sudo "$ZT" info | awk '{print $3}')

mkdir -p "$DIR" "$HOME/Library/LaunchAgents"
curl -fsSL "$BASE/server.py" -o "$DIR/server.py"
TOKEN_FILE="$DIR/token"
if [ ! -s "$TOKEN_FILE" ]; then umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$TOKEN_FILE"; fi
chmod 600 "$TOKEN_FILE"
TOKEN=$(cat "$TOKEN_FILE")

cat > "$DIR/server.sh" <<EOF
#!/bin/sh
export MAC_SCREEN_TOKEN='$TOKEN'
exec /usr/bin/python3 '$DIR/server.py' --http 0.0.0.0 8766
EOF
chmod 700 "$DIR/server.sh"

LABEL=ai.opencode.mac-screen
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$DIR/server.sh</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$DIR/server.log</string>
<key>StandardErrorPath</key><string>$DIR/server.log</string></dict></plist>
EOF
launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

printf '\nStep 2 ready on Mac (Node ID: %s).\nRun this final pairing command on Proxmox (keep token private):\n\n' "$MAC_NODE"
printf 'curl -fsSL %s/install-proxmox.sh | sh -s -- pair %s %s\n\n' "$BASE" "$MAC_NODE" "$TOKEN"
