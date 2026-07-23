#!/bin/zsh
emulate -L zsh
setopt PIPE_FAIL

APP="$HOME/Applications/Codex 状态面板.app"
BIN="$APP/Contents/MacOS/CodexStatusPanel"
LABEL="io.github.mayday-materials.codex-status-panel"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
HEALTH="$HOME/Library/Caches/io.github.mayday-materials.codex-status-panel/panel-health.json"
LOG_PATH="$HOME/Library/Logs/Codex 状态面板.log"
FAILED=0

check() {
  if eval "$2"; then
    echo "✓ $1"
  else
    echo "✗ $1"
    FAILED=1
  fi
}

echo "Codex 状态面板安装检查"
echo "────────────────────"
check "面板 App 已安装" '[[ -x "$BIN" ]]'
check "面板支持当前 Mac" '[[ -x "$BIN" ]] && /usr/bin/lipo "$BIN" -verify_arch "$(/usr/bin/uname -m)"'
check "面板签名正常" '[[ -d "$APP" ]] && /usr/bin/codesign --verify --deep --strict "$APP"'
check "登录启动项存在" '[[ -f "$PLIST" ]]'
check "登录启动项格式正常" '[[ -f "$PLIST" ]] && /usr/bin/plutil -lint "$PLIST" >/dev/null'
check "面板进程正在运行" '/bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null | /usr/bin/grep -Eq "^[[:space:]]*pid = [0-9]+"'
check "健康状态版本正确" '[[ -s "$HEALTH" ]] && /usr/bin/grep -q '"'"'"version":"1.2.1"'"'"' "$HEALTH"'
check "行情开关状态可读" '[[ -s "$HEALTH" ]] && /usr/bin/grep -Eq '"'"'"marketPricesEnabled":(true|false)'"'"' "$HEALTH"'
check "配置打印正常" '[[ -x "$BIN" ]] && "$BIN" --print-panel-config >/dev/null'
check "跟随定位自测正常" '[[ -x "$BIN" ]] && "$BIN" --self-test-placement >/dev/null'
check "菜单控制自测正常" '[[ -x "$BIN" ]] && "$BIN" --self-test-menu-controls >/dev/null'
check "任务进度自测正常" '[[ -x "$BIN" ]] && "$BIN" --self-test-task-progress >/dev/null'
check "认证回退自测正常" '[[ -x "$BIN" ]] && "$BIN" --self-test-authentication-fallback >/dev/null'
check "正常退出不会立即重启" '[[ -f "$PLIST" ]] && [[ "$(/usr/bin/plutil -extract KeepAlive.SuccessfulExit raw "$PLIST" 2>/dev/null)" == "false" ]]'

if [[ -s "$HEALTH" ]]; then
  echo ""
  echo "面板状态："
  /bin/cat "$HEALTH"
  echo ""
fi

if [[ -x "$BIN" ]]; then
  echo ""
  echo "Codex 额度读取："
  if "$BIN" --print-quota; then
    :
  else
    echo "Codex 未连接或未登录；这不代表安装损坏。"
  fi
fi

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "全部安装检查通过。"
else
  echo "有项目未通过。日志：$LOG_PATH"
fi

if [[ -t 0 ]]; then
  echo ""
  read -k 1 "?按任意键关闭…"
  echo ""
fi
exit "$FAILED"
