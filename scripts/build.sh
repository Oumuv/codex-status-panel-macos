#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/Codex 状态面板.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
cp "$ROOT/Resources/quota-panel-background.png" "$RESOURCES/quota-panel-background.png"
cp "$ROOT/Resources/default-panel-config.json" "$RESOURCES/default-panel-config.json"
for TASK_ICON in \
  task-running-icon.png \
  task-waiting-icon.png \
  task-completed-icon.png \
  task-failed-icon.png; do
  cp "$ROOT/Resources/$TASK_ICON" "$RESOURCES/$TASK_ICON"
done

for ARCH in arm64 x86_64; do
  /usr/bin/swiftc \
    -swift-version 5 \
    -O \
    -target "$ARCH-apple-macos12.3" \
    -sdk "$SDK" \
    -framework AppKit \
    -framework CoreGraphics \
    "$ROOT/Sources/CodexStatusPanel/main.swift" \
    -o "$TMP_DIR/CodexStatusPanel-$ARCH"
done

/usr/bin/lipo -create \
  "$TMP_DIR/CodexStatusPanel-arm64" \
  "$TMP_DIR/CodexStatusPanel-x86_64" \
  -output "$MACOS/CodexStatusPanel"

/usr/bin/codesign --force --deep --sign - "$APP"
echo "$APP"
