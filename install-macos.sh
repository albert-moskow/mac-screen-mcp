#!/bin/sh
set -eu

BASE="https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main"
DIR="$HOME/.local/share/opencode/mac-screen-mcp"
[ "$(uname -s)" = Darwin ] || { echo "Run on macOS." >&2; exit 1; }
for bin in curl python3; do command -v "$bin" >/dev/null || { echo "Missing $bin." >&2; exit 1; }; done
if command -v tailscale >/dev/null 2>&1; then
  TS=tailscale
elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
else
  echo "Tailscale is not installed. Install Tailscale on Mac (https://tailscale.com/download/mac or brew install --cask tailscale), sign in, and rerun." >&2
  exit 1
fi
"$TS" status >/dev/null 2>&1 || { echo "Open Tailscale on this Mac and sign in first." >&2; exit 1; }

mkdir -p "$DIR" "$HOME/Library/LaunchAgents"
curl -fsSL "$BASE/server.py" -o "$DIR/server.py"
TOKEN_FILE="$DIR/token"
if [ ! -s "$TOKEN_FILE" ]; then umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$TOKEN_FILE"; fi
chmod 600 "$TOKEN_FILE"
TOKEN=$(cat "$TOKEN_FILE")
cat > "$DIR/server.sh" <<EOF
#!/bin/sh
export MAC_SCREEN_TOKEN='$TOKEN'
exec /usr/bin/python3 '$DIR/server.py' --http
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
"$TS" serve --bg 8766

HOST=$("$TS" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"].get("DNSName", "").rstrip("."))')
[ -n "$HOST" ] || { echo "Could not read Tailscale DNS name." >&2; exit 1; }
printf '\nMac server ready. Pair it on Proxmox using this command (keep token private):\n\n'
printf 'curl -fsSL https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main/install-proxmox.sh | sh -s -- %s %s\n\n' "https://$HOST" "$TOKEN"
