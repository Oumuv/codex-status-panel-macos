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
SWIFT_SOURCES=("$ROOT"/Sources/CodexStatusPanel/**/*.swift(N))

if (( ${#SWIFT_SOURCES[@]} == 0 )); then
  echo "没有找到 Swift 源文件：$ROOT/Sources/CodexStatusPanel" >&2
  exit 1
fi

/bin/rm -rf "$APP"
/bin/mkdir -p "$MACOS" "$RESOURCES"
/usr/bin/ditto "$ROOT/Resources" "$RESOURCES"
/bin/mv "$RESOURCES/Info.plist" "$CONTENTS/Info.plist"

for ARCH in arm64 x86_64; do
  /usr/bin/swiftc \
    -swift-version 5 \
    -O \
    -target "$ARCH-apple-macos12.3" \
    -sdk "$SDK" \
    -framework AppKit \
    -framework CoreGraphics \
    "${SWIFT_SOURCES[@]}" \
    -o "$TMP_DIR/CodexStatusPanel-$ARCH"
done

/usr/bin/lipo -create \
  "$TMP_DIR/CodexStatusPanel-arm64" \
  "$TMP_DIR/CodexStatusPanel-x86_64" \
  -output "$MACOS/CodexStatusPanel"

/usr/bin/codesign --force --deep --sign - "$APP"
echo "$APP"
