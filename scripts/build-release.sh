#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="1.2.4"
STAGE_ROOT="$ROOT/build/release"
STAGE="$STAGE_ROOT/Codex状态面板-macOS"
OUT="$ROOT/dist/Codex-Status-Panel-macOS-Universal-v$VERSION.zip"
LABEL="io.github.mayday-materials.codex-status-panel"

"$ROOT/scripts/build.sh" >/dev/null

/bin/rm -rf "$STAGE"
/bin/mkdir -p "$STAGE/panel" "$ROOT/dist"

/usr/bin/ditto "$ROOT/build/Codex 状态面板.app" "$STAGE/panel/Codex 状态面板.app"
/bin/cp "$ROOT/Resources/$LABEL.plist.in" "$STAGE/panel/$LABEL.plist.in"
/bin/cp "$ROOT/Resources/default-panel-config.json" "$STAGE/panel/default-panel-config.json"
/bin/cp "$ROOT/README.md" "$STAGE/README.md"
/usr/bin/printf 'Codex Status Panel macOS Universal v%s\n' "$VERSION" > "$STAGE/VERSION.txt"
/bin/cp "$ROOT/LICENSE" "$ROOT/PRIVACY.md" "$ROOT/ASSET-NOTICE.md" "$STAGE/"
/bin/cp "$ROOT/package/安装Codex状态面板.command" "$STAGE/安装Codex状态面板.command"
/bin/cp "$ROOT/package/检查Codex状态面板.command" "$STAGE/检查Codex状态面板.command"
/bin/cp "$ROOT/package/卸载Codex状态面板.command" "$STAGE/卸载Codex状态面板.command"
/bin/chmod +x "$STAGE"/*.command

for forbidden in pet preview shared CODEX-ONLY.txt; do
  if [[ -e "$STAGE/$forbidden" ]]; then
    echo "Forbidden stage entry exists: $forbidden" >&2
    exit 1
  fi
done

(
  cd "$STAGE"
  export LC_ALL=C
  find . -type f ! -name CHECKSUMS-SHA256.txt -print | sort |
    while IFS= read -r file; do /usr/bin/shasum -a 256 "$file"; done > CHECKSUMS-SHA256.txt
)

/bin/rm -f "$OUT"
/usr/bin/ditto -c -k --norsrc --keepParent "$STAGE" "$OUT"
printf '%s\n' "$OUT"
