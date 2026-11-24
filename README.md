# mac-screen MCP

Remote screenshot MCP server for OpenCode. Mac runs the server; OpenCode connects over Tailscale HTTPS. The server only captures after a local macOS consent dialog. It does not control mouse or keyboard.

## Setup

1. Install and sign in to Tailscale on Mac and on the same Proxmox/OpenCode host. Keep both devices in your own tailnet. Do not enable Tailscale Funnel or public port forwarding.
2. On Mac, run:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/albert-moskow/mac-screen-mcp/main/install-macos.sh | sh
   ```

   Installer prints a second command containing Mac's private Tailscale URL and random bearer token.
3. Run that printed command inside the same Proxmox/container/user environment where OpenCode runs. It installs remote MCP config. OpenCode reloads config; check `/mcps`.
4. Invoke `mac-screen_request_screen_access`, then `mac-screen_capture_screen`. Revoke with `mac-screen_revoke_screen_access`.

Each install generates its own random token. Token grants remote access to MCP tools; keep it private. Tailscale account and device login are required; GitHub hosts code only and does not relay screen data.

## Uninstall from Mac

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/ai.opencode.mac-screen.plist"; tailscale serve --https=443 off; rm -rf "$HOME/.local/share/opencode/mac-screen-mcp" "$HOME/Library/LaunchAgents/ai.opencode.mac-screen.plist"
```

Remove `mac-screen` from `mcp.servers` in OpenCode config on Proxmox to disconnect the client.

## Check

```sh
python3 -m unittest test_server.py
```
