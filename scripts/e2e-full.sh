#!/usr/bin/env bash
# Mac + iPhone 통합 E2E: 실제 HostModel·RDCoreHost(Go 코어)와 실제 ClientModel·HostAPI를 가짜 tailnet(rdtestenv)으로 잇는다.
#
# 호스트 쪽 코어는 Packages/RDCore/RDCore.xcframework(scripts/build-core.sh의 산출물)다. 이 스크립트는 그것을 다시 빌드하지
# 않으므로, 링크가 없거나 core/ 소스보다 오래됐으면 바로 실패한다(고치는 방법: scripts/build-core.sh).
#
# 실행마다 따로인 작업 폴더(eyebuild e2e-full-run-<pid>-<시각>)를 쓰고 끝나면 지운다. 이 실행이 띄운 프로세스만 끝낸다.
# 시나리오 결과·로그는 eyebuild e2e-full-logs/<실행 id>에 남는다(최근 10개).
# 시험이 실패하거나 건너뛰어졌거나 시나리오 9개가 모두 PASS가 아니면 0이 아닌 값으로 끝난다.
#
# 사용: scripts/e2e-full.sh
# RD_E2E_FAIL_FAST=1이면 첫 실패 시나리오에서 멈춘다. RD_E2E_SWIFT_PURPOSE로 SwiftPM 빌드 폴더 이름을 바꾼다.
# RD_E2E_TOTAL_LIMIT_SECONDS로 전체 제한 시간(기본 600초)을 바꾼다.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EXPECTED_SCENARIOS=9
TOTAL_LIMIT_SECONDS="${RD_E2E_TOTAL_LIMIT_SECONDS:-600}"
STARTED=$(date +%s)
RUN_ID="$$-$STARTED"
PURPOSE="e2e-full-run-$RUN_ID"
SWIFT_PURPOSE="${RD_E2E_SWIFT_PURPOSE:-e2e-full}"
WORK="$(eyebuild -p remotedebug dir "$PURPOSE")"
LOG_ROOT="$(eyebuild -p remotedebug dir e2e-full-logs)"
LOGS="$LOG_ROOT/$RUN_ID"
mkdir -p "$LOGS"
TEST_PID=""
COMPLETED=0

log() { echo "e2e-full: $*" >&2; }

# 프로세스 트리 전체에 신호를 보낸다(swift test는 시험 프로세스를 새 프로세스 그룹으로 띄운다).
signal_tree() {
  local signal=$1 pid=$2 child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do signal_tree "$signal" "$child"; done
  kill "-$signal" "$pid" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  # bash 3.2는 set -u로 멈출 때 $?가 0일 수 있다. 끝까지 오지 못한 실행은 성공으로 끝내지 않는다.
  if [ "$COMPLETED" != "1" ] && [ "$rc" -eq 0 ]; then rc=1; fi
  if [ -n "$TEST_PID" ] && kill -0 "$TEST_PID" 2>/dev/null; then
    signal_tree TERM "$TEST_PID"
    for _ in $(seq 1 50); do kill -0 "$TEST_PID" 2>/dev/null || break; sleep 0.1; done
    signal_tree KILL "$TEST_PID"
  fi
  # 이 실행의 작업 폴더 안 바이너리로 뜬 프로세스만 끝낸다. 경로가 실행마다 다르다.
  pkill -f "$WORK/rdtestenv" 2>/dev/null || true
  for _ in $(seq 1 50); do pgrep -f "$WORK/rdtestenv" >/dev/null 2>&1 || break; sleep 0.1; done
  pkill -KILL -f "$WORK/rdtestenv" 2>/dev/null || true
  eyebuild -p remotedebug rm "$PURPOSE" >/dev/null 2>&1 || true
  # 최근 10개 실행의 로그만 남긴다.
  # shellcheck disable=SC2012
  ls -1t "$LOG_ROOT" | grep -v '^\.' | tail -n +11 | while read -r old; do rm -rf "${LOG_ROOT:?}/${old:?}"; done
  log "로그: $LOGS"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
  # 설치 웹 페이지 파일(core/internal/host/web)은 go:embed로 코어에 들어가므로 소스로 본다.
  newest="$(find "$ROOT/core" \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' -o -path '*/capi/include/*' \
            -o -path '*/internal/host/web/*' \) -type f -newer "$reference" -print 2>/dev/null | head -5)"
  if [ -n "$newest" ]; then
    log "RDCore.xcframework가 core/ 소스보다 오래됐습니다. 테스트할 호스트 코어가 지금 소스와 다릅니다."
    log "더 최근에 바뀐 파일(최대 5개):"
    printf '  %s\n' $newest >&2
    log "scripts/build-core.sh를 실행한 뒤 다시 돌리세요."
    exit 1
  fi
  log "호스트 코어: $target"
}
check_xcframework

# 1. rdtestenv.
scripts/go.sh build -o "$WORK/rdtestenv" ./cmd/rdtestenv

export RDTESTENV_BIN="$WORK/rdtestenv"
export RD_FIXTURES="$ROOT/Packages/RemoteDebugKit/Fixtures/apps"
export RD_E2E_TMPDIR="$WORK/tmp"
export RD_E2E_LOG_DIR="$LOGS"
mkdir -p "$RD_E2E_TMPDIR"

# 2. 시험 빌드. SwiftPM 빌드 폴더는 실행 사이에 재사용한다(증분 캐시).
eyebuild -p remotedebug swift "$SWIFT_PURPOSE" -- build --build-tests --package-path Packages/E2E >"$LOGS/build.log" 2>&1 \
  || { tail -40 "$LOGS/build.log" >&2; log "시험 빌드 실패"; exit 1; }

# 3. 시험 실행. 전체 제한 시간을 넘기면 프로세스 트리를 끝내고 실패한다.
remaining=$(( TOTAL_LIMIT_SECONDS - ( $(date +%s) - STARTED ) ))
(( remaining > 60 )) || { log "빌드에 시간을 다 써서 시험할 시간이 없습니다."; exit 1; }
export RD_E2E_HARD_LIMIT_SECONDS=$(( remaining - 15 ))
eyebuild -p remotedebug swift "$SWIFT_PURPOSE" -- test --skip-build --package-path Packages/E2E >"$LOGS/test.log" 2>&1 &
TEST_PID=$!
test_rc=0
timed_out=0
deadline=$(( STARTED + TOTAL_LIMIT_SECONDS - 5 ))
while kill -0 "$TEST_PID" 2>/dev/null; do
  if (( $(date +%s) >= deadline )); then
    timed_out=1
    log "제한 시간 안에 시험이 끝나지 않았습니다."
    signal_tree TERM "$TEST_PID"
    sleep 3
    signal_tree KILL "$TEST_PID"
    break
  fi
  sleep 1
done
wait "$TEST_PID" || test_rc=$?
TEST_PID=""
grep -E '^e2e-full:|^✘|recorded an issue' "$LOGS/test.log" >&2 || true
(( timed_out == 0 )) || exit 1

# 4. 판정. 종료 코드 0만 믿지 않는다(필터가 시험을 하나도 고르지 않거나 건너뛰어도 0일 수 있다).
fail=0
if [ "$test_rc" -ne 0 ]; then log "swift test 종료 코드: $test_rc"; fail=1; fi
if grep -Eq '(Test|Suite) .* skipped' "$LOGS/test.log"; then log "건너뛴 시험이 있습니다."; fail=1; fi
if ! grep -Eq 'Test run with 1 test.* passed' "$LOGS/test.log"; then log "시험 1개가 통과했다는 기록이 없습니다."; fail=1; fi
passed="$(grep -c '^PASS ' "$LOGS/results.txt" 2>/dev/null || true)"
if [ "${passed:-0}" -ne "$EXPECTED_SCENARIOS" ]; then
  log "PASS 시나리오 ${passed:-0}개, 필요한 수 ${EXPECTED_SCENARIOS}개."
  fail=1
fi
if pgrep -f "$WORK/rdtestenv" >/dev/null 2>&1; then log "시험이 하위 프로세스를 남겼습니다."; fail=1; fi
[ "$fail" -eq 0 ] || exit 1

log "시나리오 ${EXPECTED_SCENARIOS}개 통과 ($(( $(date +%s) - STARTED ))초)"
COMPLETED=1
