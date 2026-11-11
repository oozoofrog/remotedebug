#!/bin/bash
# 실제 개발 서명 앱(Xcode DerivedData의 Debug-iphoneos)이 정책을 통과하고, 변형본은 정확한 사유로 거부되는지 확인한다.
# 수락된 첫 실제 앱으로 IPA 라운드트립도 확인한다: rdvalidate package → unzip -t → ditto -x -k →
# codesign --verify --deep --strict → 원본과 파일 트리 비교(경로·실행 비트·링크 대상·SHA-256) → rdvalidate inspect(.ipa).
# 원본은 읽기만 한다. 변형·IPA는 eyebuild 임시 폴더에만 만들고 끝나면 지운다.
# 출력은 번들 ID·수락/거부·사유 코드·개수뿐이다(UDID·팀 ID·프로필 이름 없음).
# 실제 빌드의 상태 변화는 킷 회귀로 보지 않는다: 프로필이 만료된 빌드(profile_expired)와 불완전한 번들은 SKIP.
# 종료 코드: 실제 빌드가 하나 이상 수락되고 실패가 없으면 0, 실패 1, 수락할 수 있는 실제 빌드가 없음 3.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="Packages/RemoteDebugKit"
PURPOSE="kit-realbuilds"
FAILS=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }

cd "$ROOT" || exit 1

shopt -s nullglob
APPS=()
for app in /Volumes/eyedisk/build/Xcode/DerivedData/*/Build/Products/Debug-iphoneos/*.app; do
    case "$app" in *-Runner.app) continue ;; esac
    APPS+=("$app")
done
if [ "${#APPS[@]}" -eq 0 ]; then
    echo "NO-REAL-BUILD 실제 개발 서명 빌드가 없습니다(/Volumes/eyedisk/build/Xcode/DerivedData/*/Build/Products/Debug-iphoneos/*.app). Xcode로 기기용 Debug 빌드를 먼저 만드세요."
    exit 3
fi

if ! eyebuild -p remotedebug swift kit -- build --package-path "$PKG" --product rdvalidate >/dev/null 2>&1; then
    echo "FAIL rdvalidate 빌드"; exit 1
fi
BIN="$(eyebuild -p remotedebug swift kit -- build --package-path "$PKG" --show-bin-path 2>/dev/null | tail -1)/rdvalidate"
[ -x "$BIN" ] || { echo "FAIL rdvalidate 실행 파일 없음"; exit 1; }

TMP="$(eyebuild -p remotedebug dir "$PURPOSE")"
trap 'eyebuild -p remotedebug rm "$PURPOSE" >/dev/null 2>&1' EXIT
rm -rf "${TMP:?}"/* 2>/dev/null

# summarize <json 파일> → "accepted|bundleId|코드,코드"
summarize() {
    python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("%s|%s|%s" % (str(d["accepted"]).lower(), d.get("bundleId", ""), ",".join(sorted(r["code"] for r in d["reasons"]))))
' "$1"
}

FIRST=""
ACCEPTED=0
SKIPPED=0
for app in "${APPS[@]}"; do
    out="$TMP/inspect.json"
    "$BIN" inspect "$app" --json >"$out" 2>"$TMP/inspect.err"
    rc=$?
    if [ $rc -eq 66 ]; then
        echo "SKIP $(basename "$app"): 완전한 앱 번들이 아닙니다(Info.plist·서명을 읽을 수 없음, 빌드 중간 산출물로 보임)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    IFS='|' read -r acc bid codes < <(summarize "$out")
    if [ "$rc" -eq 0 ] && [ "$acc" = "true" ]; then
        pass "$bid: accepted"
        ACCEPTED=$((ACCEPTED + 1))
        [ -z "$FIRST" ] && FIRST="$app"
    else
        case ",$codes," in
            *",profile_expired,"*)
                echo "SKIP $bid: 실제 빌드의 프로필이 만료됨 [$codes] (킷 회귀가 아님. Xcode로 다시 빌드하면 검사됩니다)"
                SKIPPED=$((SKIPPED + 1)) ;;
            *) fail "$bid: rejected [$codes] (수락을 기대함, 종료 코드 $rc)" ;;
        esac
    fi
done

if [ -z "$FIRST" ]; then
    echo "NO-REAL-BUILD 수락할 수 있는 실제 빌드가 없습니다(건너뜀 ${SKIPPED}건, 실패 ${FAILS}건). 변형·라운드트립 검사를 하지 못했습니다."
    echo "             Xcode로 기기용 Debug 빌드를 새로 만든 뒤 다시 실행하세요."
    exit 3
fi

# 변형 검사: <설명> <필수 코드> <허용되는 추가 코드(쉼표)> <변형 앱 경로>
expect_rejected() {
    local label="$1" required="$2" extra="$3" target="$4"
    local out="$TMP/mut.json"
    "$BIN" inspect "$target" --json >"$out" 2>/dev/null
    local rc=$?
    IFS='|' read -r acc bid codes < <(summarize "$out")
    if [ "$rc" -ne 2 ] || [ "$acc" != "false" ]; then
        fail "$label: 거부를 기대했으나 종료 코드 $rc, accepted=$acc [$codes]"; return
    fi
    local allowed=",$required,$extra,"
    local c bad=""
    for c in ${codes//,/ }; do
        case "$allowed" in *",$c,"*) ;; *) bad="$bad $c" ;; esac
    done
    case ",$codes," in *",$required,"*) ;; *) fail "$label: 필수 사유 $required 없음 [$codes]"; return ;; esac
    if [ -n "$bad" ]; then fail "$label: 예상 밖 사유 [$bad ] (전체 [$codes])"; else pass "$label: rejected [$codes]"; fi
}

NAME="$(basename "$FIRST")"
copy_app() { # copy_app <대상 폴더 부모> → 복사된 앱 경로를 출력
    mkdir -p "$1"
    ditto "$FIRST" "$1/$NAME" && echo "$1/$NAME"
}

# 1) embedded.mobileprovision 삭제 → no_provisioning_profile (봉인된 파일이 없어져 서명도 깨지므로 invalid_signature가 함께 나올 수 있다)
M1="$(copy_app "$TMP/m1/Debug-iphoneos")"
rm -f "$M1/embedded.mobileprovision"
expect_rejected "변형1(프로필 삭제)" no_provisioning_profile invalid_signature "$M1"

# 2) Release-iphoneos 폴더로 이동 → configuration_not_debug (서명은 그대로 유효해야 하므로 다른 사유는 허용하지 않는다)
M2="$(copy_app "$TMP/m2/Release-iphoneos")"
expect_rejected "변형2(Release-iphoneos 폴더)" configuration_not_debug "" "$M2"

# 3) 엔타이틀먼트 없이 ad hoc 재서명 → get_task_allow_missing
M3="$(copy_app "$TMP/m3/Debug-iphoneos")"
if codesign --force --sign - "$M3" >/dev/null 2>&1; then
    expect_rejected "변형3(ad hoc 재서명, 엔타이틀먼트 없음)" get_task_allow_missing "" "$M3"
else
    fail "변형3: codesign 재서명 실패"
fi

# 4) 실제 앱 IPA 라운드트립
RT="$TMP/roundtrip"
mkdir -p "$RT/extract" "$RT/work"
IPA="$RT/app.ipa"
if "$BIN" package "$FIRST" --out "$IPA" >"$RT/package.out" 2>"$RT/package.err" && [ -s "$IPA" ]; then
    pass "라운드트립: rdvalidate package"
    if unzip -tq "$IPA" >/dev/null 2>&1; then pass "라운드트립: unzip -t"; else fail "라운드트립: unzip -t"; fi
    if ditto -x -k "$IPA" "$RT/extract" 2>/dev/null; then
        pass "라운드트립: ditto -x -k"
        EXTRACTED="$RT/extract/Payload/$NAME"
        if codesign --verify --deep --strict "$EXTRACTED" >/dev/null 2>&1; then
            pass "라운드트립: codesign --verify --deep --strict(풀어 낸 앱)"
        else
            fail "라운드트립: codesign --verify --deep --strict(풀어 낸 앱)"
        fi
        # 파일 트리 비교: 경로·종류·실행 비트·링크 대상·SHA-256. 차이는 상대 경로만 최대 10개 보인다.
        if python3 -I - "$FIRST" "$EXTRACTED" >"$RT/tree.out" 2>&1 <<'PY'
import hashlib, os, stat, sys

def tree(root):
    out = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                out[rel] = ("link", os.readlink(path))
            elif stat.S_ISDIR(st.st_mode):
                out[rel] = ("dir",)
            elif stat.S_ISREG(st.st_mode):
                h = hashlib.sha256()
                with open(path, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                out[rel] = ("file", bool(st.st_mode & 0o111), h.hexdigest())
            else:
                out[rel] = ("other",)
    return out

a, b = tree(sys.argv[1]), tree(sys.argv[2])
diffs = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
files = sum(1 for v in a.values() if v[0] == "file")
links = sum(1 for v in a.values() if v[0] == "link")
execs = sum(1 for v in a.values() if v[0] == "file" and v[1])
print("항목 %d개(파일 %d, 실행 파일 %d, 링크 %d, 폴더 %d), 차이 %d개" % (len(a), files, execs, links, len(a) - files - links, len(diffs)))
for k in diffs[:10]:
    print("  차이: %s (원본 %s / 추출 %s)" % (k, a.get(k, ("없음",))[0], b.get(k, ("없음",))[0]))
sys.exit(1 if diffs or not a else 0)
PY
        then
            pass "라운드트립: 파일 트리 일치 — $(head -1 "$RT/tree.out")"
        else
            fail "라운드트립: 파일 트리 불일치"; sed 's/^/    /' "$RT/tree.out"
        fi
    else
        fail "라운드트립: ditto -x -k"
    fi
    "$BIN" inspect "$IPA" --work-dir "$RT/work" --confirm-debug >"$RT/inspect.out" 2>&1
    rc=$?
    if [ $rc -eq 0 ]; then pass "라운드트립: rdvalidate inspect(.ipa) 수락"; else fail "라운드트립: rdvalidate inspect(.ipa) 종료 코드 $rc"; grep -E '^\s+- ' "$RT/inspect.out" | sed 's/^/    /'; fi
    if [ -z "$(ls -A "$RT/work")" ]; then pass "라운드트립: 검사용 임시 폴더 정리"; else fail "라운드트립: 검사용 임시 폴더가 남음"; fi
else
    fail "라운드트립: rdvalidate package"; sed 's/^/    /' "$RT/package.err"
fi

echo "----"
echo "수락 ${ACCEPTED}건, 건너뜀 ${SKIPPED}건, 실패 ${FAILS}건"
[ "$FAILS" -eq 0 ] && exit 0 || exit 1
