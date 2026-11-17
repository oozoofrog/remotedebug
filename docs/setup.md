# 설정과 실행

## 요구 사항

| 항목 | 조건 | 작성 환경 |
| --- | --- | --- |
| Mac | Apple silicon | arm64 |
| macOS | 26.0 이상 | 27.2 |
| Xcode | iOS·macOS 26.0 SDK 이상. 확인한 버전은 오른쪽 하나뿐이다 | 27.2 (27B48), Swift 6.4.2 |
| 인터넷 | 처음 빌드할 때 Xcode(SwiftPM)가 [Swiftail](https://github.com/oozoofrog/Swiftail)을 공개 저장소의 고정한 리비전으로 받는다. Go나 미리 만든 바이너리는 필요 없다 | |
| iPhone | iOS 26.0 이상, 개발자 모드 켜짐. 앱과 설치할 Debug 빌드의 개발 프로필에 그 기기가 들어 있어야 한다 | 실기기 확인하지 않음 |
| 시뮬레이터 | arm64. VPN 확장은 쓸 수 없다 | iPhone 18 Pro, iOS 27.2 |

작성 환경은 빌드 산출물을 로컬 도구 `eyebuild`로 한 폴더에 모은다. 이 문서의 명령은 일반 형태다.

### tailnet

- [DNS 관리 페이지](https://login.tailscale.com/admin/dns)에서 MagicDNS와 HTTPS Certificates를 켠다. iOS 설치기가 받는 설치 주소가 https라서 둘 다 필요하다.
- 로그인 방법은 두 가지다. 앱이 여는 브라우저 로그인 페이지를 쓰거나, 관리 콘솔에서 만든 인증 키(`tskey-auth-…`)를 앱에 입력한다. 인증 키는 저장하지 않고 다음 시작에 한 번만 쓴다.
- RemoteDebug 두 앱은 tailnet에 노드를 하나씩 더한다. Mac은 `rd-mac-<8자>`, iPhone 앱은 `rd-phone-<8자>`다. [설치 웹 페이지](#iphone에서-앱-없이-설치웹-페이지)만 쓰는 iPhone은 노드를 더하지 않고 공식 Tailscale 앱이 이미 올린 그 iPhone의 노드를 쓴다.

### tailnet 정책(ACL)

ACL 태그는 선택 사항이다. `tag:rd-mac`, `tag:rd-phone`을 쓰면 iPhone에서 Mac의 443 포트(설치·API)와 4747 포트(앱 QR 페어링)만 허용하도록 네트워크 층에서 한 번 더 막을 수 있다. 태그는 태그를 지정한 인증 키로 로그인한 노드에 붙는다.

> **주의.** tailnet 정책은 tailnet 관리자만 바꿀 수 있다. 아래는 정책 파일 전체가 아니라 기존 정책의 `tagOwners`와 `acls`에 더할 항목이다. 정책 파일을 이 내용만으로 바꾸면 이 규칙 하나만 남아 tailnet의 다른 연결이 모두 끊긴다. 기존 정책에 모든 연결을 허용하는 규칙이 남아 있으면 이 항목을 더해도 더 막히는 연결은 없다. 이 항목의 문법과 동작은 실제 tailnet에 적용해 확인하지 않음.

```
// tagOwners에 더한다
"tag:rd-mac": ["autogroup:admin"],
"tag:rd-phone": ["autogroup:admin"],

// acls에 더한다
{ "action": "accept", "src": ["tag:rd-phone"], "dst": ["tag:rd-mac:443,4747"] },
```

위 규칙은 RemoteDebug iPhone 앱의 노드(`tag:rd-phone`)만 허용한다. [설치 웹 페이지](#iphone에서-앱-없이-설치웹-페이지)를 여는 iPhone은 공식 Tailscale 앱의 노드라서 사용자 소유 노드이고 `tag:rd-phone`이 없다. 기존 정책에 모든 연결을 허용하는 규칙이 없고 위 규칙만 더했다면, 그 iPhone은 Mac에 닿지 못해 Safari가 페이지를 열지 못한다. 설치 웹 페이지를 쓰려면 그 iPhone 노드(또는 그 iPhone을 쓰는 사용자)에서 `tag:rd-mac`의 443 포트로 가는 연결도 허용해야 한다. 기존 정책이 모든 연결을 허용하면 더할 것이 없다. 위의 주의는 이 규칙에도 그대로 적용된다. 예를 들어 tailnet의 모든 사용자 기기를 허용하는 항목은 아래 꼴일 것으로 보이며, 문법과 동작은 실제 tailnet에 적용해 확인하지 않음.

```
// acls에 더한다(확인하지 않음)
{ "action": "accept", "src": ["autogroup:member"], "dst": ["tag:rd-mac:443"] },
```

## 서명

| 대상 | 번들 ID | 서명 |
| --- | --- | --- |
| `RemoteDebugMac` | `com.oozoofrog.app.RemoteDebugMac` | 로컬 서명(`CODE_SIGN_IDENTITY = -`). 팀 ID가 필요 없다 |
| `RemoteDebugPhone` | `<앞부분>.RemoteDebugPhone` | 자동 서명. Network Extension(Packet Tunnel) 권한 필요 |
| `RemoteDebugTunnel` | `<앞부분>.RemoteDebugPhone.Tunnel` | 자동 서명. Network Extension(Packet Tunnel) 권한 필요 |
| `RemoteDebugWidgets` | `<앞부분>.RemoteDebugPhone.Widgets` | 자동 서명 |

앞부분은 `Config/Signing.xcconfig`의 `RD_BUNDLE_PREFIX`이고 기본값은 `com.oozoofrog`에 `.app`을 붙인 값이다. 터널 확장의 번들 ID는 앱이 실행 중에 자기 번들 ID에 `.Tunnel`을 붙여 찾으므로 코드는 고치지 않는다.

1. `Config/Signing.local.xcconfig.example`을 `Config/Signing.local.xcconfig`로 복사하고 `DEVELOPMENT_TEAM`에 10자 팀 ID를 넣는다. 팀 ID는 developer.apple.com의 Account > Membership details에 있다. iPhone 대상들이 같은 팀으로 서명돼야 한다.
2. 기본 앞부분의 번들 ID는 그 ID를 등록한 팀에서만 쓸 수 있다. 다른 팀으로 서명하면 같은 파일에 `RD_BUNDLE_PREFIX = dev.<팀 ID 소문자>`처럼 그 팀이 쓸 수 있는 앞부분을 넣는다. Mac 앱의 **iPhone 앱 설치…**는 이 값을 자동으로 정한다([Mac 앱으로 iPhone 앱 설치](#mac-앱으로-iphone-앱-설치)).
3. Xcode에서 `RemoteDebug.xcodeproj`를 연다. 프로젝트 파일은 저장소에 있고 팀 ID는 들어 있지 않다. 대상과 빌드 설정은 Xcode에서 직접 고친다.
4. Xcode에서 `RemoteDebugPhone`과 `RemoteDebugTunnel`의 Signing & Capabilities를 차례로 연다. Network Extensions 항목에 Packet Tunnel이 있고 프로필 오류가 없으면 그 계정에서 쓸 수 있다. 번들 ID를 쓸 수 없다는 오류가 나오면 2단계를 다시 본다. 권한을 지원하지 않는다는 오류가 나오면 그 계정으로는 iPhone 앱을 만들 수 없다.

사용 중인 Apple 계정이 이 권한을 쓸 수 있는지는 확인하지 않음. 무료 계정에서 가능한지도 확인하지 않음. App ID를 등록하거나 권한을 켜는 일은 계정 소유자가 직접 승인해야 한다.

Xcode 자동 서명은 연결한 iPhone을 개발자 계정에 등록할 수 있다. 기기 등록도 계정 소유자가 승인해야 한다.

### 다른 Mac에 나눠 줄 Mac 앱(Developer ID)

`scripts/release-mac.sh`는 Mac 앱을 Developer ID로 서명하고 Apple 공증을 받아 zip으로 묶는다. 받은 사람은 경고 없이 열 수 있다. App Sandbox는 쓰지 않는다.

- Xcode에 로그인한 계정이 Developer ID 인증서를 만들 수 있어야 한다(계정 소유자). 인증서가 없으면 Xcode가 만든다.
- `Config/Signing.local.xcconfig`에 `DEVELOPMENT_TEAM`이 있어야 한다.
- 서명에는 계정의 법적 이름과 팀 ID가 들어가고, 앱을 받은 사람이 볼 수 있다.
- 이 빌드에는 저장소 경로가 들어가지 않는다. **iPhone 앱 설치…**에서 **선택…**으로 저장소 폴더를 골라야 한다.
- `scripts/release-mac.sh --no-notarize`는 서명까지만 한다.

## 빌드와 실행

```sh
open RemoteDebug.xcodeproj
```

- 앱과 패키지는 소스만으로 빌드된다. Swiftail은 Xcode가 패키지로 받는다. 고정한 리비전은 `RemoteDebug.xcodeproj/project.pbxproj`의 패키지 참조와 `Packages/SwiftailHost/Package.swift` 두 곳에 있고 함께 바꾼다.
- Swiftail을 로컬 체크아웃으로 쓰려면 SwiftPM 명령에는 환경 변수 `SWIFTAIL_PATH`에 그 폴더를 주고(폴더 이름은 `Swiftail`이어야 한다), Xcode에서는 이 저장소 옆의 `../Swiftail` 폴더를 프로젝트 탐색기에 끌어 놓는다. 같은 이름의 원격 패키지를 로컬 사본이 덮어쓴다. 그 변경은 커밋하지 않는다.
- 시험 링크 빌드: `RemoteDebugPhone`, `RemoteDebugTunnel`, `RemoteDebugVPNTunnel`에 컴파일 조건 `RD_TEST_LINKS`를 넣어 시험 전용 도구(`remotedebug://test?…` 주소, 연결 시험, 확장의 시험 진단)를 함께 컴파일한다. `Config/Signing.local.xcconfig`에 `RD_EXTRA_SWIFT_CONDITIONS = RD_TEST_LINKS`를 넣으면 켜진다. 값이 비어 있는 기본에서는 빌드가 달라지지 않는다. 이 빌드에는 TLS 검증을 건너뛰는 도구와 Mac을 1초마다 부르는 도구가 있어 배포하지 않는다.
- Xcode에서 스킴 `RemoteDebugMac`을 고르고 My Mac으로 실행한다.
- 스킴 `RemoteDebugPhone`을 고르고 연결한 iPhone으로 실행한다. 실기기 설치는 기기 소유자가 승인해야 한다.

### `eyebuild`가 없는 Mac

`scripts/check-ipa-roundtrip.sh`, `scripts/check-real-builds.sh`는 `eyebuild`를 부른다. 없으면 `FAIL rdvalidate 빌드`를 출력하고 끝난다. `scripts/check-real-builds.sh`는 그 전에 아래의 DerivedData 조건으로 먼저 끝날 수 있다.

아래 스크립트를 PATH에 있는 폴더에 `eyebuild`라는 이름으로 두면 같은 명령을 받는다. 산출물은 `RD_BUILD_ROOT`(기본 `~/RemoteDebugBuild`) 아래에 쌓인다. 이 스크립트는 빌드하지 않는 호출(`dir`, `run`, `rm`, `swift … build --help`, `xcodebuild … -version`)로 인자 전달만 확인했다. 이 스크립트로 실제 빌드와 시험은 확인하지 않음.

```bash
#!/usr/bin/env bash
set -euo pipefail
root="${RD_BUILD_ROOT:-$HOME/RemoteDebugBuild}"
[ "${1:-}" = "-p" ] && shift 2
cmd="$1"; shift
if [ "$cmd" = "rm" ]; then for p in "$@"; do rm -rf "${root:?}/$p"; done; exit 0; fi
dir="$root/$1"; shift
[ "${1:-}" = "--" ] && shift
mkdir -p "$dir"
case "$cmd" in
  dir) echo "$dir" ;;
  run) EYEBUILD_DIR="$dir" exec "$@" ;;
  swift) sub="$1"; shift; exec swift "$sub" --scratch-path "$dir/.build" "$@" ;;
  xcodebuild) exec xcodebuild -derivedDataPath "$dir/DerivedData" "$@" ;;
  *) echo "eyebuild: 지원하지 않는 명령: $cmd" >&2; exit 2 ;;
esac
```

`scripts/check-real-builds.sh`는 Xcode 기본 DerivedData 위치(`~/Library/Developer/Xcode/DerivedData`)에서 Debug 빌드를 찾는다. Xcode에서 위치를 바꿨으면 `RD_DERIVED_DATA=<폴더>`로 준다. 수락할 빌드가 없으면 종료 코드 3으로 끝난다.

### 명령줄 빌드와 시험

작성 환경에서는 같은 인자를 `eyebuild`로 감싸 실행했다. 시간은 캐시가 있을 때 기록이다. 캐시 없는 첫 빌드 시간은 확인하지 않음.

| 명령 | 내용 | 기록된 시간 |
| --- | --- | --- |
| `swift test --package-path Packages/RemoteDebugKit` | 킷 시험 | 약 10초 |
| `swift test --package-path Packages/PhoneClient` | iPhone 로직 시험 | 약 5초 |
| `swift test --package-path Packages/SwiftailHost` | 호스트 로직(`RDHostLogic`)과 HTTP 전송(`SwiftailHostServer`) 시험. Swiftail이 필요하다 | 기록 없음 |
| `RD_TEST_TMPDIR=<쓰기 가능한 폴더> swift test --package-path Packages/MacHost` | Mac 로직과 호스트 통합 시험(`MacHostCoreTests`, `MacHostE2ETests`). `RD_TEST_TMPDIR`를 주지 않으면 일부 시험이 작성 환경의 빌드 디스크 폴더에 임시 폴더를 만들려다 그 폴더가 없는 Mac에서는 실패한다 | 기록 없음 |
| `swift test --package-path Packages/WebPage` | 설치 웹 페이지 로직을 JavaScriptCore로 시험 | 기록 없음 |
| `scripts/check-ipa-roundtrip.sh` | IPA 묶기와 풀기 | 약 5초 |

```sh
xcodebuild -project RemoteDebug.xcodeproj -scheme RemoteDebugMac -destination 'platform=macOS,arch=arm64' build
xcodebuild -project RemoteDebug.xcodeproj -scheme RemoteDebugMac -destination 'platform=macOS,arch=arm64' test
xcrun simctl list devices available
xcodebuild -project RemoteDebug.xcodeproj -scheme RemoteDebugPhone -destination 'platform=iOS Simulator,id=<시뮬레이터 ID>' build
xcodebuild -project RemoteDebug.xcodeproj -scheme RemoteDebugPhone -destination 'platform=iOS Simulator,id=<시뮬레이터 ID>' test
xcodebuild -project RemoteDebug.xcodeproj -scheme RemoteDebugPhone -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## 이전 버전에서 업데이트한 뒤

앱 안의 tailnet 노드가 바뀌었다(Swiftail). 이전 버전의 로그인과 페어링은 옮기지 않는다.

- Mac: 업데이트한 앱을 처음 실행하면 Tailscale에 다시 로그인해야 한다. **네트워크** 화면에서 로그인한다. 이전 노드의 상태 폴더(`~/Library/Application Support/RemoteDebug/state`)는 읽지 않고, 새 노드가 처음 실행 상태가 되면 지운다. 같은 네트워크 직접 연결의 신원은 새 위치(`direct`)로 옮긴다.
- iPhone: RemoteDebug와 RD 업데이트 두 앱 모두 이전 버전의 tailnet 로그인을 이어받지 않는다(두 앱은 같은 노드를 공유한다). VPN을 켜면 로그인이 필요하고, Mac과 같은 계정으로 로그인한 뒤 Mac과 다시 페어링해야 한다.
- 이전 노드는 tailnet 관리 콘솔의 Machines에 남아 있을 수 있다. 필요하면 지운다. 사용자의 tailnet을 바꾸는 일이므로 관리자가 직접 한다.
- 페어링 허용은 Mac 앱 화면에서만 한다. 에이전트(MCP 도구, `rd` 명령)는 대기 중인 요청을 보고 거부할 수 있지만 허용할 수 없다.
- 호스트 API(`/v1/*`)에 직접 요청을 보내는 도구는 상태를 바꾸는 요청(`POST`, `PUT`, `DELETE`)에 JSON 본문(`Content-Type: application/json`)을 쓰고, 브라우저에서 보낸 요청이면 같은 출처여야 한다([protocol.md](protocol.md) §3).

## 첫 실행: Mac

앱 화면 위의 **시작하기** 목록이 남은 일을 순서대로 보여 준다: 이 Mac을 Tailscale에 연결 → 설치 주소 열기 → iPhone 연결 → 첫 빌드 게시. 지금 할 단계에는 그 단계의 버튼(공유 시작, 로그인 페이지, DNS 설정 페이지, iPhone 페어링, 빌드 가져오기)이 붙는다. 네 단계를 마치면 사라지고, **나중에**를 누르면 숨긴다. 실제 처음 실행 화면으로는 확인하지 않음.

이 절차는 실행 중인 앱에서 손으로 해 보지 않았다. 화면 문구는 소스와 미리보기 스크린샷으로만 확인했다. 실제 tailnet 로그인(2단계)은 실제 tailnet에서 확인하지 않음. 인증서 발급(3단계)은 가짜 tailnet에서도 TLS를 끄고 시험해서 한 번도 실행되지 않았다. [실기기 확인 절차](device-test.md)의 D9, D2, D1, D12에서 확인한다.

1. 앱을 열면 공유가 자동으로 시작된다. 멈췄다면 창 위 안내 줄의 **공유 시작**을 누른다. 공유 상태는 사이드바 아래 한 줄에 나오고, 공유 중지는 그 옆 메뉴에 있다.
2. 로그인한다. 왼쪽 **네트워크** 화면에서 둘 중 하나를 쓴다.
   - 브라우저: 상태가 "로그인 필요"가 되면 **로그인 페이지 열기**를 누른다.
   - 인증 키: **인증 키로 로그인**을 펼쳐 "인증 키(선택)" 칸에 키를 넣고 **인증 키로 다시 시작**을 누른다. 공유를 시작하기 전이면 키를 넣고 **공유 시작**을 누른다.
3. 상태가 "인증서 발급 중"을 거쳐 "공유 중"이 될 때까지 기다린다.
4. **앱** 화면 도구 막대의 **가져오기** 메뉴에서 **빌드 가져오기…**(⌘O)를 누르거나 `.app`, `.ipa`를 창에 끌어 놓는다. 같은 메뉴의 **폴더 감시…**로 폴더를 고르면 새 빌드를 자동으로 가져온다. Xcode에서 Debug 구성으로 기기용으로 빌드한 것만 받는다.
5. 빌드 폴더 이름(`Debug-iphoneos`)과 앱 안의 `*.debug.dylib` 어느 쪽으로도 Debug임을 확인할 수 없으면 "Debug 구성으로 빌드한 앱인가요?" 대화상자가 번들 ID, 버전, 빌드 번호, 경로를 보여 준다. Debug 빌드가 맞을 때만 **Debug 빌드로 가져오기**를 누르고, 아니면 **가져오지 않기**를 누른다.
6. **기기** 화면에서 **iPhone 페어링…**을 누른다. 시트가 "이 iPhone에 RemoteDebug 앱이 있나요?"와 두 동선을 보여 준다. iPhone의 상황으로 고른다. 고르기 전에는 QR도 코드도 열지 않는다. 시트 위의 두 칸으로 동선을 바꿀 수 있다.
   - **RemoteDebug 앱이 있는 iPhone**: QR, 할 일 세 줄, 남은 시간, **페어링 링크 복사**가 나온다. QR에 Tailscale 키가 들어 있으면(아래 [QR 한 번으로 연결](#qr-한-번으로-연결tailscale-oauth-클라이언트)) 링크 복사 대신 "Tailscale 키가 든 QR은 링크로 복사할 수 없습니다. iPhone의 RemoteDebug 앱 안 카메라로 읽으세요."가 나온다. iPhone의 RemoteDebug 앱으로 QR을 읽는다([iPhone 절](#첫-실행-iphone)). QR은 5분 뒤 만료되고 한 번만 쓸 수 있다. **새 QR 만들기**로 다시 연다.
   - **앱이 아직 없는 iPhone**: 할 일 네 줄, 설치 페이지 QR, 코드 없는 설치 페이지 주소, **링크 복사**, 8자 코드, 남은 시간이 나온다. 이 Mac에 RemoteDebug 앱 빌드가 게시되어 있지 않으면 그 안내도 나온다([웹 페이지 절](#iphone에서-앱-없이-설치웹-페이지)). 코드는 5분 뒤 만료되고 한 번만 쓸 수 있다. **새 코드 만들기**로 다시 연다.
7. iPhone이 요청하면 시트에 "요청한 iPhone이 맞는지 확인하고 응답하세요."와 요청 줄이 나온다. 같은 줄이 **기기** 화면의 "허용 대기"에도 나온다. 줄에는 '‘<기기 이름>’(<노드 이름>)이 페어링을 요청했습니다', 요청이 온 동선("RemoteDebug 앱의 QR로 요청" 또는 "Safari 설치 페이지의 코드로 요청"), tailnet 로그인 이름이 있다. 기기 이름은 iPhone이 보낸 값이고, 노드 이름과 로그인 이름은 tailnet이 알려 준 값이다.
   - 앱 QR 요청: 확인 숫자 6자리와 "iPhone에 나온 숫자와 같을 때만 허용하세요."가 함께 나온다. iPhone 앱 화면의 숫자와 같을 때만 **허용**을 누른다. 같은 OAuth 클라이언트의 키로 들어온 iPhone들은 로그인 이름이 같으므로 숫자로 가린다. 노드 이름은 `rd-phone-<8자>`다.
   - 설치 페이지 요청: 확인 숫자가 없다. 공식 Tailscale 앱이 쓰는 그 iPhone의 노드 이름이 나온다([Mac에서 요청 확인하기](#mac에서-요청-확인하기)). 방금 직접 보낸 요청이고 노드 이름과 로그인 이름이 코드를 넘긴 iPhone과 맞을 때만 **허용**을 누른다.

   모르는 요청이면 **거부**를 누른다. 120초 안에 답하지 않거나 iPhone이 연결을 끊으면 요청은 만료된다. 허용한 기기는 이 Mac이 게시한 빌드 목록을 보고 설치할 수 있다. 앱 QR 요청을 허용했는데 "iPhone과 페어링을 끝내지 못했습니다."가 나오면 iPhone이 그사이 연결을 끊은 것이다. 새 QR로 다시 한다.

## 첫 실행: iPhone

### 터미널에서 iPhone 앱 설치

`scripts/install-phone.sh`는 iPhone 앱을 자기 개발자 계정으로 빌드해 연결한 iPhone에 설치한다. Xcode만 있으면 되고, 소스만으로 빌드한다. 처음 빌드할 때 Xcode가 Swiftail을 받으므로 인터넷이 필요하다.

```bash
git clone https://github.com/oozoofrog/remotedebug.git
remotedebug/scripts/install-phone.sh
```

- 서명 팀은 `Config/Signing.local.xcconfig`, 없으면 키체인의 Apple Development 인증서에서 찾는다. 팀이나 iPhone이 여러 개면 목록을 보여 주고 멈춘다. `--team <팀 ID>`, `--device <UDID>`로 고른다.
- 저장소 설정과 다른 팀이면 번들 ID 앞부분을 `dev.<팀 ID 소문자>`로 쓴다. `--prefix`로 바꾼다.
- `Config/Signing.local.xcconfig`가 없으면 고른 값으로 만든다.
- 빌드 산출물은 `RD_BUILD_ROOT`(기본 `~/RemoteDebugBuild`)의 `phone-install`에 둔다.

확인한 것: 새로 복제한 저장소에서 팀·기기를 인자로 주고 iPhone 14 Pro(iOS 27.2)에 설치. 다른 계정과 처음 등록하는 기기는 확인하지 않음. 이 설치는 이전 버전의 스크립트로 한 것이고, 지금의 스크립트(소스만으로 빌드)로는 실행해 보지 않음.

### Mac 앱으로 iPhone 앱 설치

Xcode에서 직접 실행하지 않아도 Mac 앱이 iPhone 앱을 빌드해 설치한다. **기기** 화면 도구 막대나 **시작하기** 목록의 **iPhone 앱 설치…**를 누른다. 실기기로는 확인하지 않음.

1. iPhone을 케이블로 연결하고 잠금을 푼 뒤 '이 컴퓨터를 신뢰'를 허용한다. 처음 연결한 iPhone은 설정 > 개인정보 보호 및 보안 > 개발자 모드를 켠다.
2. **소스**는 이 Mac 앱을 빌드한 저장소가 기본값이다(Mac 앱 Info.plist의 RDSourceRoot 값). 다른 위치면 **선택…**으로 `RemoteDebug.xcodeproj`가 있는 폴더를 고른다.
3. **서명 팀**은 키체인의 Apple Development 인증서에서 찾는다. 없으면 Xcode > Settings > Accounts에서 계정을 추가한다. VPN 권한(Network Extension) 때문에 유료 Apple Developer Program 팀이어야 한다.
4. **번들 ID 앞부분**은 저장소 설정(`Config/Signing.xcconfig`의 `RD_BUNDLE_PREFIX`, 로컬 서명 설정 파일이 덮어씀)의 팀과 같으면 그 값, 다른 팀이면 `dev.<팀 ID 소문자>`가 기본값이다. 앱·터널·위젯은 각각 `<앞부분>.RemoteDebugPhone`, `.Tunnel`, `.Widgets`가 된다.
5. **설치**를 누르면 `xcodebuild -allowProvisioningUpdates -allowProvisioningDeviceRegistration`으로 그 iPhone을 팀에 등록하고 서명해 빌드한 뒤 `devicectl`로 설치하고 실행한다. 기록은 `~/Library/Application Support/RemoteDebug/ProjectLogs/PhoneApp.log`에 남는다. 빌드 결과는 Xcode의 빌드 위치 설정을 따른다.


### Mac과 다른 계정으로 로그인했을 때

iPhone 앱이 VPN에 연결된 뒤 이 iPhone 노드의 tailnet(MagicDNS 이름의 첫 라벨을 뺀 부분)이 페어링한(또는 페어링하려는) Mac의 tailnet과 다르면 "Mac과 다른 Tailscale 계정에 로그인됨"이 나온다. **다른 계정으로 로그인**을 누르면 이 iPhone에 저장된 Tailscale 로그인을 지우고 VPN을 다시 켠다. 로그인 페이지가 나오면 Mac과 같은 계정을 고른다. 이전 계정의 tailnet에는 이 iPhone 노드가 남으므로 필요하면 그 관리 콘솔에서 지운다. 실기기로는 확인하지 않음.

### QR 한 번으로 연결(Tailscale OAuth 클라이언트)

Mac 앱 설정 창(⌘,) **고급** 탭의 "iPhone 자동 연결"에 Tailscale OAuth 클라이언트를 넣으면 iPhone에서 Tailscale 로그인을 하지 않아도 된다. 실제 Tailscale API와 실기기로는 확인하지 않음.

이 키는 앱 QR 동선에만 실린다. 설치 페이지 동선은 iPhone의 공식 Tailscale 앱이 이미 tailnet에 들어 있어야 한다.

1. Mac이 로그인한 tailnet의 관리 콘솔에서 OAuth 클라이언트를 만든다([만드는 법](https://tailscale.com/kb/1215/oauth-clients)). 권한은 Auth Keys 쓰기(`auth_keys`)를 고르고 태그는 `tag:rd-phone`을 고른다. 태그가 목록에 없으면 정책 파일의 `tagOwners`에 `"tag:rd-phone": ["autogroup:admin"]`을 먼저 더한다.
2. 클라이언트 ID와 비밀값(`tskey-client-…`, 만들 때 한 번만 보여 준다)을 Mac 앱 설정 창(⌘,) **고급** > "iPhone 자동 연결"에 넣고 **저장**을 누른다. 저장할 때는 형식만 본다. 클라이언트가 실제로 받아들여지는지는 다음 QR을 열 때 알 수 있고, 키를 만들지 못하면 QR 아래와 이 설정에 그 까닭이 나온다.
3. **기기** > **iPhone 페어링…** > **RemoteDebug 앱이 있는 iPhone**을 열면 QR 아래에 "이 QR에는 한 번만 쓸 수 있는 Tailscale 키가 들어 있어, iPhone은 로그인 없이 연결됩니다."가 나온다. 이 QR에는 **페어링 링크 복사**가 없다(링크를 웹 주소로 내도록 빌드했으면 있다. [페어링 링크를 웹 주소로](#페어링-링크를-웹-주소로연결-도메인)). RemoteDebug 앱 안 카메라로 QR을 읽으면 앱이 그 키로 tailnet에 들어온 뒤 페어링을 요청한다. 확인 숫자가 같으면 Mac에서 **허용**을 누른다.

키는 QR과 같은 5분 동안 한 번만 쓸 수 있고 미리 승인된, `tag:rd-phone`이 붙은 키다. QR을 찍은 기기는 이 tailnet에 들어오므로 QR을 다른 사람에게 보여 주지 않는다. 그 iPhone 노드는 태그가 붙은 노드라서, 정책 파일이 `tag:rd-phone`에서 이 Mac의 443과 4747 포트로 가는 연결을 허용해야 한다([tailnet 정책(ACL)](#tailnet-정책acl)).

tailnet lock이 켜진 tailnet에서는 키로 처음 들어온 iPhone이 서명 기기에서 서명될 때까지 Mac에 닿지 못한다. 시트에 "이 tailnet은 tailnet lock을 씁니다."로 시작하는 안내가 나온다. 서명 기기에서 서명한 뒤 **새 QR 만들기**로 다시 페어링한다.


이 절차는 실기기에서 확인하지 않음. 화면 문구는 시뮬레이터와 미리보기로만 봤다. iOS의 VPN 구성 추가 알림, 실제 로그인, iOS 설치 창, 설치된 앱 실행은 [실기기 확인 절차](device-test.md)의 U9, D9, D1에서 확인한다.

1. 앱의 VPN 카드에서 **VPN 켜기**를 누르고, iOS의 'VPN 구성 추가' 알림에서 허용을 누른다.
2. 상태가 "로그인 필요"가 되면 **로그인 페이지 열기**로 로그인하거나 **인증 키로 켜기**에 키를 넣는다. 상태가 "연결됨"이 될 때까지 기다린다.
3. Mac에서 **iPhone 페어링…** > **RemoteDebug 앱이 있는 iPhone**을 열고, iPhone의 RemoteDebug 앱으로 그 QR을 읽는다. Tailscale 키가 없는 QR이면 Mac에서 복사한 `remotedebug://pair#…` 링크를 iPhone에서 눌러 열어도 된다(웹 주소로 빌드했으면 `https://…` 링크이고 키가 있어도 복사할 수 있다). 링크와 QR에는 비밀이 들어 있으므로 다른 사람에게 보내지 않는다.
4. iPhone과 Mac에 확인 숫자 6자리가 나온다. 같으면 Mac에서 허용한다. 짝이 되면 앱은 `GET /v1/info`로 Mac의 이름과 주소를 받는다.
5. "빌드" 목록에서 **설치**를 누른다. "iOS 설치 창에서 ‘설치’를 누르세요"가 나오면 iOS 설치 창에서 **설치**를 누른다. 창을 닫았으면 **다시 열기**를 누른다.
6. "전송 완료"가 나오면 홈 화면에서 앱을 연다. 개발자를 신뢰하라는 알림이 나오면 설정 > 일반 > VPN 및 기기 관리에서 신뢰한 뒤 다시 연다. 앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드를 확인한다.

### 페어링 링크를 웹 주소로(연결 도메인)

기본 페어링 링크는 `remotedebug://pair#…`이다. 이 스킴은 같은 스킴을 선언한 다른 앱도 받을 수 있어서, Tailscale 키가 든 제안은 링크 복사 없이 QR만 보인다. 자기 웹 도메인이 있으면 링크를 연결 도메인(universal link) `https://<호스트><경로>#…`로 낼 수 있다. 그 주소는 그 도메인이 허락한 앱만 받으므로 키가 든 제안도 링크로 복사한다. 실제 iPhone에서 Safari의 링크를 눌러 앱이 열리고 페어링되는 것을 확인했다(2026-11-17).

1. `Config/Signing.local.xcconfig`에 호스트를 넣는다. 경로는 바꿀 때만 넣는다(기본 `/remotedebug/pair`). xcconfig는 `//`부터 줄 끝을 주석으로 읽으므로 `https://`는 적지 않는다. 빌드 설정이 둘을 합쳐 `RD_PAIR_LINK_BASE`(`https://example.com/remotedebug/pair`)를 만들고 Mac 앱과 iPhone 앱의 Info.plist RDPairLinkBase에 넣는다.

   ```
   RD_PAIR_LINK_HOST = example.com
   RD_PAIR_LINK_PATH = /remotedebug/pair
   ```

2. Mac 앱과 iPhone 앱을 **같은 값으로** 빌드한다(`Config/Signing.local.xcconfig`를 고친 뒤 빌드). 호스트가 있으면 iPhone 앱(`RemoteDebugPhone`)은 `Apps/iOS/RemoteDebugPhone+Links.entitlements`로 서명되어 연결 도메인 권한 `applinks:<호스트>`가 들어간다. 자동 서명이 App ID에 Associated Domains를 켠다(계정 소유자의 승인이 필요할 수 있다). 터널 확장과 RD 업데이트 앱에는 넣지 않는다. 호스트가 비어 있으면 권한도 없고 링크는 `remotedebug://pair#…` 그대로다.
   내려받은 Mac 앱(공증된 배포본)은 이 값 없이 빌드돼 있다. 그 앱에는 사용자 기본값으로 넣고 앱을 다시 연다. 값을 지우면 `remotedebug://pair#…`로 돌아간다.

   ```sh
   defaults write com.oozoofrog.app.RemoteDebugMac RDPairLinkBase https://example.com/remotedebug/pair
   ```

   적용되지 않으면 `~/Library/Containers/com.oozoofrog.app.RemoteDebugMac`이 있는지 본다. 예전에 샌드박스로 빌드한 앱을 돌린 Mac에서는 `defaults`가 그 폴더 안에 쓴다. 그때는 파일 경로로 넣는다: `defaults write ~/Library/Preferences/com.oozoofrog.app.RemoteDebugMac RDPairLinkBase …`.

3. 그 호스트에 아래 두 파일을 올린다.

**`/.well-known/apple-app-site-association`**: `https://<호스트>/.well-known/apple-app-site-association`에서 리디렉션 없이 `Content-Type: application/json`으로 낸다. `appIDs`는 `<팀 ID>.<iPhone 앱 번들 ID>`다. 번들 ID는 `$(RD_BUNDLE_PREFIX).RemoteDebugPhone`이다(Mac 앱의 **iPhone 앱 설치…**나 `scripts/install-phone.sh`가 앞부분을 `dev.<팀 ID 소문자>`로 바꿨으면 그 값). 여러 팀·앞부분으로 설치하면 그 수만큼 `appIDs`에 넣는다. `components`는 페어링 경로 하나만 연다. 아래 팀 ID `ABCDE12345`는 예시다.

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["ABCDE12345.com.oozoofrog.app.RemoteDebugPhone"],
        "components": [
          { "/": "/remotedebug/pair", "comment": "RemoteDebug 앱 페어링 링크. 값은 # 뒤에 있다" }
        ]
      }
    ]
  }
}
```

**대체 페이지**(`https://<호스트><경로>`): 앱이 없거나 앱이 이 주소로 빌드되지 않았을 때, 또는 Safari 주소 막대에 링크를 붙여 넣었을 때 열린다. 주소의 조각(`#` 뒤)에 페어링 비밀과 Tailscale 키가 있으므로 다음을 지킨다.

- 제3자 스크립트·글꼴·분석·광고·iframe을 싣지 않는다. 같은 출처의 정적 HTML 한 장이면 된다.
- 열리자마자, 다른 무엇보다 먼저 주소에서 조각을 지운다(`history.replaceState`). 브라우저 기록에는 조각까지 남을 수 있다.
- 조각을 어디에도 보내지 않는다: 요청, 로그, 분석, 저장소(`localStorage` 등)에 넣지 않는다. 조각은 서버 요청과 Referer에 실리지 않지만, 페이지의 스크립트는 읽을 수 있다.
- `Referrer-Policy: no-referrer`, `Cache-Control: no-store`를 보낸다.
- 할 일을 적는다: RemoteDebug 앱 안 카메라로 Mac의 QR을 읽는다. 링크를 메시지·메모에서 길게 눌러 RemoteDebug로 열 수도 있다. 이 페이지가 계속 열리면 iPhone 앱이 이 주소로 빌드되었는지 확인한다.

```html
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<script>
  // 페어링 비밀과 키가 든 조각을 주소와 현재 기록 항목에서 지운다. 읽거나 보내지 않는다.
  if (location.hash) history.replaceState(null, "", location.pathname);
</script>
<title>RemoteDebug 페어링</title>
<p>이 링크는 RemoteDebug iPhone 앱에서 열립니다. RemoteDebug 앱 안 카메라로 Mac의 QR 코드를 읽으세요.</p>
<p>이 페이지가 계속 보이면 iPhone 앱이 이 주소로 빌드되었는지 확인하세요.</p>
```

iPhone 앱은 호스트와 경로가 설정과 같은 https 링크만 페어링 링크로 읽고(대소문자를 가리지 않는 호스트, 끝의 `/` 하나는 받음), 다른 호스트·경로·포트·쿼리와 `http`는 받지 않는다. `remotedebug://pair#…`도 계속 읽으므로 호스트 없이 빌드한 Mac과도 페어링한다. OS가 배달한 링크는 지금처럼 Mac 주소를 보이고 묻는다. 두 앱의 설정이 어긋나면 iPhone 앱이 안내한다.

| Mac | iPhone | 결과 |
| --- | --- | --- |
| 없음 | 없음 또는 있음 | `remotedebug://pair#…`. 지금과 같다 |
| 있음 | 같은 값 | `https://…#…`. 링크와 QR 모두 열린다 |
| 있음 | 없음 | 앱 안 카메라로 읽으면 "이 iPhone 앱은 그 주소 없이 빌드되었습니다"가 든 안내. 링크를 누르면 대체 페이지가 열린다 |
| 있음 | 다른 호스트나 경로 | 앱 안 카메라로 읽으면 "다른 웹 주소로 빌드한 Mac 앱"이 든 안내 |

실기기에서만 확인되는 것: Apple의 연결 도메인 파일 수집(설치 뒤 시간이 걸릴 수 있다), 링크를 눌렀을 때 앱이 열리는지, 앱이 이 링크를 `onOpenURL`과 `NSUserActivityTypeBrowsingWeb` 중 어느 쪽으로 받는지(둘 다 받는다), 대체 페이지가 조각을 지우는지.

### iPhone 앱 업데이트

RemoteDebug iPhone 앱은 설치하는 동안 자기 VPN이 꺼지므로 자기 빌드를 스스로 설치하지 않는다. 업데이트 앱(RD 업데이트)에서 설치한다: RD 업데이트를 열고 RemoteDebug 빌드의 **업데이트**를 누른다. RD 업데이트는 RemoteDebug의 빌드 목록에서 설치한다. 규칙은 [`protocol-addenda.md`](protocol-addenda.md)의 M.

아래는 RD 업데이트 없이 Mac의 공식 Tailscale로 받는 방법이다. 규칙은 [`protocol-addenda.md`](protocol-addenda.md)의 I.

처음 한 번(Mac):

1. Mac에 공식 Tailscale 앱을 설치하고 로그인한다. iPhone의 공식 Tailscale도 같은 tailnet에 로그인한다.
2. RemoteDebug Mac 앱 설정 창(⌘,) **고급** 탭의 "iPhone 앱 업데이트"에서 **공식 Tailscale로 열기**를 누른다. "열림"과 주소가 나온다.

업데이트할 때마다:

1. Mac에서 이 저장소의 `RemoteDebug.xcodeproj`를 스킴 `RemoteDebugPhone`으로 빌드해 게시한다(앱 화면의 **빌드해서 게시**나 `rd build`). 업데이트 페이지는 가장 최근 빌드를 자동으로 내준다.
2. iPhone에서 공식 Tailscale 앱을 연결한다(RemoteDebug VPN은 꺼진다).
3. Mac 앱 설정 창(⌘,) **고급** 탭의 "iPhone 앱 업데이트"에 나온 주소를 iPhone의 Safari로 연다. Safari에서 **설치**, iOS 창에서 **설치**를 누른다.
4. 설치가 끝나면 RemoteDebug를 열고 VPN을 다시 켠다. 설정 > "이 앱"의 버전으로 확인한다.

- 업데이트 페이지 주소는 Mac의 공식 Tailscale tailnet 안에서만 열린다. Mac 앱이 꺼져 있으면 페이지가 응답하지 않는다.

### Mac에서 iPhone으로 파일 보내기

이미지, JSON, DB, 설정 파일처럼 디버그 중인 앱에 넣을 파일을 Mac에서 iPhone으로 보낸다. 실기기에서 확인하지 않음.

1. Mac 앱 사이드바의 **보낸 파일**에 파일을 끌어 놓거나 **파일 보내기…**로 고른다. 에이전트는 `remotedebug_push_file` 도구나 `rd push <파일>`을 쓴다. 이름이 같은 파일을 다시 보내면 바뀐다. 폴더는 압축해서 보낸다.
   - 프로젝트별 구역: 연결한 프로젝트가 있으면 도구 막대의 **넣을 구역**에서 프로젝트나 **공통**을 고른 뒤 보낸다. 앱 화면에서 그 앱 줄의 더 보기 메뉴 **파일 보내기…**는 그 프로젝트 구역에 넣는다. 보낸 항목은 오른쪽 클릭 **구역 옮기기**로 옮긴다. 에이전트는 `remotedebug_push_file`·`remotedebug_push_link`의 `project`나 `rd push <파일> <프로젝트>`, `rd link <주소> <이름> <프로젝트>`로 정한다(프로젝트는 연결한 프로젝트의 이름이나 `.xcodeproj`·`.xcworkspace` 경로).
2. iPhone 앱의 **파일** 탭을 당겨 새로고침하면 Mac이 보낸 파일이 나온다. 프로젝트 구역에 넣은 항목이 있으면 프로젝트 이름별 칸으로 나뉘고 **공통**이 마지막에 온다. 파일을 눌러 상세 화면에서 **받기**를 누른다. 앱을 닫아도 계속 받고, 진행은 잠금 화면과 Dynamic Island에 보인다.
3. 상세 화면의 **다른 앱으로 보내기**로 디버그 중인 앱에 넘기거나, **파일 앱에서 보기**로 "나의 iPhone > RemoteDebug"를 연다.

- 링크도 보낸다: **링크 보내기…**나 웹 주소 끌어 놓기, `rd link <주소> [이름]`. 웹 주소는 Safari로, `앱스킴://…` 딥 링크는 그 앱으로 열려 디버그 중인 앱의 특정 화면을 바로 열 때 쓴다.
- Mac 앱이 공유 중이어야 iPhone이 받는다. 공유를 멈춘 동안 넣은 파일은 공유를 시작할 때 보낸다.
- RemoteDebug 앱은 다른 앱의 샌드박스에 직접 파일을 넣을 수 없다. 받는 앱이 파일 열기(공유 시트, 문서 선택기)를 지원해야 한다.

### iPhone 알림(새 빌드·파일)

새 빌드가 게시되거나 Mac에서 보낸 파일·링크가 추가되면 iPhone에 알림을 받는다. APNs 개발(sandbox) 환경만 쓴다. 실기기에서 확인하지 않음.

1. Apple Developer에서 APNs 인증 키(`.p8`)를 만들고 Key ID와 Team ID를 적어 둔다.
2. Mac 앱 설정 창(⌘,) **알림** 탭의 **iPhone 알림**에서 **키 파일 고르기…**로 `.p8`을 고르고 **Key ID**와 **Team ID**를 넣은 뒤 **저장**한다. 키 파일 내용은 Mac 키체인(`RemoteDebug APNs key`)에, Key ID와 Team ID는 앱 설정에 저장된다. **키 지우기**로 지운다.
3. iPhone 앱 설정에서 **새 빌드·파일 알림**을 켜고 알림 권한을 허용한다. 거부했다면 **iOS 설정 열기**로 허용한다.
4. Mac의 **시험 알림 보내기**를 눌러 iPhone에 도착하는지 본다. **마지막 전송**에 결과가 나온다.
5. 빌드나 파일·링크 하나를 알리는 알림은 아래로 당기거나 길게 누르면 버튼이 나온다. 빌드는 **설치**, 링크는 **링크 열기**, 파일은 **받기**다. 여러 항목을 묶은 알림과 이름을 숨긴 알림에는 버튼이 없다.

- 알림의 제목과 본문은 Apple의 서버를 거친다. **알림에 이름을 넣지 않기**를 켜면 "새 빌드가 있습니다"처럼 이름 없는 문구만 보낸다.
- 알림 기능을 쓰려면 iPhone 앱이 푸시 알림 권한이 있는 프로비저닝으로 서명되어야 한다. 규칙은 [protocol-addenda.md의 P절](protocol-addenda.md#p-새-빌드파일-알림apns)에 있다.

## iPhone에서 앱 없이 설치(웹 페이지)

RemoteDebug 앱이 아직 없는 iPhone의 동선이다. 공식 Tailscale 앱과 Safari로 페어링하고, 페이지에서 RemoteDebug 앱을 설치한 뒤, 그 앱은 [앱 QR 동선](#첫-실행-iphone)으로 따로 페어링한다. Safari가 쓰는 노드(공식 Tailscale 앱)와 RemoteDebug 앱의 노드(`rd-phone-<8자>`)는 서로 다른 tailnet 노드라서 허용 목록에 따로 들어간다. 실제 iPhone의 Safari, 실제 TLS 인증서, 공식 Tailscale 앱, Safari에서 여는 iOS 설치 창으로는 확인하지 않음. 화면 문구는 페이지 소스(`Packages/SwiftailHost/Sources/RDHostLogic/Resources/web`)와 Mac 앱 소스에서 옮겼다. 실기기 확인은 [D14](device-test.md#d14-설치-웹-페이지공식-tailscale-앱)다.

### 준비

- iPhone: 공식 Tailscale 앱이 Mac과 같은 tailnet에 로그인되어 있고 VPN이 켜져 있다. RemoteDebug iPhone 앱이 있으면 그 앱의 VPN을 끈다. iOS는 VPN을 하나만 켜므로 그 앱의 VPN이 켜져 있으면 공식 앱의 VPN이 꺼진다.
- tailnet: MagicDNS와 HTTPS Certificates가 켜져 있다([tailnet](#tailnet)). 정책에 ACL 규칙을 더했다면 [tailnet 정책(ACL)](#tailnet-정책acl)의 웹 페이지 조건을 본다.
- Mac: RemoteDebug 앱까지 설치하려면 Mac에 RemoteDebug iPhone 앱 빌드(스킴 `RemoteDebugPhone`)가 게시되어 있어야 한다. 없으면 시트에 "이 Mac에 게시된 RemoteDebug 앱 빌드가 없어 4단계를 할 수 없습니다. 먼저 RemoteDebugPhone 스킴을 빌드해 게시하세요."가 나온다.
- Mac: 공유 중이고 설정 창(⌘,) **고급** 탭의 "HTTPS 인증서"가 "발급됨"이다. **네트워크** 화면의 "설치 페이지" 줄에 `https://<Mac의 FQDN>/` 꼴의 주소가 보인다. "아직 없음"이면 아직 페어링할 수 없는 상태다.
- Mac에 Debug 빌드를 가져왔다([첫 실행: Mac](#첫-실행-mac)의 4~5단계).
- 그 iPhone이 설치할 빌드의 개발 프로필에 들어 있고, 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있다. 이 설정 경로는 실기기에서 확인하지 않음.
- 허용은 Mac 앱 화면에서만 한다. Mac에서 떨어져 있으면 Mac 화면을 조작할 방법이 따로 있어야 한다. 원격으로 Mac 화면을 조작해 허용하는 경로는 확인하지 않음.

### 순서

1. Mac: **기기** 화면에서 **iPhone 페어링…**을 누르고 **앱이 아직 없는 iPhone**을 고른다. 할 일 네 줄("iPhone의 Tailscale 앱을 이 Mac과 같은 tailnet에 연결합니다." 등), QR, 코드 없는 설치 페이지 주소(`https://<Mac의 FQDN>/`), **링크 복사**(코드가 든 `https://<Mac의 FQDN>/#code=<코드>`), 8자 코드, 남은 시간이 나온다. 이 동선은 Mac이 페어링할 수 있는 상태이고 tailnet 주소를 받았을 때만 열린다. 코드는 5분 뒤 만료되고 한 번만 쓸 수 있다.
2. iPhone: 셋 중 하나로 페이지를 연다.
   - iPhone 카메라로 시트의 QR을 찍고 나오는 링크를 연다. 시트에도 "iPhone 카메라로 이 QR을 찍거나, Safari에서 아래 주소를 엽니다."라고 나온다.
   - **링크 복사**로 복사한 링크를 iPhone으로 보내 Safari에서 연다.
   - Safari 주소창에 시트의 주소(또는 **네트워크** 화면 "설치 페이지"의 주소)를 넣는다. 이 주소에는 코드가 없으므로 3단계에서 코드를 직접 넣는다.

   Safari 밖의 브라우저는 확인하지 않음.
3. iPhone: 페이지가 "빌드 목록을 받는 중"을 거쳐 "Mac 페어링" 입력 화면을 보여 준다. 링크로 열었으면 "페어링 코드" 칸에 코드가 들어 있고, 요청은 아직 보내지 않은 상태다. 코드가 Mac 시트의 8자와 같은지 본다. 하이픈, 공백, 대소문자는 가리지 않는다. "기기 이름"의 기본값은 iPhone(Safari)이고 Mac의 승인 줄에 이 이름이 나온다.
4. iPhone: **페어링 요청**을 누른다. "Mac의 승인을 기다리는 중", "Mac 앱에서 ‘<기기 이름>’의 페어링 요청을 승인하세요."와 남은 시간이 나온다. 그만두려면 **페어링 취소**를 누른다.
5. Mac: 시트에 "요청한 iPhone이 맞는지 확인하고 응답하세요."와 요청 줄 '‘iPhone(Safari)’(<노드 이름>)이 페어링을 요청했습니다', "Safari 설치 페이지의 코드로 요청"이 나온다. 기기 이름을 바꿨으면 그 이름이 나온다. [Mac에서 요청 확인하기](#mac에서-요청-확인하기)대로 확인한 뒤 **허용**을 누른다.
6. iPhone: 페이지가 "빌드" 목록으로 바뀐다. 빌드마다 이름, '버전 <버전> (<빌드 번호>) · <크기>', 번들 ID, **설치**가 있고, 목록 아래에 다음 할 일 "RemoteDebug를 설치한 뒤 앱을 열고, Mac 앱의 ‘iPhone 페어링…’에서 ‘RemoteDebug 앱이 있는 iPhone’을 골라 나온 QR을 앱으로 읽으세요.", 페이지 아래쪽에 Mac 이름과 주소가 나온다.
7. iPhone: 설치할 빌드의 **설치**를 누른다. "Mac이 빌드를 확인하는 중" 뒤에 **설치 창 열기**와 "설치 창에서 ‘설치’를 누르세요"가 나온다.
8. iPhone: **설치 창 열기**를 누르고, iOS 설치 창이 뜨면 설치를 누른다. 창을 닫았으면 같은 자리의 **다시 열기**를 누른다. 그만두려면 **취소**를 누른다.
9. iPhone: 전송 중에는 '전송 중 <보낸 크기> / <전체 크기>'가 나온다. 끝나면 "전송 완료"와 "Mac이 빌드를 모두 보냈습니다. 설치 진행은 홈 화면의 앱 아이콘에서 확인하세요."가 나온다. **확인**으로 닫는다.
10. iPhone: 홈 화면에서 앱을 연다. 개발자를 신뢰하라는 알림이 나오면 설정 > 일반 > VPN 및 기기 관리에서 신뢰한 뒤 다시 연다. 앱이 실행되지 않으면 페이지에 나오는 "앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있는지 확인하세요."대로 개발자 모드를 확인한다.
11. RemoteDebug 앱을 설치했으면: Mac에서 **iPhone 페어링…** > **RemoteDebug 앱이 있는 iPhone**을 열고 앱으로 QR을 읽어 페어링한다([첫 실행: iPhone](#첫-실행-iphone)). 앱은 Safari와 다른 tailnet 노드라서 이 페어링이 따로 필요하다. 앱의 VPN을 켜면 공식 Tailscale 앱의 VPN은 꺼진다.

설치하는 동안 페이지를 새로고침하면 그 설치의 진행을 더 확인하지 않는다. 홈 화면에서 설치되었는지 직접 보고, 없으면 **설치**를 다시 눌러 새 세션을 연다.

### Mac에서 요청 확인하기

- 요청 줄의 ‘<기기 이름>’은 페이지의 "기기 이름" 칸에 넣은 값이다. 비워 두면 iPhone(Safari)다. 페이지를 연 사람이면 누구나 바꿀 수 있으므로 이 이름만으로 판단하지 않는다.
- 괄호 안은 tailnet이 알려 준 그 iPhone의 노드 이름이다. 공식 Tailscale 앱이 쓰는 노드라서 `rd-phone-<8자>`가 아니고, 그 iPhone의 MagicDNS 이름 첫 부분이다. tailnet 관리 콘솔의 Machines 목록에서 그 iPhone의 이름과 비교한다. 관리 콘솔에 같은 이름이 보이는지는 확인하지 않음.
- 그 아래의 tailnet 로그인 이름이 iPhone의 Tailscale 앱에 로그인한 계정과 같은지 본다.
- 방금 직접 페이지에서 **페어링 요청**을 누른 요청일 때만 **허용**을 누른다. 모르는 요청이면 **거부**를 누른다. 줄에 적힌 시각까지 응답하지 않으면 요청이 만료된다.
- 허용하는 대상은 Safari가 아니라 그 iPhone의 tailnet 노드다. 허용한 뒤에는 그 iPhone에서 Mac에 닿는 모든 앱과 브라우저가 빌드 목록을 보고 설치할 수 있다. 접근을 끊으려면 **기기** 화면에서 그 기기의 **제거**를 누른다.

### 문제 해결(웹 페이지)

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| Safari가 페이지를 열지 못하고 자체 오류를 보여 준다. 이때는 페이지 문구가 나오지 않는다. Safari의 오류 문구는 확인하지 않음 | iPhone에서 공식 Tailscale 앱의 VPN이 꺼져 있다, 공식 앱이 다른 tailnet에 로그인되어 있다, RemoteDebug iPhone 앱의 VPN이 켜져 공식 앱 VPN이 꺼졌다, Mac이 공유 중이 아니다, tailnet 정책이 그 iPhone에서 Mac의 443 포트를 막는다 | 공식 Tailscale 앱에서 VPN과 로그인한 tailnet을 확인한다. Mac **네트워크** 화면의 "설치 페이지" 줄에 주소가 있는지 본다. 정책은 [tailnet 정책(ACL)](#tailnet-정책acl)을 본다 |
| Mac 시트가 **앱이 아직 없는 iPhone**을 열지 않고 페어링할 수 없는 까닭을 보인다. **네트워크** 화면의 "설치 페이지"가 "아직 없음"이다 | Mac이 아직 페어링할 수 없는 상태다(공유 중이 아님, 로그인 필요, HTTPS 인증서 꺼짐 또는 발급 중 등) | **네트워크** 화면의 상태 안내를 따른다. "HTTPS 인증서 꺼짐"이면 **DNS 설정 페이지 열기**에서 켠다 |
| 페이지: "빌드 목록을 받지 못했습니다"와 "Mac에 연결할 수 없습니다. iPhone의 VPN이 켜져 있는지, Mac 앱이 공유 중인지 확인하세요." | 페이지를 연 뒤 VPN이 꺼졌거나 Mac 공유가 멈췄다 | VPN과 Mac 공유를 확인하고 **다시 시도**를 누른다 |
| 페이지: "페어링 코드는 8자입니다. Mac에 표시된 코드를 다시 확인하세요." 또는 "페어링 코드에 쓰지 않는 글자가 들어 있습니다. Mac에 표시된 코드를 다시 확인하세요." | 코드가 8자가 아니거나 `U`·기호가 들어 있다. 요청은 Mac으로 가지 않았다 | Mac 시트의 코드를 다시 넣는다 |
| 페이지: "페어링 코드가 맞지 않거나 만료되었습니다. Mac에 표시된 코드를 확인하고 다시 입력하세요." | 코드가 틀렸거나 5분이 지났다 | Mac 시트의 코드를 확인한다. 시트가 "코드가 만료됐거나 틀린 시도가 많아 더 쓸 수 없습니다. 새 코드를 만드세요."면 **새 코드 만들기**를 누르고 새 링크나 새 코드로 다시 요청한다 |
| 페이지: "코드를 너무 많이 틀렸습니다. Mac에서 새 페어링 코드를 연 뒤 다시 시도하세요." | 다섯 번 틀려 코드가 폐기됐다. Mac은 폐기된 코드를 잠시 계속 보여 줄 수 있다 | Mac에서 **새 코드 만들기** |
| 페이지가 "Mac의 승인을 기다리는 중"에서 넘어가지 않는다 | Mac에서 아직 허용하지 않았다. 허용은 Mac 앱에서만 한다 | Mac 시트나 **기기** 화면의 "허용 대기"에서 그 요청을 확인하고 **허용**을 누른다. 남은 시간이 끝나면 페이지에 "페어링 요청이 만료되었습니다. Mac에서 새 코드를 열고 다시 시도하세요."가 나온다 |
| 페이지: "Mac에서 페어링을 거절했습니다. 다시 하려면 Mac에서 새 코드를 여세요." | Mac에서 **거부**를 눌렀다 | Mac에서 **새 코드 만들기**를 누르고 다시 요청한다 |
| 페이지: "공유 중인 빌드가 없습니다" | Mac에 게시된 빌드가 없다 | Mac에서 Debug 빌드를 가져온 뒤 페이지의 **새로고침**을 누른다 |
| **새로고침**을 누르거나 설치를 진행하는 중에 "Mac 페어링" 입력 화면과 "이 iPhone은 Mac에서 승인되지 않았습니다. 다시 페어링하세요."가 나온다 | Mac에서 이 기기를 제거했거나, 이 iPhone 노드가 허용 목록에 없다 | Mac에서 새 코드를 열고 다시 페어링한다 |
| **설치 창 열기**를 눌러도 iOS 설치 창이 뜨지 않는다 | Safari가 `itms-services` 링크로 설치 창을 여는지는 실기기에서 확인하지 않음 | **다시 열기**를 누른다. Mac **활동** 화면에서 그 설치 줄이 "설치 정보 전송"으로 바뀌었는지 본다. 바뀌었으면 iOS가 Mac에서 설치 정보를 받은 것이다. 매니페스트는 세션마다 5번까지 받을 수 있으므로 여러 번 실패하면 **취소**를 누르고 **설치**로 새 세션을 연다. 바뀌지 않으면 [D2](device-test.md#d2-실제-tls-인증서)로 인증서를 본다 |
| 페이지: "설치 주소가 이 페이지를 연 주소와 달라 열지 않았습니다. Mac 앱 네트워크 화면의 ‘설치 페이지’ 주소로 이 페이지를 다시 연 뒤 설치하세요. 그래도 같으면 Mac 앱을 최신 버전으로 업데이트하세요." | 페이지를 Mac의 `https://<FQDN>/` 주소가 아닌 다른 주소로 열었거나, Mac이 준 설치 주소가 페이지의 규칙(페이지와 같은 출처의 `/i/<토큰>/manifest.plist`를 가리키는 `itms-services` 주소)에 맞지 않아 페이지가 링크를 만들지 않았다 | Mac 앱 **네트워크** 화면 "설치 페이지"의 주소로 페이지를 다시 연다. 같은 주소로 열었는데도 나오면 Mac 앱을 새 버전으로 바꾼 뒤 **다시 설치** |
| 페이지: "Mac이 빌드를 확인하는 동안 응답 시간이 지났습니다. 잠시 뒤 다시 설치하세요." | Mac이 60초 안에 설치 세션을 만들지 못했다 | 잠시 뒤 **다시 설치** |
| 페이지: "제한 시간 안에 전송이 끝났는지 확인하지 못했습니다. 홈 화면에서 앱이 설치되었는지 확인하고, 없으면 다시 설치하세요." | 설치 세션을 연 뒤 600초 안에 전송 완료를 확인하지 못했다 | 홈 화면을 보고, 앱이 없으면 **다시 설치** |
| "전송 완료" 뒤 앱이 실행되지 않는다 | 개발자 모드가 꺼져 있거나 기기가 빌드의 개발 프로필에 없다 | 아래 [문제 해결](#문제-해결)의 같은 줄을 따른다 |

## 문제 해결

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| `FAIL rdvalidate 빌드` | `eyebuild`가 없다(이 문구는 `rdvalidate` 빌드 실패에서도 나온다) | [대체 스크립트](#eyebuild가-없는-mac)를 둔다 |
| "HTTPS 인증서 꺼짐" | tailnet의 HTTPS Certificates가 꺼져 있다 | **DNS 설정 페이지 열기**에서 켠다. 앱은 공유를 다시 시작하지 않아도 잠시 뒤 열린다고 안내하며, 이 동작은 확인하지 않음 |
| "MagicDNS 꺼짐" | tailnet의 MagicDNS가 꺼져 있다 | **DNS 설정 페이지 열기**에서 켠다 |
| Mac: "코드가 만료됐거나 틀린 시도가 많아 더 쓸 수 없습니다. 새 코드를 만드세요." | 5분이 지났거나 다섯 번 틀렸다 | **새 코드 만들기** |
| Mac: "QR이 만료됐습니다. 새 QR을 만드세요." | 앱용 QR을 연 지 5분이 지났다 | **새 QR 만들기** |
| Mac: "iPhone과 페어링을 끝내지 못했습니다. iPhone이 연결을 끊었을 수 있습니다. 새 QR로 다시 시도하세요." | 허용하는 사이 iPhone이 연결을 끊었거나 그 주소의 노드가 바뀌었다 | **새 QR 만들기**로 다시 페어링한다 |
| 앱 QR을 읽었는데 Mac에 요청이 오지 않는다 | tailnet 정책이 iPhone에서 Mac의 4747 포트를 막는다, tailnet lock이 켜져 있어 키로 들어온 iPhone이 아직 서명되지 않았다, Mac이 공유 중이 아니다 | [tailnet 정책(ACL)](#tailnet-정책acl)에 4747을 더한다. lock이면 서명한 뒤 새 QR로 다시 한다 |
| iPhone: "페어링 코드가 맞지 않거나 만료되었습니다. Mac에 표시된 코드를 확인하고 다시 입력하세요." | 코드가 틀렸거나 만료됐다 | Mac의 코드를 다시 확인한다 |
| iPhone: "코드를 너무 많이 틀렸습니다. Mac에서 새 페어링 코드를 연 뒤 다시 시도하세요." | 코드가 폐기됐다. Mac은 폐기된 코드를 계속 보여 줄 수 있다 | Mac에서 **새 코드 만들기** |
| iPhone VPN 카드: "tailnet에 로그인해야 합니다. 로그인하면 자동으로 연결됩니다." | 이 기기가 tailnet에 로그인하지 않았다 | **로그인 페이지 열기** 또는 **인증 키로 켜기** |
| "이 기기에서는 VPN 확장을 쓸 수 없습니다(시뮬레이터)." | 시뮬레이터에서 실행했다 | 실기기에서 실행한다. 시뮬레이터에서는 화면만 볼 수 있다 |
| 설치한 앱이 실행되지 않는다("전송 완료" 뒤 홈 화면에서 열리지 않는다). 앱은 전송이 끝날 때마다 개발자 모드 안내를 보여 주며, 그 문구는 증상이 아니라 안내다 | 개발자 모드가 꺼져 있거나 기기가 빌드의 개발 프로필에 없다 | 설정 > 개인정보 보호 및 보안 > 개발자 모드를 켜고 재시동한다(이 설정 경로는 실기기에서 확인하지 않음). 그래도 열리지 않으면 프로필에 기기가 등록되어 있는지 본다 |
| Mac 거부 목록: "프로비저닝 프로필이 만료됐습니다. Xcode에서 프로필을 갱신하고 다시 빌드하세요." | 빌드의 프로필이 만료됐다 | Xcode에서 다시 빌드해 가져온다 |
| iPhone: "프로비저닝 프로파일이 …에 만료되었습니다. 설치해도 실행되지 않을 수 있습니다." | 게시된 빌드의 프로필이 만료됐다 | Mac에서 새 빌드를 가져온다 |
| 패키지를 받지 못해 빌드가 멈춘다(Swiftail) | 인터넷에 닿지 않거나 고정한 리비전을 받을 수 없다. 로컬 체크아웃을 쓰는 중이면 그 경로(`SWIFTAIL_PATH`)가 틀렸다 | 연결을 확인하고 Xcode에서 패키지를 다시 읽는다. 로컬 체크아웃은 [빌드와 실행](#빌드와-실행)을 본다 |
| "RemoteDebug가 이미 실행 중" | 다른 RemoteDebug가 같은 저장 폴더를 쓰고 있다 | **실행 중인 앱으로 전환**, 또는 그 앱을 종료하고 다시 실행한다 |
| "저장된 빌드 목록(…)을 읽지 못했습니다" | `builds.json`이 손상됐거나 읽을 수 없다. `~/Library/Application Support/RemoteDebug`에 있다 | 파일을 복구한 뒤 공유를 시작하거나 빌드를 다시 가져온다. 게시본은 지우지 않는다 |
| "백업에서 빼지 못했습니다(…)" | 저장 폴더에 백업 제외를 표시하지 못했다. 노드 키가 Time Machine 백업에 들어갈 수 있다 | 폴더 권한을 확인한 뒤 앱을 다시 실행한다. 공유와 가져오기는 그대로 쓸 수 있다 |

실기기 항목은 [실기기 확인 절차](device-test.md)에 있다.
