#!/usr/bin/env bash
# Mac 호스트 E2E: 실제 Go 코어(RDCoreHost) + 가짜 tailnet(rdtestenv).
#
# 1단계(항상): rdtestenv를 새로 빌드하고 Packages/MacHost의 E2E 테스트를 돌린다.
# 2단계(RD_E2E_APP=1): 샌드박스 앱(RemoteDebug.app)을 빌드해 -RDControlURL/-RDNodeId8/-RDStartSharing으로 띄우고,
#   가짜 iPhone이 403 not_paired를 받는지, 앱을 종료(SIGTERM = 메뉴의 종료와 같은 경로, 두 번 보낸다)하면 20초 안에 종료 코드 0으로
#   끝나는지 확인한다. 코어는 앱에 정적으로 링크돼 프로세스가 끝나면 서빙도 끝난다. 리스너가 닫히는 순서는 1단계 E2E가 본다.
#   앱은 컨테이너 안 Application Support/RemoteDebug-e2e-<실행 id>를 쓰고, 끝나면 그 폴더를 지운다(개발자의 실제 상태는 건드리지 않는다).
#
# 호스트 쪽 코어는 Packages/RDCore/RDCore.xcframework(scripts/build-core.sh의 산출물)다. 이 스크립트는 그것을 다시 빌드하지
# 않으므로, 링크가 없거나 core/ 소스보다 오래됐으면 바로 실패한다(고치는 방법: scripts/build-core.sh).
#
# 실행마다 따로인 작업 폴더(eyebuild e2e-mac-<pid>-<시각>)를 쓰고, 이 실행이 띄운 프로세스만 끝낸다. 동시에 돌려도 서로 지우지 않는다.
# 사용: scripts/e2e-mac.sh            RD_E2E_APP=1 scripts/e2e-mac.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_ID="$$-$(date +%s)"
PURPOSE="e2e-mac-$RUN_ID"
APP_PURPOSE="e2e-mac-app-$RUN_ID"
WORK="$(eyebuild -p remotedebug dir "$PURPOSE")"
BUNDLE_ID="com.oozoofrog.app.RemoteDebugMac"
APP_STATE_NAME="RemoteDebug-e2e-$(printf '%s' "$RUN_ID" | tr -cd 'A-Za-z0-9-')"
CONTAINER_SUPPORT="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support"
CHILD_PIDS=()
APP_PID=""

log() { echo "e2e-mac: $*" >&2; }

cleanup() {
  local rc=$?
  for pid in "${CHILD_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  # 이 실행의 작업 폴더 안 바이너리로 뜬 프로세스만(E2E 테스트가 띄운 control·peer) 끝낸다. 경로가 실행마다 다르다.
  pkill -f "$WORK/rdtestenv" 2>/dev/null || true
  # 앱이 끝난 뒤에 지운다(종료 중인 앱이 저장 폴더를 다시 만들 수 있다). 15초 안에 끝나지 않으면 강제로 끝낸다.
  if [ -n "$APP_PID" ]; then
    for _ in $(seq 1 150); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$APP_PID" 2>/dev/null; then
      kill -KILL "$APP_PID" 2>/dev/null || true
      wait "$APP_PID" 2>/dev/null || true
    fi
  fi
  if [ -n "${APP_STATE_NAME:-}" ] && [ -d "$CONTAINER_SUPPORT/$APP_STATE_NAME" ]; then
    rm -rf "${CONTAINER_SUPPORT:?}/${APP_STATE_NAME:?}"
  fi
  eyebuild -p remotedebug rm "$PURPOSE" >/dev/null 2>&1 || true
  eyebuild -p remotedebug rm "$APP_PURPOSE" >/dev/null 2>&1 || true
  exit $rc
}
trap cleanup EXIT

# 0. 호스트 코어(xcframework)가 지금 core/ 소스로 만든 것인지 확인한다.
check_xcframework() {
  local link="$ROOT/Packages/RDCore/RDCore.xcframework" target newest reference
  if [ ! -L "$link" ] && [ ! -d "$link" ]; then
    log "RDCore.xcframework가 없습니다($link). scripts/build-core.sh로 만드세요."
    exit 1
  fi
  target="$(cd "$link" 2>/dev/null && pwd -P)" || {
    log "RDCore.xcframework 링크가 가리키는 폴더가 없습니다($(readlink "$link")). scripts/build-core.sh로 다시 만드세요."
    exit 1
  }
  [ -f "$target/Info.plist" ] || { log "${target}에 Info.plist가 없습니다. scripts/build-core.sh로 다시 만드세요."; exit 1; }
  # 기준은 가장 먼저 만들어지는 산출물이다. 헤더는 슬라이스를 컴파일하기 전에 복사되므로 빌드 도중에 고친 소스도 잡는다.
  reference="$target/macos-arm64/Headers/rdcore.h"
  [ -f "$reference" ] || reference="$target/Info.plist"
  # 지우거나 이름만 바꾼 소스는 시각이 남지 않으므로 소스 목록도 비교한다. 목록은 이 프레임워크를 처음 확인할 때 옆에 남긴다.
  # 한계: 첫 확인 전에 일어난 삭제·이름 변경, 시각을 보존한 복사, build-core.sh의 TAGS 변경은 잡지 못한다.
  local manifest="$target.sources" sources
  # 설치 웹 페이지 파일(core/internal/host/web)은 go:embed로 코어에 들어가므로 소스로 본다.
  sources="$(cd "$ROOT/core" && find . \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' -o -path '*/capi/include/*' \
            -o -path '*/internal/host/web/*' \) -type f -print | LC_ALL=C sort)"
  newest="$(find "$ROOT/core" \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' -o -path '*/capi/include/*' \
            -o -path '*/internal/host/web/*' \) -type f -newer "$reference" -print 2>/dev/null | head -5)"
  if [ -z "$newest" ] && [ -f "$manifest" ] && [ "$sources" != "$(cat "$manifest")" ]; then
    log "RDCore.xcframework를 만든 뒤 core/ 소스 파일이 지워졌거나 이름이 바뀌었습니다. 테스트할 호스트 코어가 지금 소스와 다릅니다."
    diff <(cat "$manifest") <(printf '%s\n' "$sources") | grep '^[<>]' | head -5 >&2 || true
    log "scripts/build-core.sh를 실행한 뒤 다시 돌리세요."
    exit 1
  fi
  if [ -n "$newest" ]; then
    log "RDCore.xcframework가 core/ 소스보다 오래됐습니다. 테스트할 호스트 코어가 지금 소스와 다릅니다."
    log "더 최근에 바뀐 파일(최대 5개):"
    printf '  %s\n' $newest >&2
    log "scripts/build-core.sh를 실행한 뒤 다시 돌리세요."
    exit 1
  fi
  if [ ! -f "$manifest" ]; then
    printf '%s\n' "$sources" >"$manifest.$$"
    mv -f "$manifest.$$" "$manifest"
  fi
  # build-core.sh가 지운 프레임워크의 목록은 남기지 않는다.
  for old in "$(dirname "$target")"/*.xcframework.sources; do
    [ -d "${old%.sources}" ] || rm -f "$old"
  done
  log "호스트 코어: $target"
}
check_xcframework

# 1. rdtestenv. 다른 작업이 core/를 고치는 중이면 잠시 실패할 수 있다: 30초 간격으로 최대 5분 다시 시도한다.
deadline=$(( $(date +%s) + 5 * 60 ))
until scripts/go.sh build -o "$WORK/rdtestenv" ./cmd/rdtestenv; do
  if (( $(date +%s) + 30 > deadline )); then
    log "rdtestenv를 5분 안에 빌드하지 못했습니다."
    exit 1
  fi
  log "rdtestenv 빌드 실패, 30초 뒤 다시 시도합니다."
  sleep 30
done

export RDTESTENV_BIN="$WORK/rdtestenv"
export RD_FIXTURES="$ROOT/Packages/RemoteDebugKit/Fixtures/apps"
export RD_E2E_TMPDIR="$WORK/tmp"
mkdir -p "$RD_E2E_TMPDIR"

# SwiftPM 빌드 폴더(mac-host)는 패키지 테스트와 같이 쓴다(증분 캐시). 동시 실행은 SwiftPM이 잠금으로 줄을 세운다.
eyebuild -p remotedebug swift mac-host -- test --package-path Packages/MacHost --filter E2E

[ "${RD_E2E_APP:-0}" = "1" ] || exit 0

# 2. 샌드박스 앱 스모크.
log "샌드박스 앱을 빌드합니다."
APP_DIR="$(eyebuild -p remotedebug dir "$APP_PURPOSE")"
eyebuild -p remotedebug xcodebuild "$APP_PURPOSE" -- -project RemoteDebug.xcodeproj -scheme RemoteDebugMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build >"$WORK/app-build.log" 2>&1 \
  || { tail -40 "$WORK/app-build.log" >&2; log "앱 빌드 실패"; exit 1; }
APP="$APP_DIR/DerivedData/Build/Products/Debug/RemoteDebug.app"
[ -x "$APP/Contents/MacOS/RemoteDebug" ] || { log "빌드한 앱이 없습니다: $APP"; exit 1; }
codesign -d --entitlements - --xml "$APP" >"$WORK/entitlements.plist" 2>/dev/null \
  || { log "앱의 권한을 읽지 못했습니다."; exit 1; }
entitlement() { /usr/libexec/PlistBuddy -c "Print :$1" "$WORK/entitlements.plist" 2>/dev/null; }
[ "$(entitlement com.apple.security.app-sandbox)" = "true" ] || { log "앱에 샌드박스 권한이 없습니다."; exit 1; }
[ "$(entitlement com.apple.security.files.user-selected.read-only)" = "true" ] \
  || { log "앱에 user-selected.read-only 권한이 없습니다."; exit 1; }
if entitlement com.apple.security.files.user-selected.read-write >/dev/null; then
  log "앱에 user-selected.read-write 권한이 있습니다. 고른 폴더는 읽기만 해야 합니다."
  exit 1
fi

"$WORK/rdtestenv" control >"$WORK/control.out" 2>"$WORK/control.err" &
CHILD_PIDS+=($!)
CONTROL=""
for _ in $(seq 1 300); do
  CONTROL="$(head -1 "$WORK/control.out" 2>/dev/null | sed -n 's/.*"controlURL":"\([^"]*\)".*/\1/p')"
  [ -n "$CONTROL" ] && break
  sleep 0.1
done
[ -n "$CONTROL" ] || { cat "$WORK/control.err" >&2; log "가짜 제어 서버가 뜨지 않았습니다."; exit 1; }

ID8="$(printf '%08x' $(( (RANDOM << 16) | RANDOM )))"
log "앱 실행: rd-mac-$ID8, 저장 폴더 $APP_STATE_NAME, 제어 서버 $CONTROL"
"$APP/Contents/MacOS/RemoteDebug" -RDControlURL "$CONTROL" -RDNodeId8 "$ID8" -RDStartSharing YES \
  -RDStateRootName "$APP_STATE_NAME" -ApplePersistenceIgnoreState YES >"$WORK/app.out" 2>"$WORK/app.err" &
APP_PID=$!
CHILD_PIDS+=($APP_PID)

peer() {  # peer <상태 폴더 이름> <동작> <인자...>
  local dir="$WORK/peer-$1"; shift
  "$WORK/rdtestenv" peer --control "$CONTROL" --state-dir "$dir" --hostname rd-phone-smoke "$@"
}

# 앱이 tailnet에 오르면 페어링하지 않은 iPhone은 403 not_paired를 받는다. 호스트 이름(rd-mac-<id8>)은 MagicDNS로 찾는다.
HOST_URL="http://rd-mac-$ID8:443"
result=""
up_deadline=$(( $(date +%s) + 5 * 60 ))
while (( $(date +%s) < up_deadline )); do
  kill -0 "$APP_PID" 2>/dev/null || { cat "$WORK/app.err" >&2; log "앱이 일찍 끝났습니다."; exit 1; }
  result="$(peer a builds --host "$HOST_URL" 2>>"$WORK/peer.err" | tail -1 || true)"
  case "$result" in *'"status":403'*) break;; esac
  sleep 2
done
case "$result" in
  *'"status":403'*'"not_paired"'*|*'"not_paired"'*'"status":403'*) log "페어링하지 않은 기기: $result";;
  *) log "403 not_paired를 받지 못했습니다: $result"; tail -20 "$WORK/peer.err" >&2; exit 1;;
esac
[ -d "$CONTAINER_SUPPORT/$APP_STATE_NAME/state" ] || { log "앱이 컨테이너 안 저장 폴더를 쓰지 않았습니다."; exit 1; }

# 종료: SIGTERM은 메뉴의 종료처럼 공유를 멈춘 뒤 끝난다. 정리 중에 온 두 번째 신호는 그 정리를 끊지 않는다.
# 스모크가 확인하는 것: 앱이 10초 강제 종료(종료 코드 1) 전에 종료 코드 0으로 끝난다. 코어는 앱에 정적으로 링크돼 있어
# 프로세스가 사라지면 서빙도 사라지므로, 프로세스가 끝난 뒤의 tailnet 탐침은 앱 결함으로 실패할 수 없어 하지 않는다.
kill -TERM "$APP_PID"
sleep 0.2
kill -TERM "$APP_PID" 2>/dev/null || true
for _ in $(seq 1 200); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$APP_PID" 2>/dev/null; then log "앱이 20초 안에 끝나지 않았습니다."; exit 1; fi
# 정상 종료 경로(공유 중지 뒤 종료)는 0으로 끝난다. 앱의 10초 강제 종료는 1이다.
app_rc=0
wait "$APP_PID" 2>/dev/null || app_rc=$?
[ "$app_rc" -eq 0 ] || { log "앱이 정상 종료 경로로 끝나지 않았습니다(종료 코드 $app_rc)."; exit 1; }
APP_PID=""

log "샌드박스 앱 스모크 통과"
