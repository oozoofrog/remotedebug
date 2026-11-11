#!/bin/bash
# 정책 검사용 합성 .app 픽스처를 만든다(Fixtures/apps 아래, 저장소에 커밋).
# - iOS arm64 최소 Mach-O (clang + iPhoneOS SDK), ad hoc 서명(`codesign --sign -`)
# - 프로필: 합성 plist를 일회용 자체 서명 인증서로 `openssl smime -sign` 해 CMS로 감싼다.
# 작업 폴더는 eyebuild가 정한 /Volumes/eyedisk/build 아래이고 끝나면 지운다. 인증서·키는 저장소에 남지 않는다.
# 모든 UDID·팀 ID·이름은 가짜다.
# 새 픽스처는 작업 폴더에 모두 만든 뒤에만 기존 Fixtures/apps와 바꾼다. 중간에 실패하면 기존 픽스처는 그대로 남는다.
# 결정성: plist 내용(UUID·날짜 포함)과 파일 목록은 매번 같다. 프로필의 CMS 서명은 서명 속성 없이(-noattr) 만들지만
# 일회용 키를 매번 새로 만들므로 서명 바이트와 그에 따른 코드 서명 해시는 실행마다 다르다(테스트는 그 바이트에 의존하지 않는다).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/apps"
BASE="${EYEBUILD_DIR:-$(eyebuild -p remotedebug dir kit-fixtures)}"
WORK="$BASE/work.$$"
OUT="$WORK/apps"
mkdir -p "$OUT"
trap 'rm -rf "$WORK"' EXIT

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
FAKE_TEAM="ABCDE12345"
FAKE_UDID1="00008110-000A1B2C3D4E5F60"
FAKE_UDID2="00008110-000F9E8D7C6B5A40"

# ---- 실행 파일 ---------------------------------------------------------
cat > "$WORK/main.c" <<'C'
int main(void) { return 0; }
C
cat > "$WORK/lib.c" <<'C'
int rd_fixture_symbol(void) { return 1; }
C
LDFLAGS="-Wl,-dead_strip -Wl,-no_uuid -Os"
xcrun clang -isysroot "$IOS_SDK" -arch arm64 -miphoneos-version-min=26.0 $LDFLAGS -o "$WORK/ios-exec" "$WORK/main.c"
xcrun clang -isysroot "$IOS_SDK" -arch arm64 -miphoneos-version-min=26.0 $LDFLAGS -dynamiclib -o "$WORK/ios.dylib" "$WORK/lib.c"
xcrun clang -isysroot "$MAC_SDK" -arch arm64 -mmacosx-version-min=26.0 $LDFLAGS -o "$WORK/mac-exec" "$WORK/main.c"

# ---- 일회용 인증서 -----------------------------------------------------
OPENSSL="$(command -v openssl)"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=RemoteDebug Fixture Throwaway" -days 3650 >/dev/null 2>&1

# make_profile <kind> <out>   kind: dev | adhoc | enterprise | expired | appstore | apsprod | nodevgta
make_profile() {
    local kind="$1" out="$2" gta="true" devices="yes" all="" expiry="2099-01-01T00:00:00Z" aps="" uuidn
    case "$kind" in
        dev) uuidn=01 ;;
        adhoc) uuidn=02; gta="false" ;;
        enterprise) uuidn=03; gta="false"; devices=""; all="<key>ProvisionsAllDevices</key><true/>" ;;
        expired) uuidn=04; expiry="2020-01-01T00:00:00Z" ;;
        appstore) uuidn=05; gta="false"; devices="" ;;                                  # 규칙 5: app_store
        apsprod) uuidn=06; aps="<key>aps-environment</key><string>production</string>" ;;  # 규칙 5: aps_environment_production
        nodevgta) uuidn=07; devices="" ;;                                               # 규칙 5: no_provisioned_devices
        *) echo "알 수 없는 프로필 종류: $kind" >&2; exit 1 ;;
    esac
    if [ -n "$devices" ]; then
        devices="<key>ProvisionedDevices</key><array><string>$FAKE_UDID1</string><string>$FAKE_UDID2</string></array>"
    fi
    cat > "$WORK/profile.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Name</key><string>Fixture $kind Profile</string>
  <key>UUID</key><string>00000000-0000-4000-8000-0000000000$uuidn</string>
  <key>TeamIdentifier</key><array><string>$FAKE_TEAM</string></array>
  <key>TeamName</key><string>Fixture Team</string>
  <key>Platform</key><array><string>iOS</string></array>
  <key>Version</key><integer>1</integer>
  <key>CreationDate</key><date>2025-01-01T00:00:00Z</date>
  <key>ExpirationDate</key><date>$expiry</date>
  $devices
  $all
  <key>Entitlements</key>
  <dict>
    <key>application-identifier</key><string>$FAKE_TEAM.com.example.fixture.*</string>
    <key>com.apple.developer.team-identifier</key><string>$FAKE_TEAM</string>
    <key>get-task-allow</key><$gta/>
    $aps
  </dict>
</dict>
</plist>
PLIST
    plutil -lint "$WORK/profile.plist" >/dev/null
    "$OPENSSL" smime -sign -binary -nodetach -noattr -outform DER \
        -in "$WORK/profile.plist" -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" -out "$out"
}

# make_entitlements <gta|nogta|false> <out>
make_entitlements() {
    local mode="$1" out="$2" gta_line=""
    case "$mode" in
        gta) gta_line="<key>get-task-allow</key><true/>" ;;
        false) gta_line="<key>get-task-allow</key><false/>" ;;
        nogta) ;;
    esac
    cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>application-identifier</key><string>$FAKE_TEAM.com.example.fixture.app</string>
  <key>com.apple.developer.team-identifier</key><string>$FAKE_TEAM</string>
  $gta_line
</dict>
</plist>
PLIST
}

# make_app <dir> <Name> <platform:ios|mac> <profile:none|dev|adhoc|enterprise|expired|appstore|apsprod|nodevgta> <sign:none|gta|nogta|false> [dylib]
make_app() {
    local dir="$1" name="$2" platform="$3" profile="$4" sign="$5" dylib="${6:-}"
    local app="$OUT/$dir/$name.app"
    local bid="com.example.fixture.$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    mkdir -p "$app"
    if [ "$platform" = "ios" ]; then cp "$WORK/ios-exec" "$app/$name"; else cp "$WORK/mac-exec" "$app/$name"; fi
    local plat_name="iphoneos" plat_list="iPhoneOS" min_key="MinimumOSVersion" min_val="26.0"
    if [ "$platform" = "mac" ]; then plat_name="macosx"; plat_list="MacOSX"; min_key="LSMinimumSystemVersion"; fi
    cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bid</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>$min_key</key><string>$min_val</string>
  <key>DTPlatformName</key><string>$plat_name</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$plat_list</string></array>
</dict>
</plist>
PLIST
    plutil -lint "$app/Info.plist" >/dev/null
    if [ "$profile" != "none" ]; then make_profile "$profile" "$app/embedded.mobileprovision"; fi
    if [ -n "$dylib" ]; then
        cp "$WORK/ios.dylib" "$app/$name.debug.dylib"
        codesign --force --sign - "$app/$name.debug.dylib" >/dev/null 2>&1
    fi
    if [ "$sign" != "none" ]; then
        make_entitlements "$sign" "$WORK/ent.plist"
        codesign --force --sign - --entitlements "$WORK/ent.plist" "$app" >/dev/null 2>&1
    fi
}

# 구성 판정 변형(Release-iphoneos 폴더, 폴더 없음+사용자 확인)은 크기를 아끼려고 테스트가 AcceptedDev.app을 복사해 만든다.
D=Debug-iphoneos
make_app "$D" AcceptedDev      ios dev        gta
make_app "$D" Unsigned         ios dev        none
make_app "$D" AdhocNoGta       ios dev        nogta
make_app "$D" NoProfile        ios none       gta
make_app "$D" Enterprise       ios enterprise false
make_app "$D" AdHocDist        ios adhoc      false
make_app "$D" Expired          ios expired    gta
make_app "$D" MacApp           mac dev        gta
make_app "$D" AppStoreProfile  ios appstore   gta
make_app "$D" ApsProduction    ios apsprod    gta
make_app "$D" NoDevicesGta     ios nodevgta   gta
make_app loose DebugDylib      ios dev        gta dylib

# 모두 만든 뒤에만 바꾼다: 기존 → 백업, 새것 → 제자리, 백업 삭제.
for app in "$OUT"/*/*.app; do codesign --verify --strict "$app" >/dev/null 2>&1 || [ "$(basename "$app")" = Unsigned.app ] || { echo "서명 검증 실패: $app" >&2; exit 1; }; done
OLD="$WORK/apps.old"
if [ -d "$DEST" ]; then mv "$DEST" "$OLD"; fi
if ! mv "$OUT" "$DEST"; then
    [ -d "$OLD" ] && mv "$OLD" "$DEST"
    echo "픽스처 교체 실패(기존 픽스처를 되돌렸습니다)" >&2; exit 1
fi
rm -rf "$OLD"

echo "픽스처 생성 완료: $DEST"
du -sk "$DEST" | awk '{print "총 " $1 " KiB"}'
