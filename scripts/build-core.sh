#!/usr/bin/env bash
# Go 코어(core/capi)를 c-archive로 빌드해 RDCore.xcframework를 만든다.
# 슬라이스: macos-arm64, ios-arm64, ios-arm64-simulator (최소 macOS 26.0 / iOS 26.0).
# 산출물은 `eyebuild -p remotedebug dir core-xcframework` 아래에 둔다. 새 임시 폴더에서 빌드하고
# 세 슬라이스의 아키텍처·플랫폼을 확인한 뒤에만 Packages/RDCore/RDCore.xcframework 심볼릭 링크를
# 새 결과로 원자적으로 바꾼다(rename). 실패하면 임시 폴더를 지우고 이전 링크와 결과를 그대로 둔다.
# Package.swift도 다시 쓴다.
# 사용: scripts/build-core.sh
# 시험: RD_BUILD_FAIL_SLICE=<슬라이스 이름>이면 그 슬라이스 빌드를 일부러 실패시킨다.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(eyebuild -p remotedebug dir core-xcframework)"
MIN_OS=26.0

# tailscale.com v1.104.6 기능 태그: 아래를 제외한 모든 선택 기능을 뺀다.
#   유지: netstack(tsnet), acme+serve(ListenTLS 인증서; acme가 serve에 의존), dns(MagicDNS 이름),
#         udptransport+nattraversal(직접 연결), ipnbus(tsnet.Up), health, tailnetlock(잠긴 tailnet),
#         bakedroots(제어 서버 TLS 루트), useproxy(시스템 프록시), clientmetrics
#   터널 모드(docs/tunnel.md)도 같은 목록으로 빌드한다: netstack(100.100.100.100 MagicDNS 응답),
#         dns(설정 싱크의 ReconfigureVPN 시점)이 필요하다. acme·serve·ipnbus·clientmetrics는 같은
#         아카이브의 tsnet이 쓰므로 뺄 수 없다.
# 목록은 `go run tailscale.com/cmd/featuretags --min --add=<유지 목록>`으로 만들었다.
TAGS="ts_omit_ace,ts_omit_advertiseexitnode,ts_omit_advertiseroutes,ts_omit_androidbin,ts_omit_androiddns,\
ts_omit_appconnectors,ts_omit_aws,ts_omit_bird,ts_omit_c2n,ts_omit_cachenetmap,ts_omit_captiveportal,ts_omit_capture,\
ts_omit_cliconndiag,ts_omit_clientupdate,ts_omit_cloud,ts_omit_colorable,ts_omit_completion,ts_omit_completion_scripts,\
ts_omit_conn25,ts_omit_connreject,ts_omit_dbus,ts_omit_debug,ts_omit_debugeventbus,ts_omit_debugportmapper,\
ts_omit_desktop_sessions,ts_omit_dnsresolvecache,ts_omit_doctor,ts_omit_drive,ts_omit_favorites,ts_omit_flashappliance,\
ts_omit_gro,ts_omit_hujsonconf,ts_omit_identityfederation,ts_omit_iptables,ts_omit_kube,ts_omit_linkspeed,\
ts_omit_linuxdnsfight,ts_omit_listenrawdisco,ts_omit_logtail,ts_omit_netlog,ts_omit_networkmanager,ts_omit_oauthkey,\
ts_omit_osrouter,ts_omit_outboundproxy,ts_omit_peerapiclient,ts_omit_peerapiserver,ts_omit_portlist,ts_omit_portmapper,\
ts_omit_posture,ts_omit_qrcodes,ts_omit_relayserver,ts_omit_remoteconfig,ts_omit_resolved,ts_omit_routecheck,\
ts_omit_runtimemetrics,ts_omit_sdnotify,ts_omit_serviceclientprefs,ts_omit_ssh,ts_omit_synology,ts_omit_syslog,\
ts_omit_syspolicy,ts_omit_systray,ts_omit_taildrop,ts_omit_tap,ts_omit_tpm,ts_omit_tundevstats,\
ts_omit_unixsocketidentity,ts_omit_useexitnode,ts_omit_usermetrics,ts_omit_useroutes,ts_omit_wakeonlan,\
ts_omit_webbrowser,ts_omit_webclient"

LINK="$ROOT/Packages/RDCore/RDCore.xcframework"
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  echo "error: $LINK exists and is not a symlink" >&2
  exit 1
fi

rm -rf "$OUT"/build.* # 중단된 이전 실행의 임시 폴더
STAGE="$(mktemp -d "$OUT/build.XXXXXX")"
cleanup() {
  local rc=$?
  rm -rf "$STAGE"
  if [ $rc -ne 0 ]; then
    echo "error: build failed; $LINK still points to $(readlink "$LINK" 2>/dev/null || echo '(nothing)')" >&2
  fi
}
trap cleanup EXIT

mkdir -p "$STAGE/include"
cp "$ROOT/core/capi/include/rdcore.h" "$ROOT/core/capi/include/module.modulemap" "$STAGE/include/"

# build_slice <이름> <GOOS> <SDK> <clang target>
build_slice() {
  local name=$1 goos=$2 sdk=$3 target=$4
  local sdkpath cc flags
  sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" -f clang)"
  flags="-isysroot $sdkpath -target $target"
  mkdir -p "$STAGE/slices/$name"
  echo "==> $name ($target)"
  if [ "${RD_BUILD_FAIL_SLICE:-}" = "$name" ]; then
    echo "error: simulated build failure for $name (RD_BUILD_FAIL_SLICE)" >&2
    return 1
  fi
  GOOS="$goos" GOARCH=arm64 CGO_ENABLED=1 CC="$cc" \
    CGO_CFLAGS="$flags -O2" CGO_LDFLAGS="$flags" \
    "$ROOT/scripts/go.sh" build -trimpath -buildmode=c-archive -tags "$TAGS" -ldflags "-s -w" \
    -o "$STAGE/slices/$name/libRDCore.a" ./capi
  rm -f "$STAGE/slices/$name/libRDCore.h" # Go가 만든 헤더 대신 손으로 쓴 rdcore.h를 쓴다.
}

build_slice macos-arm64         darwin macosx          "arm64-apple-macos$MIN_OS"
build_slice ios-arm64           ios    iphoneos        "arm64-apple-ios$MIN_OS"
build_slice ios-arm64-simulator ios    iphonesimulator "arm64-apple-ios$MIN_OS-simulator"

xcodebuild -create-xcframework \
  -library "$STAGE/slices/macos-arm64/libRDCore.a" -headers "$STAGE/include" \
  -library "$STAGE/slices/ios-arm64/libRDCore.a" -headers "$STAGE/include" \
  -library "$STAGE/slices/ios-arm64-simulator/libRDCore.a" -headers "$STAGE/include" \
  -output "$STAGE/RDCore.xcframework" >/dev/null

# verify_slice <슬라이스 폴더> <LC_BUILD_VERSION platform 번호: 1 macOS, 2 iOS, 7 iOS 시뮬레이터>
verify_slice() {
  local lib="$STAGE/RDCore.xcframework/$1/libRDCore.a" want=$2 archs platforms
  archs="$(lipo -archs "$lib")"
  platforms="$(otool -l "$lib" | awk '/LC_BUILD_VERSION/{f=1} f&&$1=="platform"{print $2; f=0}' | sort -u | tr '\n' ' ')"
  if [ "$archs" != "arm64" ] || [ "$platforms" != "$want " ]; then
    echo "error: $1: archs '$archs', platforms '$platforms' (want arm64, $want)" >&2
    return 1
  fi
  printf '%-22s arm64, platform %s, %s\n' "$1" "$want" "$(du -h "$lib" | cut -f1)"
}
# verify_tunnel <슬라이스 폴더>: 터널 모드 C 함수와 Go 터널 패키지가 링크되었는지 확인한다.
verify_tunnel() {
  local lib="$STAGE/RDCore.xcframework/$1/libRDCore.a"
  if ! nm -gU "$lib" 2>/dev/null | grep -q ' _rd_tunnel_set_default_interface$'; then
    echo "error: $1: rd_tunnel_set_default_interface is not exported" >&2
    return 1
  fi
  if ! grep -aq 'remotedebug/core/internal/tunnel.Start' "$lib"; then
    echo "error: $1: tunnel mode (internal/tunnel) is not linked" >&2
    return 1
  fi
  echo "$1: tunnel mode symbols present"
}
echo "==> verify slices"
verify_slice macos-arm64 1
verify_slice ios-arm64 2
verify_slice ios-arm64-simulator 7
verify_tunnel ios-arm64

# 새 결과를 고유한 이름으로 옮기고, 링크는 임시 링크를 만든 뒤 rename으로 한 번에 바꾼다.
FINAL="$OUT/RDCore-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcframework"
mv "$STAGE/RDCore.xcframework" "$FINAL"
PREV="$(readlink "$LINK" 2>/dev/null || true)"
ln -sfn "$FINAL" "$LINK.new"
mv -fh "$LINK.new" "$LINK" # -h: 디렉터리를 가리키는 링크를 따라가지 않고 링크 자체를 바꾼다(GNU mv -T와 같다).

cat > "$ROOT/Packages/RDCore/Package.swift.new" <<'SWIFT'
// swift-tools-version: 6.0
// scripts/build-core.sh가 생성한다. RDCore.xcframework는 eyebuild 산출물로 가는 심볼릭 링크다.
import PackageDescription

let package = Package(
    name: "RDCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "RDCoreBridge", targets: ["RDCoreBridge"]),
    ],
    targets: [
        .binaryTarget(name: "RDCoreC", path: "RDCore.xcframework"),
        .target(
            name: "RDCoreBridge",
            dependencies: ["RDCoreC"],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(name: "RDCoreBridgeTests", dependencies: ["RDCoreBridge"]),
    ]
)
SWIFT
mv -f "$ROOT/Packages/RDCore/Package.swift.new" "$ROOT/Packages/RDCore/Package.swift"

# 현재 결과와 직전 결과만 남긴다.
for old in "$OUT"/RDCore*.xcframework "$OUT/slices" "$OUT/include"; do
  [ -e "$old" ] || continue
  [ "$old" = "$FINAL" ] || [ "$old" = "$PREV" ] || rm -rf "$old"
done

echo "xcframework: $FINAL"
echo "note: slices are arm64 only (Apple silicon Macs, arm64 simulator); the Mac app target must build with ARCHS=arm64."
