#!/usr/bin/env bash
#
# CLI 冒烟测试：dump → set-location → 回读校验 → clear-location。
# 覆盖「只改 GPS、写入后回读校验」这条核心验收线，本地与 CI 共用。
#
#   swift build && bash scripts/cli_smoke.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -x .build/release/GeoViewer ]]; then
  BIN="$ROOT/.build/release/GeoViewer"
elif [[ -x .build/debug/GeoViewer ]]; then
  BIN="$ROOT/.build/debug/GeoViewer"
else
  echo "找不到构建产物，请先运行 swift build" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 用内置图标生成一张临时 JPEG 作为测试素材（避免往仓库里塞二进制样张）
sips -s format jpeg -Z 640 Assets/AppIcon.png --out "$WORK/t.jpg" >/dev/null 2>&1

LAT_LON="30.2741,120.1551"
EXPECTED="30.274100, 120.155100"

echo "==> 1/4 dump（初始应无位置）"
"$BIN" --dump "$WORK/t.jpg" >/dev/null

echo "==> 2/4 set-location $LAT_LON"
"$BIN" --set-location "$LAT_LON" "$WORK/t.jpg"

echo "==> 3/4 回读校验"
if ! "$BIN" --dump "$WORK/t.jpg" | grep -q "$EXPECTED"; then
  echo "回读校验失败：位置未生效" >&2
  "$BIN" --dump "$WORK/t.jpg" >&2
  exit 1
fi

if ! "$BIN" --json "$WORK/t.jpg" | grep -q "30.2741"; then
  echo "JSON 输出异常：未包含坐标" >&2
  "$BIN" --json "$WORK/t.jpg" >&2
  exit 1
fi

echo "==> 4/4 clear-location"
"$BIN" --clear-location "$WORK/t.jpg"
if ! "$BIN" --dump "$WORK/t.jpg" | grep -q "位置: 未记录"; then
  echo "清除校验失败：位置仍在" >&2
  "$BIN" --dump "$WORK/t.jpg" >&2
  exit 1
fi

echo "CLI 冒烟通过"
