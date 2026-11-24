#!/bin/sh
set -eu

BASE="https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main"
URL=${1:?Usage: install-proxmox.sh https://mac-name.tailnet.ts.net TOKEN}
TOKEN=${2:?Usage: install-proxmox.sh https://mac-name.tailnet.ts.net TOKEN}
command -v opencode >/dev/null 2>&1 || { echo "Run inside the Proxmox OpenCode environment; opencode command missing." >&2; exit 1; }
python3 - "$URL" "$TOKEN" <<'PY'
import json, os, sys, tempfile
url, token = sys.argv[1:]
if not url.startswith("https://") or "." not in url.split("/")[2]:
    raise SystemExit("Use Mac's HTTPS Tailscale DNS name.")
path = os.path.expanduser("~/.config/opencode/opencode.json")
if not os.path.exists(path): path += "c"
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path, encoding="utf-8") as f: config = json.load(f)
except FileNotFoundError: config = {}
servers = config.setdefault("mcp", {}).setdefault("servers", {})
servers["mac-screen"] = {"type":"remote", "url":url.rstrip("/")+"/mcp", "oauth":False,
                          "headers":{"Authorization":"Bearer "+token}, "codemode":False}
fd, temp = tempfile.mkstemp(dir=os.path.dirname(path), prefix="opencode-")
with os.fdopen(fd,"w",encoding="utf-8") as f:
    json.dump(config,f,indent=2); f.write("\n")
os.chmod(temp,0o600); os.replace(temp,path)
print("Configured mac-screen in " + path)
PY
echo "OpenCode reloads config automatically. Check /mcps."
