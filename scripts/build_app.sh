#!/bin/bash
# 构建「Perch」并安装到 /Applications 或 ~/Applications
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build (release)"
swift build -c release --disable-sandbox --product RecordTree 2>&1 | tail -5
BIN_PATH="$(swift build -c release --disable-sandbox --show-bin-path)/RecordTree"

APP_NAME="Perch"
DEST=""
if [[ -w /Applications ]]; then
  DEST="/Applications/$APP_NAME.app"
else
  DEST="$HOME/Applications/$APP_NAME.app"
  mkdir -p "$HOME/Applications"
fi

echo "==> assemble $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BIN_PATH" "$DEST/Contents/MacOS/RecordTree"
cp Info.plist "$DEST/Contents/Info.plist"
# 中英文显示名本地化
cp -R Resources/ "$DEST/Contents/Resources/"

# 生成 AppIcon.icns
ICON_SRC="assets/AppIcon.png"
if [[ -f "$ICON_SRC" ]]; then
  echo "==> make AppIcon.icns"
  TMP_ROOT="$(mktemp -d)"
  ICONSET="$TMP_ROOT/AppIcon.iconset"
  mkdir -p "$ICONSET"
  declare -a SPECS=(
    "16 icon_16x16.png"
    "32 icon_16x16@2x.png"
    "32 icon_32x32.png"
    "64 icon_32x32@2x.png"
    "128 icon_128x128.png"
    "256 icon_128x128@2x.png"
    "256 icon_256x256.png"
    "512 icon_256x256@2x.png"
    "512 icon_512x512.png"
    "1024 icon_512x512@2x.png"
  )
  for spec in "${SPECS[@]}"; do
    size="${spec%% *}"
    name="${spec##* }"
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/$name" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$DEST/Contents/Resources/AppIcon.icns"
  rm -rf "$TMP_ROOT"
else
  echo "!! 缺少 $ICON_SRC，跳过图标" >&2
fi

if command -v codesign >/dev/null 2>&1; then
  echo "==> ad-hoc codesign"
  codesign --force --sign - "$DEST" >/dev/null 2>&1 || true
fi

# 清理旧版 RecordTree.app / 栖痕.app，避免多个包并存
for legacy in \
  "/Applications/RecordTree.app" "$HOME/Applications/RecordTree.app" \
  "/Applications/栖痕.app" "$HOME/Applications/栖痕.app"; do
  if [[ -e "$legacy" ]]; then
    echo "==> remove legacy $legacy"
    rm -rf "$legacy"
  fi
done

# 刷新 LaunchServices 注册（确保中文/英文显示名立即生效）
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -f "$DEST" >/dev/null 2>&1 || true

echo "==> installed: $DEST"
echo "RUN: open \"$DEST\""
