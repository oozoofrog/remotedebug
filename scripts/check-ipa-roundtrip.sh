#!/bin/bash
# kit의 IPA 라운드트립 검증: 픽스처 .app → rdvalidate package → unzip -t → ditto 추출 → codesign --verify
# → rdvalidate inspect(.ipa) → 매니페스트 생성 → plutil -lint.
# 빌드·임시 파일은 모두 eyebuild 폴더(/Volumes/eyedisk/build/remotedebug/...) 아래에 두고 끝나면 지운다.
# 종료 코드: 모두 통과 0, 하나라도 실패 1.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="Packages/RemoteDebugKit"
PURPOSE="kit-roundtrip"
FAILS=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { # check <설명> <명령...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

cd "$ROOT" || exit 1
if ! eyebuild -p remotedebug swift kit -- build --package-path "$PKG" --product rdvalidate >/dev/null 2>&1; then
    echo "FAIL rdvalidate 빌드"; exit 1
fi
BIN="$(eyebuild -p remotedebug swift kit -- build --package-path "$PKG" --show-bin-path 2>/dev/null | tail -1)/rdvalidate"
[ -x "$BIN" ] || { echo "FAIL rdvalidate 실행 파일 없음"; exit 1; }
pass "rdvalidate 빌드"

TMP="$(eyebuild -p remotedebug dir "$PURPOSE")"
trap 'eyebuild -p remotedebug rm "$PURPOSE" >/dev/null 2>&1' EXIT
rm -rf "${TMP:?}"/* 2>/dev/null

roundtrip() { # roundtrip <fixture 상대 경로> <inspect 추가 옵션...>
    local rel="$1"; shift
    local app="$ROOT/$PKG/Fixtures/apps/$rel"
    local name; name="$(basename "$app" .app)"
    local dir="$TMP/$name"
    mkdir -p "$dir/work"
    local ipa="$dir/$name.ipa"

    if [ ! -d "$app" ]; then fail "$name: 픽스처 없음(Fixtures/make-fixtures.sh 실행)"; return; fi

    local out; out="$("$BIN" package "$app" --out "$ipa" 2>"$dir/package.err")"
    if [ $? -ne 0 ] || [ ! -s "$ipa" ]; then fail "$name: package"; return; fi
    pass "$name: package"

    local size sha
    size="$(printf '%s' "$out" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["size"])')"
    sha="$(printf '%s' "$out" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')"
    [ "$size" = "$(stat -f %z "$ipa")" ] && pass "$name: 보고된 크기 일치" || fail "$name: 보고된 크기 불일치"
    [ "$sha" = "$(shasum -a 256 "$ipa" | cut -d' ' -f1)" ] && pass "$name: 보고된 SHA-256 일치" || fail "$name: 보고된 SHA-256 불일치"

    check "$name: unzip -t" unzip -t "$ipa"

    mkdir -p "$dir/extract"
    if ditto -x -k "$ipa" "$dir/extract" 2>/dev/null; then pass "$name: ditto -x -k"; else fail "$name: ditto -x -k"; return; fi
    check "$name: codesign --verify --deep --strict" codesign --verify --deep --strict "$dir/extract/Payload/$name.app"

    "$BIN" inspect "$ipa" --work-dir "$dir/work" "$@" >"$dir/inspect.out" 2>&1
    local rc=$?
    [ $rc -eq 0 ] && pass "$name: rdvalidate inspect(.ipa) 수락" || { fail "$name: rdvalidate inspect(.ipa) 종료 코드 $rc"; sed 's/^/    /' "$dir/inspect.out"; }

    local bid; bid="$("$BIN" inspect "$app" --json "$@" 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("bundleId",""))')"
    "$BIN" manifest --bundle-id "${bid:-com.example.x}" --version 1.0 --title "$name" \
        --ipa-url "https://example.ts.net/i/TOKEN/app.ipa" --out "$dir/manifest.plist" 2>/dev/null
    check "$name: manifest plutil -lint" plutil -lint "$dir/manifest.plist"
}

roundtrip "Debug-iphoneos/AcceptedDev.app" --confirm-debug   # IPA에는 폴더 정보가 없어 사용자 확인이 필요
roundtrip "loose/DebugDylib.app"                              # *.debug.dylib 근거로 통과

# IPA 거부 확인(진짜 스스로 거부하는지): 확인 없이 검사하면 configuration_unverified
"$BIN" inspect "$TMP/AcceptedDev/AcceptedDev.ipa" --work-dir "$TMP/AcceptedDev/work" >"$TMP/neg.out" 2>&1
[ $? -eq 2 ] && grep -q configuration_unverified "$TMP/neg.out" && pass "IPA 구성 미확인 거부(종료 코드 2)" || fail "IPA 구성 미확인 거부"

echo "----"
if [ "$FAILS" -eq 0 ]; then echo "모두 통과"; exit 0; else echo "실패 ${FAILS}건"; exit 1; fi
