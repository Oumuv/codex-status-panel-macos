#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BIN="${1:-$ROOT/build/Codex 状态面板.app/Contents/MacOS/CodexStatusPanel}"
ASSET="$ROOT/Resources/05-green.png"
VERIFIER="$ROOT/scripts/verify-task-animation-visual.swift"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-status-panel-visual.XXXXXX")"
trap '/bin/rm -rf "$TMP_DIR"' EXIT

if [[ ! -x "$BIN" ]]; then
  echo "没有找到可执行面板，请先运行 ./scripts/build.sh：$BIN" >&2
  exit 1
fi

PREVIEW="$TMP_DIR/completed.png"
"$BIN" --render-preview "$PREVIEW" --preview-task completed >/dev/null

/usr/bin/xcrun swift "$VERIFIER" \
  --asset "$ASSET" \
  --preview "$PREVIEW" \
  --logical-panel-width 232 \
  --max-center-error-pt 0.5 \
  --max-circle-delta-pt 0.5
