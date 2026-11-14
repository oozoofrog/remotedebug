#!/usr/bin/env bash
# Mac 앱을 Developer ID로 서명하고 Apple 공증을 받아 배포용 zip을 만든다.
# 필요한 것: Xcode에 로그인한 Apple 개발자 계정(Developer ID 인증서를 만들 수 있는 계정 소유자),
#           Config/Signing.local.xcconfig의 DEVELOPMENT_TEAM.
# 사용: scripts/release-mac.sh            서명 → 공증 요청 → 공증된 앱 받기 → zip
#       scripts/release-mac.sh --no-notarize   서명까지만(공증 없이 확인용)
# 결과: `eyebuild dir mac-devid`/RemoteDebug-<버전>-<빌드>.zip, RDCore.xcframework.zip
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$ROOT/Config/Signing.local.xcconfig" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$TEAM" ]; then
  echo "error: Config/Signing.local.xcconfig에 DEVELOPMENT_TEAM이 없습니다." >&2
  exit 1
fi

OUT="$(eyebuild -p remotedebug dir mac-devid)"
ARCHIVE="$OUT/RemoteDebug.xcarchive"
EXPORT="$OUT/export"
rm -rf "$ARCHIVE" "$EXPORT" "$OUT"/*.plist

# RD_SOURCE_ROOT를 비워 Info.plist에 이 Mac의 저장소 경로를 넣지 않는다.
eyebuild -p remotedebug xcodebuild mac-devid -- -project "$ROOT/RemoteDebug.xcodeproj" -scheme RemoteDebugMac \
  -configuration Release -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  CODE_SIGN_IDENTITY="Apple Development" RD_SOURCE_ROOT= archive

options() { # <destination>
  cat > "$OUT/export-$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>$1</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
PLIST
  echo "$OUT/export-$1.plist"
}

if [ "$NOTARIZE" = 0 ]; then
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$(options export)" -allowProvisioningUpdates
else
  # Xcode 계정으로 공증을 요청하고, 끝날 때까지 공증된 앱 받기를 되풀이한다(보통 몇 분).
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$(options upload)" -allowProvisioningUpdates
  for _ in $(seq 1 60); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$EXPORT" 2>"$OUT/notarize.log"; then break; fi
    sleep 30
  done
  [ -d "$EXPORT/RemoteDebug.app" ] || { echo "error: 공증된 앱을 받지 못했습니다. $OUT/notarize.log" >&2; exit 1; }
  xcrun stapler validate "$EXPORT/RemoteDebug.app"
  spctl --assess --type execute -v "$EXPORT/RemoteDebug.app"
fi

APP="$EXPORT/RemoteDebug.app"
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
ZIP="$OUT/RemoteDebug-$VERSION-$BUILD.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$ZIP"

# scripts/install-phone.sh가 내려받는 코어. 릴리스에 RDCore.xcframework.zip이라는 이름으로 함께 올린다.
rm -rf "$OUT/RDCore.xcframework" "$OUT/RDCore.xcframework.zip"
cp -R "$(cd "$ROOT/Packages/RDCore/RDCore.xcframework" && pwd -P)" "$OUT/RDCore.xcframework"
(cd "$OUT" && ditto -c -k --keepParent RDCore.xcframework RDCore.xcframework.zip && rm -rf RDCore.xcframework)
echo "$OUT/RDCore.xcframework.zip"
