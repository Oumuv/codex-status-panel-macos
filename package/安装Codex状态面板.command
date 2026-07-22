#!/bin/zsh
emulate -L zsh
setopt ERR_EXIT PIPE_FAIL NO_UNSET

ROOT="${0:A:h}"
APP_SOURCE="$ROOT/panel/Codex 状态面板.app"
APP_DEST="$HOME/Applications/Codex 状态面板.app"
APP_BINARY="$APP_DEST/Contents/MacOS/CodexStatusPanel"
LABEL="io.github.mayday-materials.codex-status-panel"
PLIST_SOURCE="$ROOT/panel/$LABEL.plist.in"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_SOURCE="$ROOT/panel/default-panel-config.json"
CONFIG_DIR="$HOME/Library/Application Support/io.github.mayday-materials.codex-status-panel"
CONFIG_PATH="$CONFIG_DIR/panel-config.json"
LOG_PATH="$HOME/Library/Logs/Codex 状态面板.log"
HEALTH_DIR="$HOME/Library/Caches/io.github.mayday-materials.codex-status-panel"
HEALTH_PATH="$HEALTH_DIR/panel-health.json"
DOMAIN="gui/$(id -u)"
PANEL_VERSION="1.2.0"

pause_before_exit() {
  if [[ -t 0 ]]; then
    echo ""
    read -k 1 "?按任意键关闭…"
    echo ""
  fi
}

fail() {
  echo ""
  echo "安装失败：$1"
  if [[ -s "$LOG_PATH" ]]; then
    echo ""
    echo "面板日志最后 12 行："
    /usr/bin/tail -n 12 "$LOG_PATH" 2>/dev/null || true
  fi
  pause_before_exit
  exit 1
}

panel_service_has_pid() {
  /bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null \
    | /usr/bin/grep -Eq '^[[:space:]]*pid = [0-9]+'
}

panel_health_is_current() {
  [[ -s "$HEALTH_PATH" ]] \
    && /usr/bin/grep -q '"version":"'"$PANEL_VERSION"'"' "$HEALTH_PATH" 2>/dev/null \
    && /usr/bin/grep -q '"marketPricesEnabled":false' "$HEALTH_PATH" 2>/dev/null
}

wait_for_panel_health() {
  local attempt
  for attempt in {1..80}; do
    if panel_service_has_pid && panel_health_is_current; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

echo "正在安装 Codex 状态面板（macOS Universal 开源版 $PANEL_VERSION）…"

MACOS_VERSION="$(/usr/bin/sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
MACOS_REMAINDER="${MACOS_VERSION#*.}"
MACOS_MINOR="${MACOS_REMAINDER%%.*}"
if (( MACOS_MAJOR < 12 || (MACOS_MAJOR == 12 && MACOS_MINOR < 3) )); then
  fail "需要 macOS 12.3 或更高版本，当前版本为 $MACOS_VERSION。"
fi

[[ -d "$APP_SOURCE" && -x "$APP_SOURCE/Contents/MacOS/CodexStatusPanel" ]] \
  || fail "面板 App 文件不完整，请重新解压整个分享包。"
[[ -f "$PLIST_SOURCE" && -f "$CONFIG_SOURCE" ]] \
  || fail "启动项模板或默认配置缺失，请重新解压整个分享包。"

ARCH="$(/usr/bin/uname -m)"
[[ "$ARCH" == "arm64" || "$ARCH" == "x86_64" ]] \
  || fail "不支持当前 Mac 架构：$ARCH。"
/usr/bin/lipo "$APP_SOURCE/Contents/MacOS/CodexStatusPanel" -verify_arch "$ARCH" \
  || fail "面板不包含 $ARCH 架构。"
/usr/bin/plutil -lint "$PLIST_SOURCE" >/dev/null \
  || fail "启动项模板格式异常，请重新下载分享包。"
/usr/bin/codesign --verify --deep --strict "$APP_SOURCE" \
  || fail "面板签名校验失败，请重新下载分享包。"

mkdir -p "$HOME/Applications" \
  "$HOME/Library/LaunchAgents" \
  "$HOME/Library/Logs" \
  "$HEALTH_DIR" \
  "$CONFIG_DIR"

for EXISTING_PLIST in "$HOME/Library/LaunchAgents"/*.plist(N); do
  EXISTING_LABEL="$(/usr/bin/plutil -extract Label raw "$EXISTING_PLIST" 2>/dev/null || true)"
  EXISTING_EXECUTABLE="$(/usr/bin/plutil -extract ProgramArguments.0 raw "$EXISTING_PLIST" 2>/dev/null || true)"
  if [[ "$EXISTING_LABEL" == "$LABEL" \
        || "$EXISTING_EXECUTABLE" == *"Codex 状态面板.app/Contents/MacOS/CodexStatusPanel"* ]]; then
    /bin/launchctl bootout "$DOMAIN" "$EXISTING_PLIST" 2>/dev/null || true
    /bin/rm -f "$EXISTING_PLIST"
  fi
done
/bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in {1..20}; do
  /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  /bin/sleep 0.1
done

/bin/rm -rf "$APP_DEST"
/usr/bin/ditto "$APP_SOURCE" "$APP_DEST"
/usr/bin/xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP_DEST" >/dev/null
/bin/rm -f "$HEALTH_PATH"

if [[ ! -f "$CONFIG_PATH" ]]; then
  /bin/cp "$CONFIG_SOURCE" "$CONFIG_PATH"
  echo "已创建默认配置：$CONFIG_PATH"
else
  echo "保留已有配置：$CONFIG_PATH"
fi

/bin/cp "$PLIST_SOURCE" "$PLIST_DEST"
/usr/bin/plutil -replace ProgramArguments.0 -string "$APP_BINARY" "$PLIST_DEST"
/usr/bin/plutil -replace EnvironmentVariables.CODEX_STATUS_PANEL_CONFIG -string "$CONFIG_PATH" "$PLIST_DEST"
/usr/bin/plutil -replace EnvironmentVariables.CODEX_STATUS_PANEL_HEALTH_FILE -string "$HEALTH_PATH" "$PLIST_DEST"
/usr/bin/plutil -replace EnvironmentVariables.CODEX_STATUS_PANEL_SHOW_MARKET_PRICES -string false "$PLIST_DEST"
/usr/bin/plutil -replace KeepAlive.SuccessfulExit -bool false "$PLIST_DEST"
/usr/bin/plutil -replace StandardErrorPath -string "$LOG_PATH" "$PLIST_DEST"
/usr/bin/plutil -replace StandardOutPath -string "$LOG_PATH" "$PLIST_DEST"
/usr/bin/plutil -lint "$PLIST_DEST" >/dev/null

if ! /bin/launchctl bootstrap "$DOMAIN" "$PLIST_DEST"; then
  /bin/sleep 1
  /bin/launchctl bootstrap "$DOMAIN" "$PLIST_DEST" \
    || fail "无法注册面板登录启动项。"
fi
/bin/launchctl kickstart -k "$DOMAIN/$LABEL" \
  || fail "面板启动请求失败。"

if ! wait_for_panel_health; then
  echo "首次启动未通过自检，正在自动重试…"
  /bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  /bin/sleep 0.5
  /bin/launchctl bootstrap "$DOMAIN" "$PLIST_DEST" \
    || fail "面板重试注册失败。"
  /bin/launchctl kickstart -k "$DOMAIN/$LABEL" \
    || fail "面板重试启动失败。"
  wait_for_panel_health \
    || fail "面板进程没有保持运行。请把上面的日志发给维护者。"
fi

echo ""
echo "安装完成："
echo "  ✓ Codex 状态面板"
echo "  ✓ 可编辑配置文件"
echo "  ✓ 随登录自动启动"
echo ""
echo "配置文件：$CONFIG_PATH"
echo "日志文件：$LOG_PATH"
echo "额度读取使用本机 Codex 登录状态，不需要 API Key。"
pause_before_exit
