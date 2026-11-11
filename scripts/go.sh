#!/usr/bin/env bash
# core 모듈에서 go를 실행한다. 모든 캐시는 /Volumes/eyedisk/build 아래에 둔다(build-run 규칙).
# 사용: scripts/go.sh <go 인자...>        예) scripts/go.sh test ./...
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec eyebuild -p remotedebug run go-core -- bash -c '
  set -euo pipefail
  export GOCACHE="$EYEBUILD_DIR/gocache" GOMODCACHE="$EYEBUILD_DIR/gomod" GOPATH="$EYEBUILD_DIR/gopath"
  export GOFLAGS="-modcacherw" GOTOOLCHAIN=local
  mkdir -p "$GOCACHE" "$GOMODCACHE" "$GOPATH"
  cd "$1/core"
  shift
  exec go "$@"
' _ "$ROOT" "$@"
