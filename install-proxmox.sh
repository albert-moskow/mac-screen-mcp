#!/bin/sh
set -eu

BASE="https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main"
STATE_DIR="$HOME/.local/share/opencode/mac-screen-mcp"
mkdir -p "$STATE_DIR"

if ! command -v zerotier-cli >/dev/null 2>&1; then
  echo "Installing ZeroTier on Linux..."
  curl -fsSL https://install.zerotier.com | sudo bash
fi
sudo systemctl enable --now zerotier-one >/dev/null 2>&1 || true

if [ "${1:-}" = "pair" ]; then
  MAC_NODE=${2:?Missing Mac ZeroTier NodeID}
  TOKEN=${3:?Missing Mac token}
  NWID=$(cat "$STATE_DIR/nwid")
  AUTH=$(sudo cat /var/lib/zerotier-one/authtoken.secret)
  MAC_IP="10.147.20.2"
  TOKEN_FILE="$STATE_DIR/token"
  umask 077
  printf '%s' "$TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  curl -fsSL -X POST "http://127.0.0.1:9993/controller/network/$NWID/member/$MAC_NODE" \
    -H "X-ZT1-Auth: $AUTH" \
    -d "{\"authorized\":true,\"ipAssignments\":[\"$MAC_IP\"]}" >/dev/null

  echo "Waiting for Mac ($MAC_IP:18766) over ZeroTier..."
  python3 - "$MAC_IP" <<'PY'
import socket, sys, time
host = sys.argv[1]
for _ in range(15):
    s = socket.socket()
    s.settimeout(1.5)
    try:
        s.connect((host, 18766))
        s.close()
        break
    except OSError:
        s.close()
        time.sleep(1)
PY

  python3 - "http://$MAC_IP:18766" <<'PY'
import json, os, sys, tempfile
url = sys.argv[1]
path = os.path.expanduser("~/.config/opencode/opencode.json")
if not os.path.exists(path):
    path += "c"
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path, encoding="utf-8") as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
servers = config.setdefault("mcp", {}).setdefault("servers", {})
servers["mac-screen"] = {
    "type": "remote",
    "url": url.rstrip("/") + "/mcp",
    "oauth": False,
    "headers": {"Authorization": "Bearer {file:~/.local/share/opencode/mac-screen-mcp/token}"},
    "codemode": False,
}
fd, temp = tempfile.mkstemp(dir=os.path.dirname(path), prefix="opencode-")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
os.chmod(temp, 0o600)
os.replace(temp, path)
print("Configured mac-screen in " + path)
PY
  echo "Mac paired ($MAC_IP). Check /mcps in OpenCode."
  exit 0
fi

AUTH=$(sudo cat /var/lib/zerotier-one/authtoken.secret)
NODE=$(sudo zerotier-cli info | awk '{print $3}')
if [ -s "$STATE_DIR/nwid" ]; then
  NWID=$(cat "$STATE_DIR/nwid")
else
  NWID="${NODE}000001"
  printf '%s\n' "$NWID" > "$STATE_DIR/nwid"
fi

curl -fsSL -X POST "http://127.0.0.1:9993/controller/network/$NWID" \
  -H "X-ZT1-Auth: $AUTH" \
  -d '{"name":"opencode-mac-screen","private":true,"v4AssignMode":{"zt":true},"routes":[{"target":"10.147.20.0/24","via":null}],"ipAssignmentPools":[{"ipRangeStart":"10.147.20.10","ipRangeEnd":"10.147.20.250"}],"rules":[{"type":"ACTION_ACCEPT"}]}' >/dev/null

sudo zerotier-cli join "$NWID" >/dev/null
curl -fsSL -X POST "http://127.0.0.1:9993/controller/network/$NWID/member/$NODE" \
  -H "X-ZT1-Auth: $AUTH" \
  -d '{"authorized":true,"ipAssignments":["10.147.20.1"]}' >/dev/null

printf '\nStep 1 ready on Proxmox (Network ID: %s).\nNow run this command on your Mac:\n\n' "$NWID"
printf 'curl -fsSL %s/install-macos.sh | sh -s -- %s\n\n' "$BASE" "$NWID"
