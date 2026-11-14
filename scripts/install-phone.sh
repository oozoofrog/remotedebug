#!/usr/bin/env bash
# 이 저장소의 iPhone 앱(RemoteDebug)을 자기 개발자 계정으로 빌드해 USB나 Wi-Fi로 연결한 iPhone에 설치한다.
# 필요한 것: Xcode(Apple 계정 로그인, Apple Development 인증서), XcodeGen(`brew install xcodegen`),
#           개발자 모드를 켠 iPhone. Go는 필요 없다(코어는 릴리스에서 내려받는다).
# 사용: scripts/install-phone.sh [--team <팀 ID>] [--device <UDID>] [--prefix <번들 ID 앞부분>]
#   팀·기기가 하나뿐이면 인자 없이 된다. 여러 개면 목록을 보여 주고 멈춘다.
# 빌드 산출물: RD_BUILD_ROOT(기본 ~/RemoteDebugBuild)/phone-install
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_URL="${RD_CORE_URL:-https://github.com/oozoofrog/remotedebug/releases/latest/download/RDCore.xcframework.zip}"
TEAM="" DEVICE="" PREFIX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: 모르는 인자: $1" >&2; exit 2 ;;
  esac
done
fail() { echo "error: $*" >&2; exit 1; }

command -v xcodebuild >/dev/null || fail "Xcode가 없습니다. App Store에서 Xcode를 설치하세요."
command -v xcodegen >/dev/null || fail "XcodeGen이 없습니다. 'brew install xcodegen'으로 설치하세요."

# 1. 코어(RDCore.xcframework). 없으면 릴리스에서 내려받는다.
CORE="$ROOT/Packages/RDCore/RDCore.xcframework"
if [ ! -e "$CORE/Info.plist" ]; then
  echo "==> 코어를 내려받습니다: $CORE_URL"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fL --progress-bar -o "$TMP/core.zip" "$CORE_URL" || fail "코어를 내려받지 못했습니다. 직접 빌드하려면 scripts/build-core.sh를 쓰세요(Go 필요)."
  ditto -x -k "$TMP/core.zip" "$TMP/out"
  [ -e "$TMP/out/RDCore.xcframework/Info.plist" ] || fail "내려받은 파일에 RDCore.xcframework가 없습니다."
  rm -rf "$CORE"
  mv "$TMP/out/RDCore.xcframework" "$CORE"
fi

# 2. 서명 팀. 인자 → Config/Signing.local.xcconfig → 키체인의 Apple Development 인증서.
LOCAL="$ROOT/Config/Signing.local.xcconfig"
config() { [ -e "$2" ] || return 0; sed -n "s/^$1 *= *//p" "$2" | tail -1 | tr -d '[:space:]'; }
REPO_TEAM="$(config DEVELOPMENT_TEAM "$LOCAL")"
[ -n "$TEAM" ] || TEAM="$REPO_TEAM"
if [ -z "$TEAM" ]; then
  TEAMS="$(security find-certificate -a -c "Apple Development" -p 2>/dev/null | python3 -c '
import subprocess, sys, re
seen = {}
for pem in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", sys.stdin.read(), re.S):
    subject = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253"], input=pem, capture_output=True, text=True).stdout
    team = re.search(r"OU=([A-Z0-9]{10})", subject)
    org = re.search(r"(?:^|,)O=([^,]+)", subject.replace("subject=", "").strip())
    if team: seen[team.group(1)] = org.group(1) if org else ""
for team, org in seen.items(): print(team, org)
')"
  COUNT="$(printf '%s' "$TEAMS" | grep -c . || true)"
  [ "$COUNT" -gt 0 ] || fail "Apple Development 인증서가 없습니다. Xcode > Settings > Accounts에서 로그인하고 Manage Certificates로 인증서를 만드세요."
  if [ "$COUNT" -gt 1 ]; then
    echo "서명 팀이 여러 개입니다. --team <팀 ID>로 고르세요:" >&2
    printf '%s\n' "$TEAMS" | sed 's/^/  /' >&2
    exit 1
  fi
  TEAM="${TEAMS%% *}"
fi

# 3. 번들 ID 앞부분. 저장소 설정의 팀이면 저장소 값, 다른 팀이면 그 팀만 쓰는 dev.<팀 ID 소문자>.
if [ -z "$PREFIX" ]; then
  PREFIX="$(config RD_BUNDLE_PREFIX "$LOCAL")"
  if [ -z "$PREFIX" ]; then
    if [ -n "$REPO_TEAM" ] && [ "$REPO_TEAM" = "$TEAM" ]; then
      PREFIX="$(config RD_BUNDLE_PREFIX "$ROOT/Config/Signing.xcconfig")"
    else
      PREFIX="dev.$(printf '%s' "$TEAM" | tr '[:upper:]' '[:lower:]')"
    fi
  fi
fi
# Xcode에서 다시 빌드할 때도 같은 값을 쓰도록 남긴다(저장소에 올라가지 않는 파일).
if [ ! -e "$LOCAL" ]; then
  printf 'DEVELOPMENT_TEAM = %s\nRD_BUNDLE_PREFIX = %s\n' "$TEAM" "$PREFIX" > "$LOCAL"
fi

# 4. iPhone.
if [ -z "$DEVICE" ]; then
  JSON="$(mktemp)"
  xcrun devicectl list devices --json-output "$JSON" --quiet >/dev/null 2>&1 || true
  PHONES="$(python3 - "$JSON" <<'PY'
import json, sys
try: devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception: devices = []
for d in devices:
    h, p, c = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    if h.get("platform") == "iOS" and h.get("reality") == "physical" and h.get("deviceType") == "iPhone" and h.get("udid") \
       and c.get("tunnelState") in ("connected", "disconnected"):
        print(h["udid"], p.get("name", "iPhone"), p.get("osVersionNumber", ""))
PY
)"
  rm -f "$JSON"
  COUNT="$(printf '%s' "$PHONES" | grep -c . || true)"
  [ "$COUNT" -gt 0 ] || fail "연결된 iPhone이 없습니다. USB로 연결해 잠금을 풀고 '이 컴퓨터를 신뢰'를 누른 뒤, 설정 > 개인정보 보호 및 보안 > 개발자 모드를 켜세요."
  if [ "$COUNT" -gt 1 ]; then
    echo "iPhone이 여러 대입니다. --device <UDID>로 고르세요:" >&2
    printf '%s\n' "$PHONES" | sed 's/^/  /' >&2
    exit 1
  fi
  DEVICE="${PHONES%% *}"
fi

# 5. 빌드 → 설치 → 실행.
OUT="${RD_BUILD_ROOT:-$HOME/RemoteDebugBuild}/phone-install"
mkdir -p "$OUT"
(cd "$ROOT" && xcodegen generate --spec project.yml >/dev/null)
ARGS=(-project "$ROOT/RemoteDebug.xcodeproj" -scheme RemoteDebugPhone -configuration Debug
  -destination "id=$DEVICE" -derivedDataPath "$OUT/DerivedData"
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration
  "DEVELOPMENT_TEAM=$TEAM" "RD_BUNDLE_PREFIX=$PREFIX")
echo "==> 빌드합니다(처음에는 몇 분 걸립니다). 기록: $OUT/build.log"
if ! xcodebuild "${ARGS[@]}" build > "$OUT/build.log" 2>&1; then
  grep -E "error:|requires a provisioning profile|No Account|No profiles" "$OUT/build.log" | sort -u | head -10 >&2
  fail "빌드하지 못했습니다. 전체 기록: $OUT/build.log"
fi
APP="$(xcodebuild "${ARGS[@]}" -showBuildSettings -json 2>/dev/null | python3 -c '
import json, sys
for entry in json.load(sys.stdin):
    s = entry.get("buildSettings", {})
    if s.get("WRAPPER_EXTENSION") == "app" and s.get("PRODUCT_TYPE") == "com.apple.product-type.application":
        print(s["BUILT_PRODUCTS_DIR"] + "/" + s["FULL_PRODUCT_NAME"]); break
')"
[ -d "$APP" ] || fail "빌드한 앱을 찾지 못했습니다. 기록: $OUT/build.log"
echo "==> 설치합니다: $APP"
xcrun devicectl device install app --device "$DEVICE" "$APP" > "$OUT/install.log" 2>&1 || { tail -5 "$OUT/install.log" >&2; fail "설치하지 못했습니다. iPhone 잠금을 풀고 다시 실행하세요."; }
xcrun devicectl device process launch --device "$DEVICE" "$PREFIX.RemoteDebugPhone" >/dev/null 2>&1 || true
echo "설치했습니다. iPhone에서 RemoteDebug를 열고 Mac 앱에서 'iPhone 페어링…'을 눌러 나오는 QR을 찍으세요."
echo "처음 실행에서 '신뢰하지 않는 개발자'가 나오면 설정 > 일반 > VPN 및 기기 관리에서 개발자를 신뢰하세요."
