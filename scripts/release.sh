#!/usr/bin/env bash
#
# Perch 生产发布流水线：构建（通用二进制）→ 组装 .app → Developer ID 签名 → 打包 DMG → 公证 → staple
#
# 凭据从 .env 读取（优先本仓库根目录，其次复用 ../cella/.env 的 Apple 账号配置）。
# 参考 cella/scripts/release.sh 的实现。
#
# 用法：
#   ./scripts/release.sh                 # 完整流程：构建 + 公证
#   ./scripts/release.sh --no-notarize   # 只产出签名后的 .app / .dmg（本地自测）
#   ./scripts/release.sh --use-keychain  # 用 notarytool 钥匙串档案提交公证
#   ./scripts/release.sh --no-timestamp  # 签名不请求时间戳（TSA 不可达时的应急）
#   ./scripts/release.sh --tsa-via-relay # Apple TSA 被代理拦截时，走本地中转直连真实 IP
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build-signed"
RELEASE_DIR="$ROOT/release"
APP_NAME="Perch"
PRODUCT="RecordTree"
APP="$BUILD_DIR/$APP_NAME.app"

NOTARIZE=1
USE_KEYCHAIN_PROFILE=0
NO_TIMESTAMP=0
TSA_RELAY=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize)   NOTARIZE=0 ;;
    --no-timestamp)  NO_TIMESTAMP=1 ;;
    --use-keychain)  USE_KEYCHAIN_PROFILE=1 ;;
    --tsa-via-relay) TSA_RELAY=1 ;;
    -h|--help)       sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

RELAY_PID=""
STAGE=""
cleanup() {
  if [[ -n "$RELAY_PID" ]]; then kill "$RELAY_PID" 2>/dev/null || true; fi
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then rm -rf "$STAGE"; fi
}
trap cleanup EXIT

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf '\033[31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 读取 .env
ENV_FILE="$ROOT/.env"
if [[ ! -f "$ENV_FILE" && -f "$ROOT/../cella/.env" ]]; then
  ENV_FILE="$ROOT/../cella/.env"
  info "复用 Cella 的公证配置：$ENV_FILE"
fi
[[ -f "$ENV_FILE" ]] || fail "找不到 .env（本仓库根目录或 ../cella/.env）"

# 只解析 KEY=VALUE，去掉行内注释与包裹的引号，不 eval（避免命令注入）。
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" != *=* ]] && continue
  key="${line%%=*}"
  val="${line#*=}"
  val="${val%%[[:space:]]#*}"
  val="${val%"${val##*[![:space:]]}"}"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  [[ -n "$key" ]] && export "$key=$val"
done < "$ENV_FILE"

: "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY 未在 .env 中设置}"

if (( NOTARIZE )); then
  if (( USE_KEYCHAIN_PROFILE )); then
    : "${NOTARY_KEYCHAIN_PROFILE:?使用 --use-keychain 时需设置 NOTARY_KEYCHAIN_PROFILE}"
    NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  else
    : "${APPLE_ID:?APPLE_ID 未在 .env 中设置}"
    : "${APPLE_PASSWORD:?APPLE_PASSWORD 未在 .env 中设置}"
    : "${APPLE_TEAM_ID:?APPLE_TEAM_ID 未在 .env 中设置}"
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
  fi
fi

TIMESTAMP_URL="${APPLE_TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"
if (( NO_TIMESTAMP )); then TIMESTAMP_URL="none"; fi

# Apple 的 TSA 是纯 HTTP（codesign 只接受 HTTP URL），若本机代理把它按域名拦掉
# （典型症状：curl 经代理访问返回 503、codesign 报 "The timestamp service is not
# available."），可以改成直连它的真实 IP + Host 头，这里用一个本地中转来做。
if (( TSA_RELAY )) && [[ "$TIMESTAMP_URL" != "none" ]]; then
  mkdir -p "$BUILD_DIR"
  TSA_IP="$(curl -s --max-time 10 -H 'accept: application/dns-json' \
      'https://1.1.1.1/dns-query?name=timestamp.apple.com&type=A' \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((a['data'] for a in d.get('Answer',[]) if a.get('type')==1),''))" 2>/dev/null || true)"
  [[ -n "$TSA_IP" ]] || TSA_IP="$(dig +short timestamp.apple.com A 2>/dev/null | tail -1 || true)"
  [[ -n "$TSA_IP" ]] || fail "无法解析 timestamp.apple.com 的真实 IP，不能启用中转。"
  info "时间戳中转：timestamp.apple.com -> ${TSA_IP}（绕过代理域名规则）"
  python3 "$ROOT/scripts/tsa_relay.py" 9911 "http://$TSA_IP/ts01" timestamp.apple.com \
    > "$BUILD_DIR/tsa-relay.log" 2>&1 &
  RELAY_PID=$!
  sleep 1
  kill -0 "$RELAY_PID" 2>/dev/null || fail "时间戳中转启动失败，见 $BUILD_DIR/tsa-relay.log"
  TIMESTAMP_URL="http://127.0.0.1:9911"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo 1.0)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist 2>/dev/null || echo 1)"
DMG="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"

bold "$APP_NAME $VERSION ($BUILD_NUMBER) 生产构建"
info "签名证书 : $APPLE_SIGNING_IDENTITY"
info "架构     : universal (arm64 + x86_64)"
if [[ "$TIMESTAMP_URL" == "none" ]]; then
  info "时间戳   : 已禁用（产物不可公证）"
else
  info "时间戳   : $TIMESTAMP_URL"
fi
info "公证     : $(( NOTARIZE )) $([[ $NOTARIZE == 1 ]] && echo '开启' || echo '跳过')"
echo

# ---------------------------------------------------------------- 证书检查
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$APPLE_SIGNING_IDENTITY"; then
  fail "钥匙串中找不到证书「${APPLE_SIGNING_IDENTITY}」。
  用以下命令查看可用证书，并把完整常用名写进 .env 的 APPLE_SIGNING_IDENTITY：
      security find-identity -v -p codesigning"
fi

# ---------------------------------------------------------------- 1/5 构建
bold "1/5 构建通用二进制"
swift build -c release --disable-sandbox \
  --arch arm64 --arch x86_64 \
  --product "$PRODUCT" 2>&1 | tail -5

BIN_PATH="$(swift build -c release --disable-sandbox --arch arm64 --arch x86_64 --show-bin-path)/$PRODUCT"
[[ -f "$BIN_PATH" ]] || fail "构建产物不存在：$BIN_PATH"
info "产物架构：$(lipo -archs "$BIN_PATH")"

# ---------------------------------------------------------------- 组装 .app
bold "组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$PRODUCT"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/ "$APP/Contents/Resources/"

ICON_SRC="assets/AppIcon.png"
if [[ -f "$ICON_SRC" ]]; then
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
    size="${spec%% *}"; name="${spec##* }"
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/$name" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$TMP_ROOT"
else
  echo "!! 缺少 ${ICON_SRC}，跳过图标" >&2
fi

# ---------------------------------------------------------------- 2/5 签名
bold "2/5 Developer ID 签名（硬化运行时 + 时间戳）"
# 时间戳服务偶发抖动，签名阶段失败即重试。
SIGN_ATTEMPTS=5
attempt=1
until codesign --force --options runtime \
        --timestamp="$TIMESTAMP_URL" \
        --sign "$APPLE_SIGNING_IDENTITY" "$APP"; do
  if (( attempt >= SIGN_ATTEMPTS )); then
    fail "签名失败：连续 ${SIGN_ATTEMPTS} 次未成功。
  若报错为「The timestamp service is not available.」，说明访问不到 ${TIMESTAMP_URL}。
  应急（产物不可公证）：./scripts/release.sh --no-notarize --no-timestamp"
  fi
  printf '  第 %d 次签名失败（时间戳服务抖动），重试…\n' "$attempt"
  attempt=$(( attempt + 1 ))
  sleep 3
done

codesign --verify --deep --strict --verbose=2 "$APP"
info "签名校验通过"
info "生效的 entitlements："
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | plutil -convert xml1 -o - - 2>/dev/null \
  | grep -E '<key>|<string>|<true/>|<false/>' \
  | sed 's/^[[:space:]]*/    /' || info "    （无）"

# ---------------------------------------------------------------- 3/5 DMG
bold "3/5 打包 DMG"
mkdir -p "$RELEASE_DIR"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
codesign --force --timestamp="$TIMESTAMP_URL" --sign "$APPLE_SIGNING_IDENTITY" "$DMG"
info "已生成 $DMG"

# ---------------------------------------------------------------- 4/5 公证
if (( NOTARIZE )); then
  bold "4/5 公证（上传给 Apple，可能需要几分钟）"
  # 网络抖动时 notarytool 会直接报 connectTimeout / connection lost，这里自动重试
  NOTARY_LOG="$BUILD_DIR/notary.log"
  attempt=1
  while true; do
    if ! xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait 2>&1 | tee "$NOTARY_LOG"; then
      : # 结果统一看日志，避免 pipefail 直接中断
    fi
    grep -q "status: Accepted" "$NOTARY_LOG" && break
    if grep -q "status: Invalid" "$NOTARY_LOG"; then
      fail "公证被拒绝，详情见 $NOTARY_LOG"
    fi
    (( attempt < 3 )) || fail "公证提交连续失败（通常是网络问题），详情见 $NOTARY_LOG"
    attempt=$((attempt + 1))
    info "公证提交失败，10 秒后重试（第 $attempt 次）"
    sleep 10
  done

  bold "5/5 staple 并验证"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type install --verbose=2 "$DMG"
  info "公证完成，可分发"
else
  bold "4/5 跳过公证（--no-notarize）"
  bold "5/5 跳过 staple"
  echo "  注意：未公证的 DMG 在其它 Mac 上首次打开会被 Gatekeeper 拦截。"
fi

echo
bold "完成"
info "$DMG"
