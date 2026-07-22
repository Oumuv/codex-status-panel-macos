#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BIN="$ROOT/build/Codex 状态面板.app/Contents/MacOS/CodexStatusPanel"
PLIST="$ROOT/Resources/io.github.mayday-materials.codex-status-panel.plist.in"
SOURCE="$ROOT/Sources/CodexStatusPanel/main.swift"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

"$ROOT/scripts/build.sh" >/dev/null

echo "检查菜单控制自测入口..."
"$BIN" --self-test-menu-controls | /usr/bin/grep -q 'menu-controls-self-test: passed'
echo "检查版本号..."
"$BIN" --print-panel-config | /usr/bin/grep -q 'version=1.2.0'
echo "检查 LaunchAgent 正常退出语义..."
/usr/bin/plutil -extract KeepAlive.SuccessfulExit raw "$PLIST" | /usr/bin/grep -q '^false$'
echo "检查手动启动用户配置读取..."
USER_CONFIG_DIR="$TMP_HOME/Library/Application Support/io.github.mayday-materials.codex-status-panel"
/bin/mkdir -p "$USER_CONFIG_DIR"
/bin/cp "$ROOT/Resources/default-panel-config.json" "$USER_CONFIG_DIR/panel-config.json"
/usr/bin/plutil -replace theme.id -string codex-user-config-test "$USER_CONFIG_DIR/panel-config.json"
HOME="$TMP_HOME" CFFIXED_USER_HOME="$TMP_HOME" "$BIN" --print-panel-config \
  | /usr/bin/grep -q 'theme=codex-user-config-test'
echo "检查缺失预览输出路径提示..."
set +e
PREVIEW_USAGE_OUTPUT="$("$BIN" --render-preview 2>&1)"
PREVIEW_USAGE_STATUS="$?"
set -e
if [[ "$PREVIEW_USAGE_STATUS" -eq 0 ]] \
  || ! /usr/bin/grep -q '用法：.*--render-preview' <<<"$PREVIEW_USAGE_OUTPUT"; then
  echo "缺少 --render-preview 输出路径时没有以失败状态返回用法提示" >&2
  exit 1
fi
echo "检查面板折叠文案..."
/usr/bin/grep -q '"折叠"' "$SOURCE"
if /usr/bin/grep -q '"隐藏"' "$SOURCE"; then
  echo '面板内仍存在“隐藏”文案' >&2
  exit 1
fi

echo "v1.2-menu-controls-test: passed"
