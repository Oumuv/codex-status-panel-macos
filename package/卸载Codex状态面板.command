#!/bin/zsh
emulate -L zsh
setopt ERR_EXIT PIPE_FAIL NO_UNSET

APP_DEST="$HOME/Applications/Codex 状态面板.app"
LABEL="io.github.mayday-materials.codex-status-panel"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
HEALTH_PATH="$HOME/Library/Caches/io.github.mayday-materials.codex-status-panel/panel-health.json"
CONFIG_PATH="$HOME/Library/Application Support/io.github.mayday-materials.codex-status-panel/panel-config.json"
CONFIG_DIR="${CONFIG_PATH:h}"
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
if [[ "$PI_AGENT_DIR" == '~/'* ]]; then
  PI_AGENT_DIR="$HOME/${PI_AGENT_DIR#\~/}"
fi
PI_EXTENSION_PATH="$PI_AGENT_DIR/extensions/io.github.mayday-materials.codex-status-panel.ts"
PI_STATE_DIR="$CONFIG_DIR/pi-sessions"
DOMAIN="gui/$(id -u)"

/bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
/bin/rm -f "$PLIST_DEST"
/bin/rm -rf "$APP_DEST"
/bin/rm -f "$HEALTH_PATH"
/bin/rm -f "$PI_EXTENSION_PATH"
/bin/rm -rf "$PI_STATE_DIR"
/bin/rmdir "${PI_EXTENSION_PATH:h}" 2>/dev/null || true

echo "Codex 状态面板与 Pi CLI 状态桥接已卸载。"
echo "保留的用户配置：$CONFIG_PATH"
if [[ -t 0 ]]; then
  echo ""
  read -k 1 "?按任意键关闭…"
  echo ""
fi
