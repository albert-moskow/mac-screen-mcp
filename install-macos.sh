#!/bin/sh
set -eu

BASE="https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main"
DIR="$HOME/.local/share/opencode/mac-screen-mcp"
NWID=${1:?Usage: install-macos.sh ZEROTIER_NETWORK_ID}

[ "$(uname -s)" = Darwin ] || { echo "Run on macOS." >&2; exit 1; }
for bin in curl python3; do command -v "$bin" >/dev/null || { echo "Missing $bin." >&2; exit 1; }; done
PY_BIN=$(command -v python3)

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
cat > "$DIR/server.py" <<'SERVER_EOF'
#!/usr/bin/env python3
from __future__ import annotations
import base64
import json
import os
import platform
import secrets
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "mac-screen"
SERVER_VERSION = "0.2.0"

FALLBACK_PNG_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
)

SESSION_STATE: dict[str, Any] = {
    "approved": False,
    "expires_at": 0.0,
    "reason": "",
}
HTTP_OUTPUTS = None


def is_macos() -> bool:
    return platform.system() == "Darwin"


def has_active_consent() -> bool:
    if not SESSION_STATE["approved"]:
        return False
    if time.time() >= SESSION_STATE["expires_at"]:
        SESSION_STATE["approved"] = False
        SESSION_STATE["expires_at"] = 0.0
        SESSION_STATE["reason"] = ""
        return False
    return True


def prompt_macos_consent(reason: str, duration_seconds: int) -> bool:
    safe_reason = reason.replace("\\", "\\\\").replace('"', '\\"')
    script = (
        f'display dialog "OpenCode запрашивает доступ к снимку экрана.\\n\\n'
        f'Причина: {safe_reason}\\n'
        f'Длительность: {duration_seconds} сек." '
        f'with title "OpenCode Screen Access" '
        f'buttons {{"Отклонить", "Разрешить"}} default button "Разрешить" cancel button "Отклонить"'
    )
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    return result.returncode == 0


def request_access(reason: str, duration_seconds: int = 120) -> dict[str, Any]:
    duration_seconds = max(15, min(int(duration_seconds), 600))
    if is_macos():
        approved = prompt_macos_consent(reason, duration_seconds)
    else:
        approved = os.environ.get("MAC_SCREEN_DEV_AUTO_APPROVE") == "1"

    if not approved:
        SESSION_STATE["approved"] = False
        SESSION_STATE["expires_at"] = 0.0
        SESSION_STATE["reason"] = ""
        return {
            "approved": False,
            "platform": platform.system(),
            "message": (
                "Доступ не подтверждён. На macOS нажмите «Разрешить» в системном окне; "
                "в тестовой Linux-среде установите MAC_SCREEN_DEV_AUTO_APPROVE=1."
            ),
        }

    SESSION_STATE["approved"] = True
    SESSION_STATE["expires_at"] = time.time() + duration_seconds
    SESSION_STATE["reason"] = reason
    return {
        "approved": True,
        "platform": platform.system(),
        "version": SERVER_VERSION,
        "expires_in_seconds": duration_seconds,
        "reason": reason,
    }


def revoke_access() -> dict[str, Any]:
    SESSION_STATE["approved"] = False
    SESSION_STATE["expires_at"] = 0.0
    SESSION_STATE["reason"] = ""
    return {"approved": False, "message": "Доступ к экрану отключён."}


def capture_screen() -> dict[str, Any]:
    if not has_active_consent():
        raise PermissionError(
            "Нет активного разрешения на снимок экрана. Сначала вызовите request_screen_access."
        )

    if is_macos():
        with tempfile.NamedTemporaryFile(prefix="opencode_screen_", suffix=".png", delete=False) as tmp:
            tmp_path = tmp.name
        try:
            proc = subprocess.run(
                ["screencapture", "-x", tmp_path],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
            if proc.returncode != 0 or not os.path.exists(tmp_path):
                osa = (
                    f'tell application "Terminal" to do script '
                    f'"screencapture -x {tmp_path} && exit"'
                )
                subprocess.run(["osascript", "-e", osa], capture_output=True, text=True, timeout=10, check=False)
                for _ in range(30):
                    if os.path.exists(tmp_path) and os.path.getsize(tmp_path) > 0:
                        proc = subprocess.CompletedProcess(args=["screencapture"], returncode=0, stdout="", stderr="")
                        break
                    time.sleep(0.2)
            if proc.returncode != 0 or not os.path.exists(tmp_path):
                raise RuntimeError(
                    f"Не удалось сделать снимок через screencapture: {proc.stderr.strip() or 'код ' + str(proc.returncode)}"
                )
            subprocess.run(
                ["sips", "-Z", "1920", tmp_path],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            with open(tmp_path, "rb") as f:
                data_b64 = base64.b64encode(f.read()).decode("ascii")
            return {
                "mimeType": "image/png",
                "data": data_b64,
                "note": "Снимок экрана macOS получен.",
            }
        finally:
            if os.path.exists(tmp_path):
                try:
                    os.remove(tmp_path)
                except OSError:
                    pass

    return {
        "mimeType": "image/png",
        "data": FALLBACK_PNG_BASE64,
        "note": "Тестовый режим (не macOS): возвращена 1x1 PNG-заглушка.",
    }


TOOLS = [
    {
        "name": "request_screen_access",
        "description": "Запрашивает у пользователя временное разрешение на снимок экрана.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "reason": {
                    "type": "string",
                    "description": "Зачем нужен снимок экрана (показывается пользователю в окне запроса).",
                },
                "duration_seconds": {
                    "type": "integer",
                    "description": "На сколько секунд выдать доступ (от 15 до 600, по умолчанию 120).",
                    "default": 120,
                },
            },
            "required": ["reason"],
            "additionalProperties": False,
        },
    },
    {
        "name": "capture_screen",
        "description": "Делает снимок экрана, если пользователь уже подтвердил доступ.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
    {
        "name": "revoke_screen_access",
        "description": "Немедленно отключает активный доступ к экрану.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
]


def send_message(msg: dict[str, Any]) -> None:
    if HTTP_OUTPUTS is not None:
        HTTP_OUTPUTS.append(msg)
        return
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle_call_tool(req_id: Any, params: dict[str, Any]) -> None:
    name = params.get("name")
    arguments = params.get("arguments") or {}

    try:
        if name == "request_screen_access":
            reason = str(arguments.get("reason", "Помощь по текущему экрану"))
            duration = int(arguments.get("duration_seconds", 120))
            res = request_access(reason=reason, duration_seconds=duration)
            send_message(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False)}],
                        "isError": not res.get("approved", False),
                    },
                }
            )
            return

        if name == "capture_screen":
            shot = capture_screen()
            send_message(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [
                            {"type": "text", "text": shot["note"]},
                            {
                                "type": "image",
                                "data": shot["data"],
                                "mimeType": shot["mimeType"],
                            },
                        ],
                        "isError": False,
                    },
                }
            )
            return

        if name == "revoke_screen_access":
            res = revoke_access()
            send_message(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False)}],
                        "isError": False,
                    },
                }
            )
            return

        send_message(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Unknown tool: {name}"},
            }
        )
    except Exception as exc:
        send_message(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": f"Ошибка: {exc}"}],
                    "isError": True,
                },
            }
        )


def handle_request(msg: dict[str, Any]) -> None:
    method = msg.get("method")
    req_id = msg.get("id")
    params = msg.get("params") or {}

    if method == "initialize":
        send_message(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                    "instructions": (
                        "Используй request_screen_access перед capture_screen, "
                        "а после завершения помощи вызывай revoke_screen_access."
                    ),
                },
            }
        )
        return

    if method == "notifications/initialized":
        return

    if method == "ping":
        send_message({"jsonrpc": "2.0", "id": req_id, "result": {}})
        return

    if method == "tools/list":
        send_message({"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
        return

    if method == "tools/call":
        handle_call_tool(req_id, params)
        return

    if req_id is not None:
        send_message(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Method not found: {method}"},
            }
        )


class MCPHttpHandler(BaseHTTPRequestHandler):
    server_version = "MacScreenMCP/0.1"

    def do_GET(self) -> None:
        self.send_error(405, "Method Not Allowed")

    def do_POST(self) -> None:
        global HTTP_OUTPUTS
        client_ip = self.client_address[0]
        if client_ip != "127.0.0.1" and not client_ip.startswith("10.147.20."):
            self.send_error(403, "Forbidden")
            return
        token = os.environ.get("MAC_SCREEN_TOKEN", "")
        provided = self.headers.get("Authorization", "")
        expected = f"Bearer {token}"
        if not token or not secrets.compare_digest(provided, expected):
            self.send_error(401, "Unauthorized")
            return
        if self.path != "/mcp":
            self.send_error(404, "Not found")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 1 or length > 1_000_000:
                self.send_error(413, "Invalid request size")
                return
            request = json.loads(self.rfile.read(length))
            if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
                self.send_error(400, "Invalid JSON-RPC request")
                return
            HTTP_OUTPUTS = []
            handle_request(request)
            responses = HTTP_OUTPUTS
            HTTP_OUTPUTS = None
            if not responses:
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            payload = json.dumps(responses[-1], ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)
        except (ValueError, json.JSONDecodeError):
            HTTP_OUTPUTS = None
            self.send_error(400, "Invalid JSON")
        except Exception:
            HTTP_OUTPUTS = None
            self.send_error(500, "Internal server error")

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("mac-screen: " + fmt % args + "\n")


class ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--http":
        if not os.environ.get("MAC_SCREEN_TOKEN"):
            raise SystemExit("MAC_SCREEN_TOKEN is required")
        host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
        port = int(sys.argv[3]) if len(sys.argv) > 3 else 18766
        print(f"mac-screen MCP listening on {host}:{port}/mcp", file=sys.stderr)
        ReusableHTTPServer((host, port), MCPHttpHandler).serve_forever()
        return
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(msg, dict):
            handle_request(msg)


if __name__ == "__main__":
    main()
SERVER_EOF
chmod 700 "$DIR/server.py"

TOKEN_FILE="$DIR/token"
if [ ! -s "$TOKEN_FILE" ]; then umask 077; "$PY_BIN" -c 'import secrets; print(secrets.token_urlsafe(32))' > "$TOKEN_FILE"; fi
chmod 600 "$TOKEN_FILE"
TOKEN=$(cat "$TOKEN_FILE")

cat > "$DIR/server.sh" <<EOF
#!/bin/sh
export MAC_SCREEN_TOKEN='$TOKEN'
exec '$PY_BIN' '$DIR/server.py' --http 0.0.0.0 18766
EOF
chmod 700 "$DIR/server.sh"

LABEL=ai.opencode.mac-screen
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
: > "$DIR/server.log"
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
launchctl remove "$LABEL" >/dev/null 2>&1 || true
pkill -f "$DIR/server.py" >/dev/null 2>&1 || true
OLD_PIDS=$(lsof -tiTCP:18766 -sTCP:LISTEN 2>/dev/null || true)
if [ -n "$OLD_PIDS" ]; then kill -9 $OLD_PIDS >/dev/null 2>&1 || true; fi
sleep 1
screencapture -x /tmp/opencode_tcc_check.png && rm -f /tmp/opencode_tcc_check.png && echo "Screen Recording TCC check: OK" || echo "Screen Recording TCC check: FAILED (enable Terminal in System Settings -> Privacy & Security -> Screen Recording)"
# Start directly from the current Terminal session so macOS TCC inherits Terminal.app's Screen Recording permission
nohup "$DIR/server.sh" >>"$DIR/server.log" 2>&1 </dev/null &

"$PY_BIN" - <<'PY'
import os, sys, time, urllib.request
token = open(os.path.expanduser("~/.local/share/opencode/mac-screen-mcp/token")).read().strip()
for _ in range(20):
    try:
        req = urllib.request.Request(
            "http://127.0.0.1:18766/mcp",
            data=b'{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}',
            headers={"Content-Type":"application/json","Authorization":"Bearer "+token},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=1) as resp:
            if resp.status == 200:
                print("Local MCP server is listening and verified on 0.0.0.0:18766")
                sys.exit(0)
    except Exception:
        time.sleep(0.25)
print("Warning: port 18766 did not open yet; check ~/.local/share/opencode/mac-screen-mcp/server.log", file=sys.stderr)
sys.exit(1)
PY

printf '\nStep 2 ready on Mac (Node ID: %s).\nRun this final pairing command on Proxmox (keep token private):\n\n' "$MAC_NODE"
printf 'curl -fsSL %s/install-proxmox.sh | sh -s -- pair %s %s\n\n' "$BASE" "$MAC_NODE" "$TOKEN"
