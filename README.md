# mac-screen MCP

## Русский

Удалённый MCP-сервер снимков экрана для OpenCode через **автономный ZeroTier** (локальный контроллер сети поднимается прямо на Proxmox — без аккаунтов и регистрации на сайте). Снимок делается только после подтверждения в системном окне macOS.

### Установка (3 команды)

1. **На сервере (Proxmox)** создай приватную сеть ZeroTier:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main/install-proxmox.sh | sh
   ```
2. **На Mac** выполни команду, которую напечатал шаг 1 (она поставит ZeroTier, подключит Mac к сети и запустит MCP-сервер).
3. **На сервере (Proxmox)** выполни финальную команду `pair`, которую напечатал Mac (не публикуй её в чате — в ней секретный токен).

После этого проверь `/mcps` в OpenCode.

## English

Remote screenshot MCP server for OpenCode over **self-hosted ZeroTier** (the network controller runs directly on your Proxmox host — no accounts or web sign-up required). Screen capture only runs after approval in a macOS system dialog.

### Setup (3 commands)

1. **On Proxmox**, create your private ZeroTier network:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main/install-proxmox.sh | sh
   ```
2. **On Mac**, run the command printed by step 1 (installs ZeroTier, joins the network, and starts the MCP server).
3. **On Proxmox**, run the final `pair` command printed by your Mac (keep it private — it contains your bearer token).

Then check `/mcps` in OpenCode.
