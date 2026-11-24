# mac-screen MCP

## Русский

Удалённый MCP-сервер снимков экрана для OpenCode. Сервер работает на Mac, OpenCode подключается через приватную сеть Tailscale. Снимок делается только после подтверждения в системном окне macOS. Управления мышью и клавиатурой нет.

### Установка

1. Установи и войди в Tailscale на Mac и Proxmox. Оба устройства должны быть в одном tailnet. Не включай Tailscale Funnel и не открывай публичные порты.
2. На Mac выполни:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main/install-macos.sh | sh
   ```

   Установщик выведет вторую команду с приватным адресом Mac в Tailscale и случайным секретным токеном.
3. Выполни напечатанную команду в том же окружении и от имени того же пользователя, где запущен OpenCode на Proxmox. Она добавит MCP-сервер в конфигурацию.
4. Проверь `/mcps` в OpenCode. Для снимка вызови `mac-screen_request_screen_access`, подтверди запрос на Mac, затем вызови `mac-screen_capture_screen`. Для отключения доступа вызови `mac-screen_revoke_screen_access`.

Каждая установка создаёт собственный случайный токен. Не публикуй токен и команду сопряжения: токен даёт доступ к MCP-серверу. Нужен вход в Tailscale на обоих устройствах. GitHub хранит только код и не передаёт снимки экрана.

### Удаление с Mac

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/ai.opencode.mac-screen.plist"; tailscale serve --https=443 off; rm -rf "$HOME/.local/share/opencode/mac-screen-mcp" "$HOME/Library/LaunchAgents/ai.opencode.mac-screen.plist"
```

На Proxmox удали `mac-screen` из `mcp.servers` в конфигурации OpenCode.

## English

Remote screenshot MCP server for OpenCode. The server runs on Mac; OpenCode connects over a private Tailscale network. Screen capture only runs after approval in a macOS system dialog. Mouse and keyboard control are not included.

### Setup

1. Install and sign in to Tailscale on Mac and Proxmox. Keep both devices in the same tailnet. Do not enable Tailscale Funnel or expose public ports.
2. On Mac, run:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main/install-macos.sh | sh
   ```

   The installer prints a second command containing Mac's private Tailscale address and a random secret token.
3. Run that printed command in the same environment and as the same user that runs OpenCode on Proxmox. It adds the MCP server to OpenCode configuration.
4. Check `/mcps` in OpenCode. To capture a screen, call `mac-screen_request_screen_access`, approve the prompt on Mac, then call `mac-screen_capture_screen`. Revoke access with `mac-screen_revoke_screen_access`.

Each installation creates its own random token. Keep the token and pairing command private: the token grants access to the MCP server. Tailscale sign-in is required on both devices. GitHub hosts code only; screen captures are not sent to GitHub.

### Uninstall from Mac

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/ai.opencode.mac-screen.plist"; tailscale serve --https=443 off; rm -rf "$HOME/.local/share/opencode/mac-screen-mcp" "$HOME/Library/LaunchAgents/ai.opencode.mac-screen.plist"
```

On Proxmox, remove `mac-screen` from `mcp.servers` in OpenCode configuration.

## Tests / Тесты

```sh
python3 -m unittest test_server.py
```
