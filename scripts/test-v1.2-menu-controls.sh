#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BIN="$ROOT/build/Codex 状态面板.app/Contents/MacOS/CodexStatusPanel"
BUILT_INFO_PLIST="$ROOT/build/Codex 状态面板.app/Contents/Info.plist"
PLIST="$ROOT/Resources/io.github.mayday-materials.codex-status-panel.plist.in"
INFO_PLIST="$ROOT/Resources/Info.plist"
SOURCE_DIR="$ROOT/Sources/CodexStatusPanel"
PANEL_CONFIGURATION="$SOURCE_DIR/PanelConfiguration.swift"
INSTALLER="$ROOT/package/安装Codex状态面板.command"
CHECKER="$ROOT/package/检查Codex状态面板.command"
RELEASE_BUILDER="$ROOT/scripts/build-release.sh"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

EXPECTED_VERSION="$(
  /usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO_PLIST"
)"
EXPECTED_BUILD_NUMBER="$(
  /usr/bin/plutil -extract CFBundleVersion raw "$INFO_PLIST"
)"

"$ROOT/scripts/build.sh" >/dev/null

echo "检查第三方用量 Provider 自测入口..."
"$BIN" --self-test-usage-provider \
  | /usr/bin/grep -q 'usage-provider-self-test:.*errors=17/17'
echo "检查新旧 Codex 桌宠状态兼容..."
"$BIN" --self-test-placement \
  | /usr/bin/grep -q 'legacy-state=pass; compact-state=pass; anchor-state=pass; self-window=pass'
echo "检查菜单控制自测入口..."
"$BIN" --self-test-menu-controls | /usr/bin/grep -q 'menu-controls-self-test: passed'
echo "检查行情数据自测入口..."
"$BIN" --self-test-market-data \
  | /usr/bin/grep -q 'market-data-self-test:.*bounds=pass'
echo "检查任务进度自测入口..."
"$BIN" --self-test-task-progress \
  | /usr/bin/grep -q 'task-progress-self-test:.*incremental=16/16;.*icons=4/4'
echo "检查认证回退自测入口..."
"$BIN" --self-test-authentication-fallback \
  | /usr/bin/grep -q 'authentication-fallback-self-test:.*presentation=3/3'
echo "检查版本号..."
PANEL_CONFIG_OUTPUT="$("$BIN" --print-panel-config)"
/usr/bin/grep -q \
  "version=${EXPECTED_VERSION}.*stockPricesEnabled=.*cryptoSeconds=5.*stockSeconds=30" \
  <<<"$PANEL_CONFIG_OUTPUT"
BUILT_VERSION="$(
  /usr/bin/plutil -extract CFBundleShortVersionString raw "$BUILT_INFO_PLIST"
)"
BUILT_BUILD_NUMBER="$(
  /usr/bin/plutil -extract CFBundleVersion raw "$BUILT_INFO_PLIST"
)"
if [[ "$BUILT_VERSION" != "$EXPECTED_VERSION" \
      || "$BUILT_BUILD_NUMBER" != "$EXPECTED_BUILD_NUMBER" ]]; then
  echo "构建产物版本与 Resources/Info.plist 不一致" >&2
  exit 1
fi
if /usr/bin/grep -Eq '[[:digit:]]+[.][[:digit:]]+[.][[:digit:]]+' \
  "$PANEL_CONFIGURATION" "$INSTALLER" "$CHECKER" "$RELEASE_BUILDER"; then
  echo "版本消费端仍存在三段式版本硬编码" >&2
  exit 1
fi
echo "检查 LaunchAgent 正常退出语义..."
/usr/bin/plutil -extract KeepAlive.SuccessfulExit raw "$PLIST" | /usr/bin/grep -q '^false$'
echo "检查行情开关健康状态兼容..."
if /usr/bin/grep -q '"marketPricesEnabled":false' "$INSTALLER" "$CHECKER"; then
  echo "安装或检查脚本仍把用户行情开关硬编码为关闭" >&2
  exit 1
fi
echo "检查手动启动用户配置读取..."
USER_CONFIG_DIR="$TMP_HOME/Library/Application Support/io.github.mayday-materials.codex-status-panel"
/bin/mkdir -p "$USER_CONFIG_DIR"
/bin/cp "$ROOT/Resources/default-panel-config.json" "$USER_CONFIG_DIR/panel-config.json"
/usr/bin/plutil -replace theme.id -string codex-user-config-test "$USER_CONFIG_DIR/panel-config.json"
HOME="$TMP_HOME" CFFIXED_USER_HOME="$TMP_HOME" "$BIN" --print-panel-config \
  | /usr/bin/grep -q 'theme=codex-user-config-test'
/usr/bin/plutil -replace usageProvider.baseUrl -string https://example.com \
  "$USER_CONFIG_DIR/panel-config.json"
/usr/bin/plutil -replace usageProvider.apiKey -string self-test-panel-secret \
  "$USER_CONFIG_DIR/panel-config.json"
CONFIG_OUTPUT="$(HOME="$TMP_HOME" CFFIXED_USER_HOME="$TMP_HOME" \
  "$BIN" --print-panel-config)"
if /usr/bin/grep -q \
  'self-test-panel-secret\|https://example.com' <<<"$CONFIG_OUTPUT"; then
  echo "配置诊断输出泄露了 Provider URL 或 API Key" >&2
  exit 1
fi
/usr/bin/grep -q \
  'usageProvider=sub2api usageProviderConfigured=true' <<<"$CONFIG_OUTPUT"
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
echo "检查八种用量预览..."
for PREVIEW_MODE in \
  codex unconfigured sub2api-wallet sub2api-empty-wallet \
  sub2api-rate-1d sub2api-rate-7d sub2api-warning sub2api-danger; do
  PREVIEW_PATH="$TMP_HOME/$PREVIEW_MODE.png"
  "$BIN" --render-preview "$PREVIEW_PATH" \
    --preview-usage "$PREVIEW_MODE" >/dev/null
  /usr/bin/file "$PREVIEW_PATH" | /usr/bin/grep -q 'PNG image data'
done
echo "检查面板折叠文案..."
/usr/bin/grep -R -q --include='*.swift' '"折叠"' "$SOURCE_DIR"
if /usr/bin/grep -R -q --include='*.swift' '"隐藏"' "$SOURCE_DIR"; then
  echo '面板内仍存在“隐藏”文案' >&2
  exit 1
fi

echo "v${EXPECTED_VERSION}-market-data-test: passed"
