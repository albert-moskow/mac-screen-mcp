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
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "mac-screen"
SERVER_VERSION = "0.2.0"

# A minimal 1x1 transparent PNG used as a safe fallback on non-macOS test systems
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


def request_access(reason: str, duration_seconds: int = 14400) -> dict[str, Any]:
    if has_active_consent():
        remaining = int(max(0, SESSION_STATE["expires_at"] - time.time()))
        return {
            "approved": True,
            "platform": platform.system(),
            "version": SERVER_VERSION,
            "expires_in_seconds": remaining,
            "reason": SESSION_STATE["reason"],
            "reused_session": True,
        }
    duration_seconds = max(60, min(int(duration_seconds), 43200))
    if is_macos():
        approved = prompt_macos_consent(reason, duration_seconds)
    else:
        # On Linux/dev environment, only approve when explicitly enabled via env var
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


def search_google(query: str) -> str:
    if not has_active_consent():
        raise PermissionError(
            "Нет активного разрешения. Сначала вызовите request_screen_access."
        )
    query = query.strip()
    if not query or len(query) > 200:
        raise ValueError("Search query must contain 1–200 characters")
    url = "https://www.google.com/search?q=" + urllib.parse.quote_plus(query)
    subprocess.run(["open", url], check=True, timeout=10)
    return "Opened Google search in the default Mac browser: " + query


def run_chrome_js(js_code: str) -> str:
    escaped = js_code.replace("\\", "\\\\").replace('"', '\\"')
    script = f'tell application "Google Chrome" to execute active tab of front window javascript "{escaped}"'
    proc = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    if proc.returncode != 0:
        err = proc.stderr.strip() or f"код {proc.returncode}"
        raise RuntimeError(
            "Не удалось выполнить действие в Chrome (включите в Chrome: Вид -> Разработчик -> Разрешить JavaScript из Apple Events): "
            + err
        )
    return proc.stdout.strip()


def read_chrome_tab() -> str:
    if not has_active_consent():
        raise PermissionError(
            "Нет активного разрешения. Сначала вызовите request_screen_access."
        )
    js = (
        "(function(){"
        "var items = Array.from(document.querySelectorAll('a,button,[role=button],input[type=submit],[data-identifier]'))"
        ".map(function(el){return (el.innerText||el.value||el.getAttribute('aria-label')||'').trim().replace(/\\s+/g,' ');})"
        ".filter(function(t){return t.length>0 && t.length<=120;})"
        ".slice(0,40);"
        "return JSON.stringify({title:document.title,url:location.href,clickables:items});"
        "})()"
    )
    return run_chrome_js(js)


def click_chrome_element(target_text: str) -> str:
    if not has_active_consent():
        raise PermissionError(
            "Нет активного разрешения. Сначала вызовите request_screen_access."
        )
    target_text = target_text.strip()
    if not target_text or len(target_text) > 120:
        raise ValueError("target_text must contain 1–120 characters")
    target_json = json.dumps(target_text, ensure_ascii=False)
    js = (
        "(function(){"
        f"var needle = ({target_json}).toLowerCase();"
        "var nodes = Array.from(document.querySelectorAll('a,button,[role=button],input[type=submit],[data-identifier],div[tabindex=\"0\"]'));"
        "function label(el){return (el.innerText||el.value||el.getAttribute('aria-label')||el.getAttribute('data-identifier')||'').trim().replace(/\\s+/g,' ');}"
        "var exact = nodes.filter(function(el){return label(el).toLowerCase() === needle;});"
        "var partial = nodes.filter(function(el){var t = label(el).toLowerCase(); return t.length > 0 && t.indexOf(needle) !== -1;});"
        "partial.sort(function(a,b){return label(a).length - label(b).length;});"
        "var match = exact[exact.length - 1] || partial[0];"
        "if(!match) return 'NOT_FOUND';"
        "match.click();"
        "return 'CLICKED: ' + label(match).slice(0,80);"
        "})()"
    )
    return run_chrome_js(js)


def capture_screen() -> dict[str, Any]:
    if not has_active_consent():
        raise PermissionError(
            "Нет активного разрешения на снимок экрана. Сначала вызовите request_screen_access."
        )

    if is_macos():
        with tempfile.NamedTemporaryFile(prefix="opencode_screen_", suffix=".png", delete=False) as tmp:
            tmp_path = tmp.name
        jpeg_path = tmp_path[:-4] + ".jpg"
        try:
            proc = subprocess.run(
                ["screencapture", "-x", tmp_path],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
            if proc.returncode != 0 or not os.path.exists(tmp_path):
                # Fallback when LaunchAgent lacks direct TCC Screen Recording:
                # run screencapture via Terminal.app which has Screen Recording permission.
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
                ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "55", "-Z", "1280", tmp_path, "--out", jpeg_path],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            if not os.path.exists(jpeg_path):
                raise RuntimeError("Не удалось сжать снимок экрана в JPEG через sips.")
            with open(jpeg_path, "rb") as f:
                data_b64 = base64.b64encode(f.read()).decode("ascii")
            return {
                "mimeType": "image/jpeg",
                "data": data_b64,
                "note": "Снимок экрана macOS сжат в JPEG 1280px.",
            }
        finally:
            for path in (tmp_path, jpeg_path):
                if os.path.exists(path):
                    try:
                        os.remove(path)
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
                    "description": "На сколько секунд выдать доступ на сессию (от 60 до 43200, по умолчанию 14400 = 4 часа).",
                    "default": 14400,
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
    {
        "name": "search_google",
        "description": "Открывает Google-поиск с заданным текстом в браузере Mac.",
        "inputSchema": {
            "type": "object",
            "properties": {"query": {"type": "string", "minLength": 1, "maxLength": 200}},
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "read_chrome_tab",
        "description": "Читает заголовок, URL и список кликабельных кнопок/ссылок активной вкладки Google Chrome на Mac (без движения мыши).",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
    {
        "name": "click_chrome_element",
        "description": "Нажимает кнопку или ссылку в активной вкладке Google Chrome на Mac по тексту или email/метке (с подтверждением и без движения мыши).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target_text": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 120,
                    "description": "Текст кнопки, ссылки или email аккаунта, по которому нужно кликнуть.",
                }
            },
            "required": ["target_text"],
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
            duration = int(arguments.get("duration_seconds", 14400))
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

        if name == "search_google":
            result = search_google(str(arguments.get("query", "")))
            send_message({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"content": [{"type": "text", "text": result}], "isError": False},
            })
            return

        if name == "read_chrome_tab":
            result = read_chrome_tab()
            send_message({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"content": [{"type": "text", "text": result}], "isError": False},
            })
            return

        if name == "click_chrome_element":
            result = click_chrome_element(str(arguments.get("target_text", "")))
            send_message({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"content": [{"type": "text", "text": result}], "isError": result == "NOT_FOUND"},
            })
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
                        "Вызывай request_screen_access один раз в начале сессии (разрешение действует на всю сессию). "
                        "НЕ вызывай revoke_screen_access после каждого действия — вызывай revoke_screen_access только когда пользователь явно попросит отключиться."
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


class LocalCallbackRelayHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        pass

    def do_GET(self) -> None:
        if not self.path.startswith("/callback"):
            self.send_error(404, "Not found")
            return
        try:
            req = urllib.request.Request(
                "http://10.147.20.1:8765" + self.path,
                headers={"Host": "127.0.0.1:8765"},
                method="GET",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = resp.read()
                status = resp.status
        except urllib.error.HTTPError as exc:
            body = exc.read()
            status = exc.code
        except Exception as exc:
            body = f"Relay error: {exc}".encode("utf-8")
            status = 502
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def start_callback_relay() -> None:
    try:
        relay = ReusableHTTPServer(("127.0.0.1", 8765), LocalCallbackRelayHandler)
        threading.Thread(target=relay.serve_forever, daemon=True).start()
    except OSError:
        pass


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--http":
        if not os.environ.get("MAC_SCREEN_TOKEN"):
            raise SystemExit("MAC_SCREEN_TOKEN is required")
        host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
        port = int(sys.argv[3]) if len(sys.argv) > 3 else 18766
        start_callback_relay()
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
