#!/bin/sh
# Swiftail 로그에서 전송 통계와 경로 줄만 골라, 문서에 옮겨도 되게 가려서 낸다.
#
# 쓰는 법: scripts/swiftail-log-lines.sh [-p 프로세스이름] 파일...
#   파일: `log stream --level info --predicate 'subsystem == "Swiftail"'`을 받은 것, 또는 기기 로그(jsonl).
#   -p:   그 프로세스의 줄만(같은 Mac에서 돈 시험 실행의 줄을 뺄 때. 예: -p rd-swiftail-host).
#
# 고르는 줄: `연결이 끝남:`, `피어 N 경로:`(Swiftail 151942f부터)와 예전 꼴 `피어 경로:`.
# 가리는 것: 기기 로그의 기기·노드 이름, tailnet 이름, FQDN, tailnet 주소(100.64.0.0/10, fd7a:…), 그 밖의 IPv4·IPv6 주소, 키, 메일, 로그인 주소.
set -eu

process=""
if [ "${1:-}" = "-p" ]; then
  process="$2"
  shift 2
fi
[ $# -gt 0 ] || { echo "쓰는 법: $0 [-p 프로세스이름] 파일..." >&2; exit 2; }

grep -hE "연결이 끝남:|피어( [0-9]+)? 경로:" "$@" \
  | { if [ -n "$process" ]; then grep -F " $process["; else cat; fi; } \
  | sed -E \
    -e 's/"(deviceId|deviceName|nodeName)":"[^"]*"/"\1":"…"/g' \
    -e 's#https?://login\.[^ "]+#<login-url>#g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<mail>/g' \
    -e 's/(nodekey|discokey|tlpub|mkey|privkey):[0-9a-f]+/\1:…/g' \
    -e 's/[A-Za-z0-9-]+\.tail[0-9a-f]{4,}\.ts\.net\.?/<fqdn>/g' \
    -e 's/tail[0-9a-f]{4,}/<tailnet>/g' \
    -e 's/100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}/<ip>/g' \
    -e 's/fd7a:[0-9a-f:]+/<ip6>/g' \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<addr>/g' \
    -e 's/\[?([0-9a-f]{1,4}:){3,7}[0-9a-f:]*\]?/<addr6>/g'
