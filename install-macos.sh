#!/bin/sh
set -eu

BASE="https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main"
DIR="$HOME/.local/share/opencode/mac-screen-mcp"
[ "$(uname -s)" = Darwin ] || { echo "Run on macOS." >&2; exit 1; }
for bin in curl python3 tailscale; do command -v "$bin" >/dev/null || { echo "Missing $bin." >&2; exit 1; }; done
tailscale status >/dev/null 2>&1 || { echo "Sign in to Tailscale on this Mac first." >&2; exit 1; }

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
tailscale serve --bg 8766

HOST=$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"].get("DNSName", "").rstrip("."))')
[ -n "$HOST" ] || { echo "Could not read Tailscale DNS name." >&2; exit 1; }
printf '\nMac server ready. Pair it on Proxmox using this command (keep token private):\n\n'
printf 'curl -fsSL https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main/install-proxmox.sh | sh -s -- %s %s\n\n' "https://$HOST" "$TOKEN"
