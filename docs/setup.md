# 설정과 실행

## 요구 사항

| 항목 | 조건 | 작성 환경 |
| --- | --- | --- |
| Mac | Apple silicon | arm64 |
| macOS | 26.0 이상 | 27.2 |
| Xcode | iOS·macOS 26.0 SDK 이상. 확인한 버전은 오른쪽 하나뿐이다 | 27.2 (27B48), Swift 6.4.2 |
| Go | 1.27.3 이상(`core/go.mod`). `scripts/go.sh`가 `GOTOOLCHAIN=local`로 실행하므로 자동으로 내려받지 않는다 | 1.27.3 |
| XcodeGen | `xcodegen` 명령 | 2.46.0 |
| iPhone | iOS 26.0 이상, 개발자 모드 켜짐. 앱과 설치할 Debug 빌드의 개발 프로필에 그 기기가 들어 있어야 한다 | 실기기 확인하지 않음 |
| 시뮬레이터 | arm64. VPN 확장은 쓸 수 없다 | iPhone 18 Pro, iOS 27.2 |

작성 환경은 빌드 산출물을 로컬 도구 `eyebuild`로 `/Volumes/eyedisk/build` 아래에 모은다. 이 문서의 명령은 일반 형태다.

### tailnet

- [DNS 관리 페이지](https://login.tailscale.com/admin/dns)에서 MagicDNS와 HTTPS Certificates를 켠다. iOS 설치기가 받는 설치 주소가 https라서 둘 다 필요하다.
- 로그인 방법은 두 가지다. 앱이 여는 브라우저 로그인 페이지를 쓰거나, 관리 콘솔에서 만든 인증 키(`tskey-auth-…`)를 앱에 입력한다. 인증 키는 저장하지 않고 다음 시작에 한 번만 쓴다.
- RemoteDebug 두 앱은 tailnet에 노드를 하나씩 더한다. Mac은 `rd-mac-<8자>`, iPhone 앱은 `rd-phone-<8자>`다. [설치 웹 페이지](#iphone에서-앱-없이-설치웹-페이지)만 쓰는 iPhone은 노드를 더하지 않고 공식 Tailscale 앱이 이미 올린 그 iPhone의 노드를 쓴다.

### tailnet 정책(ACL)

ACL 태그는 선택 사항이다. `tag:rd-mac`, `tag:rd-phone`을 쓰면 iPhone에서 Mac의 443 포트만 허용하도록 네트워크 층에서 한 번 더 막을 수 있다. 태그는 태그를 지정한 인증 키로 로그인한 노드에 붙는다.

> **주의.** tailnet 정책은 tailnet 관리자만 바꿀 수 있다. 아래는 정책 파일 전체가 아니라 기존 정책의 `tagOwners`와 `acls`에 더할 항목이다. 정책 파일을 이 내용만으로 바꾸면 이 규칙 하나만 남아 tailnet의 다른 연결이 모두 끊긴다. 기존 정책에 모든 연결을 허용하는 규칙이 남아 있으면 이 항목을 더해도 더 막히는 연결은 없다. 이 항목의 문법과 동작은 실제 tailnet에 적용해 확인하지 않음.

```
// tagOwners에 더한다
"tag:rd-mac": ["autogroup:admin"],
"tag:rd-phone": ["autogroup:admin"],

// acls에 더한다
{ "action": "accept", "src": ["tag:rd-phone"], "dst": ["tag:rd-mac:443"] },
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
3. `xcodegen generate --spec project.yml`로 프로젝트를 만든다.
4. Xcode에서 `RemoteDebugPhone`과 `RemoteDebugTunnel`의 Signing & Capabilities를 차례로 연다. Network Extensions 항목에 Packet Tunnel이 있고 프로필 오류가 없으면 그 계정에서 쓸 수 있다. 번들 ID를 쓸 수 없다는 오류가 나오면 2단계를 다시 본다. 권한을 지원하지 않는다는 오류가 나오면 그 계정으로는 iPhone 앱을 만들 수 없다.

사용 중인 Apple 계정이 이 권한을 쓸 수 있는지는 확인하지 않음. 무료 계정에서 가능한지도 확인하지 않음. App ID를 등록하거나 권한을 켜는 일은 계정 소유자가 직접 승인해야 한다.

Xcode 자동 서명은 연결한 iPhone을 개발자 계정에 등록할 수 있다. 기기 등록도 계정 소유자가 승인해야 한다.

## 빌드와 실행

```sh
scripts/build-core.sh
xcodegen generate --spec project.yml
open RemoteDebug.xcodeproj
```

- `scripts/build-core.sh`가 Go 코어를 빌드하고 `Packages/RDCore/RDCore.xcframework` 링크를 만든다. 이 링크가 있어야 프로젝트와 패키지가 빌드된다.
- Xcode에서 스킴 `RemoteDebugMac`을 고르고 My Mac으로 실행한다.
- 스킴 `RemoteDebugPhone`을 고르고 연결한 iPhone으로 실행한다. 실기기 설치는 기기 소유자가 승인해야 한다.

### `eyebuild`가 없는 Mac

`scripts/go.sh`, `scripts/build-core.sh`, `scripts/e2e-mac.sh`, `scripts/e2e-full.sh`, `scripts/check-ipa-roundtrip.sh`, `scripts/check-real-builds.sh`는 `eyebuild`를 부른다. 없을 때 나오는 문구는 스크립트마다 다르다.

| 스크립트 | `eyebuild`가 없을 때 |
| --- | --- |
| `scripts/build-core.sh`, `scripts/e2e-mac.sh`, `scripts/e2e-full.sh` | `eyebuild: command not found`로 멈춘다 |
| `scripts/go.sh` | `exec: eyebuild: not found`로 멈춘다 |
| `scripts/check-ipa-roundtrip.sh`, `scripts/check-real-builds.sh` | `FAIL rdvalidate 빌드`를 출력하고 끝난다. `scripts/check-real-builds.sh`는 그 전에 아래의 DerivedData 조건으로 먼저 끝날 수 있다 |

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

`scripts/check-real-builds.sh`는 `/Volumes/eyedisk/build/Xcode/DerivedData`의 Debug 빌드만 찾는다. 그 폴더가 없는 Mac에서는 수락할 빌드가 없어 종료 코드 3으로 끝난다.

### 명령줄 빌드와 시험

작성 환경에서는 같은 인자를 `eyebuild`로 감싸 실행했다. 시간은 캐시가 있을 때 기록이다. 캐시 없는 첫 빌드 시간은 확인하지 않음.

| 명령 | 내용 | 기록된 시간 |
| --- | --- | --- |
| `scripts/build-core.sh` | xcframework 생성 | 약 20~35초 |
| `scripts/go.sh test -race -count=1 ./...` | Go 전체 시험 | 약 2분 |
| `scripts/go.sh test -race -count=1 -run TestTunnel -v ./...` | 터널 시험 | 약 30초 |
| `swift test --package-path Packages/RemoteDebugKit` | 킷 시험 | 약 10초 |
| `swift test --package-path Packages/PhoneClient` | iPhone 로직 시험 | 약 5초 |
| `RD_TEST_TMPDIR=<쓰기 가능한 폴더> swift test --package-path Packages/MacHost` | Mac 로직 시험. `RDCore.xcframework` 필요. `RD_TEST_TMPDIR`를 주지 않으면 시험이 작성 환경의 `/Volumes/eyedisk/build/remotedebug/mac-host-tmp`에 임시 폴더를 만들려다 그 볼륨이 없는 Mac에서는 실패한다 | 약 10초 |
| `scripts/check-ipa-roundtrip.sh` | IPA 묶기와 풀기 | 약 5초 |
| `scripts/e2e-mac.sh` | 실제 Go 코어와 가짜 tailnet으로 Mac 호스트 시험 | 약 4분 30초 |
| `RD_E2E_APP=1 scripts/e2e-mac.sh` | 위에 더해 샌드박스 앱을 빌드해 실행하고 종료 확인 | 약 5분 |
| `scripts/e2e-full.sh` | Mac과 iPhone 로직 통합 시험. 제한 600초 | 시험 실행 약 4분 |

`scripts/e2e-mac.sh`와 `scripts/e2e-full.sh`는 코어를 다시 빌드하지 않는다. `core/` 소스가 xcframework보다 새로우면 바로 실패하므로 먼저 `scripts/build-core.sh`를 실행한다.

```sh
xcodebuild -project RemoteDebug.xcodeproj -scheme RemoteDebugMac -destination 'platform=macOS,arch=arm64' build
xcodebuild -project RemoteDebug.xcodeproj -scheme RemoteDebugMac -destination 'platform=macOS,arch=arm64' test
xcrun simctl list devices available
xcodebuild -project RemoteDebug.xcodeproj -scheme RemoteDebugPhone -destination 'platform=iOS Simulator,id=<시뮬레이터 ID>' build
xcodebuild -project RemoteDebug.xcodeproj -scheme RemoteDebugPhone -destination 'platform=iOS Simulator,id=<시뮬레이터 ID>' test
xcodebuild -project RemoteDebug.xcodeproj -scheme RemoteDebugPhone -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## 첫 실행: Mac

빌드 화면 위의 **시작하기** 목록이 남은 일을 순서대로 보여 준다: 이 Mac을 Tailscale에 연결 → 설치 주소 열기 → iPhone 연결 → 첫 빌드 게시. 지금 할 단계에는 그 단계의 버튼(공유 시작, 로그인 페이지, DNS 설정 페이지, iPhone 페어링, 빌드 가져오기)이 붙는다. 네 단계를 마치면 사라지고, **나중에**를 누르면 숨긴다. 실제 처음 실행 화면으로는 확인하지 않음.

이 절차는 실행 중인 앱에서 손으로 해 보지 않았다. 화면 문구는 소스와 미리보기 스크린샷으로만 확인했다. 실제 tailnet 로그인(2단계)은 실제 tailnet에서 확인하지 않음. 인증서 발급(3단계)은 가짜 tailnet에서도 TLS를 끄고 시험해서 한 번도 실행되지 않았다. [실기기 확인 절차](device-test.md)의 D9, D2, D1, D12에서 확인한다.

1. 앱을 열면 공유가 자동으로 시작된다. 멈췄다면 앱 왼쪽 아래의 **공유 시작**을 누른다.
2. 로그인한다. 왼쪽 **네트워크** 화면에서 둘 중 하나를 쓴다.
   - 브라우저: 상태가 "로그인 필요"가 되면 **로그인 페이지 열기**를 누른다.
   - 인증 키: "인증 키(선택)" 칸에 키를 넣고 **인증 키로 다시 시작**을 누른다. 공유를 시작하기 전이면 키를 넣고 **공유 시작**을 누른다.
3. 상태가 "인증서 발급 중"을 거쳐 "공유 중"이 될 때까지 기다린다.
4. **빌드** 화면에서 **빌드 가져오기…**(⌘O)를 누르거나 `.app`, `.ipa`를 창에 끌어 놓는다. **폴더 감시…**로 폴더를 고르면 새 빌드를 자동으로 가져온다. Xcode에서 Debug 구성으로 기기용으로 빌드한 것만 받는다.
5. 빌드 폴더 이름(`Debug-iphoneos`)과 앱 안의 `*.debug.dylib` 어느 쪽으로도 Debug임을 확인할 수 없으면 "Debug 구성으로 빌드한 앱인가요?" 대화상자가 번들 ID, 버전, 빌드 번호, 경로를 보여 준다. Debug 빌드가 맞을 때만 **Debug 빌드로 가져오기**를 누르고, 아니면 **가져오지 않기**를 누른다.
6. **기기** 화면에서 **iPhone 페어링…**을 누른다. QR, 8자 코드, 남은 시간, **페어링 링크 복사**가 나온다. 코드는 5분 뒤 만료되고 한 번만 쓸 수 있다. 시트 아래쪽의 "앱 없이 Safari로 설치"는 RemoteDebug 앱이 없는 iPhone용이다([웹 페이지 절](#iphone에서-앱-없이-설치웹-페이지)).
7. iPhone이 요청하면 시트에 "코드가 쓰였습니다. 요청한 기기가 맞는지 확인하고 응답하세요."와 요청 줄이 나온다. 같은 줄이 **기기** 화면의 "허용 대기"에도 나온다. 줄에는 '‘<기기 이름>’(<노드 이름>)이 페어링을 요청했습니다'와 tailnet 로그인 이름이 있다. 기기 이름은 iPhone이 보낸 값이고, 노드 이름과 로그인 이름은 tailnet이 알려 준 값이다. RemoteDebug iPhone 앱이 보낸 요청이면 노드 이름이 `rd-phone-<8자>`다. 설치 웹 페이지에서 보낸 요청이면 공식 Tailscale 앱이 쓰는 그 iPhone의 노드 이름이 나온다([Mac에서 요청 확인하기](#mac에서-요청-확인하기)). 방금 직접 보낸 요청이고 노드 이름과 로그인 이름이 코드를 넘긴 iPhone과 맞을 때만 120초 안에 **허용**을 누르고, 모르는 요청이면 **거부**를 누른다. 허용한 기기는 이 Mac이 게시한 빌드 목록을 보고 설치할 수 있다.

## 다른 프로젝트 연결

이 절차는 실행 중인 앱에서 손으로 해 보지 않았다. 로직은 가짜 빌더와 가짜 DerivedData로 시험했고, 실제 `xcodebuild` 빌드와 실제 Xcode 감지는 확인하지 않음.

1. 프로젝트 폴더나 `.xcodeproj`, `.xcworkspace`를 RemoteDebug 창이나 Dock 아이콘에 끌어 놓는다. **프로젝트** 화면의 **프로젝트 추가…**로 골라도 된다. 폴더를 주면 그 안(없으면 한 단계 아래)에서 워크스페이스를 먼저, 없으면 프로젝트 파일을 찾는다.
2. 앱이 스킴을 읽는다. 스킴이 하나이거나 프로젝트와 이름이 같은 스킴이 있으면 바로 Debug 기기용으로 빌드해 게시한다. 아니면 스킴을 고르고 **빌드해서 게시**를 누른다. 고른 스킴은 다음에도 쓴다.
3. 빌드가 실패하면 행에 컴파일 오류 줄이 나오고 **전체 로그 열기**로 로그를 본다. 로그는 저장 폴더의 `ProjectLogs`에 프로젝트별로 하나씩 있다.
4. 연결한 프로젝트를 Xcode에서 기기용 Debug로 빌드하면 앱이 결과를 가져와 게시한다. 따로 누를 것은 없다.
5. 연결하지 않은 프로젝트를 Xcode에서 기기용 Debug로 빌드하면 "<프로젝트>을(를) RemoteDebug에 등록할까요?" 알림이 온다. **등록**을 누르면 연결되고, **등록하지 않음**을 누르면 그 프로젝트는 다시 묻지 않는다. 같은 제안이 **프로젝트** 화면 위쪽에도 나온다. 알림을 받으려면 처음에 알림 권한을 허용한다.
6. 창을 닫아도 앱은 메뉴 막대에 남아 공유와 감시를 계속한다. 메뉴 막대 아이콘에서 창을 다시 열거나 **로그인할 때 열기**를 켜고, **RemoteDebug 종료**로 끝낸다.

### 에이전트에 설치(Claude Code, Codex)

**프로젝트** 화면 도구 막대의 **에이전트에 설치…**에서 Claude Code와 Codex를 각각 **설치**한다. 사용자 전체 설정에 두 가지가 들어가고, 어느 프로젝트에서든 에이전트가 RemoteDebug로 빌드·게시할 수 있다.

- 스킬 `remotedebug`: `~/.claude/skills/remotedebug/SKILL.md`, `~/.codex/skills/remotedebug/SKILL.md`
- MCP 서버 `remotedebug`: `claude mcp add --scope user`, `codex mcp add`로 등록한다. 서버는 앱 실행 파일을 `--mcp` 인자로 띄운 것이고, 도구는 `remotedebug_status`, `remotedebug_schemes`, `remotedebug_build`, `remotedebug_pairing_code`, `remotedebug_pair_requests`, `remotedebug_pair_decide`, `remotedebug_push_file`, `remotedebug_files`, `remotedebug_device_logs`다.

`claude`나 `codex` 명령을 찾지 못하면 스킬만 설치하고 그렇게 알린다. 새로 여는 세션부터 적용된다. 같은 화면의 **제거**로 되돌린다. 앱을 다른 위치로 옮기면 **다시 설치**를 눌러 서버 경로를 고친다.

화면의 설치 버튼은 손으로 눌러 보지 않았다. MCP 서버는 설치한 앱에 `initialize`, `tools/list`, `remotedebug_status` 호출을 보내 응답을 확인했다.

### 에이전트 연결

프로젝트 행의 더 보기 메뉴에서 **에이전트 연결…**을 누르면 그 프로젝트 폴더에 두 파일을 쓴다.

- `.claude/skills/remotedebug/SKILL.md`: Claude Code용 스킬
- `AGENTS.md`: 끝에 `<!-- remotedebug:start -->`와 `<!-- remotedebug:end -->` 사이의 단락을 더한다(Codex 등). 이미 있으면 그 단락만 바꾼다.

두 파일은 앱이 저장 폴더에 만들어 두는 명령 `agent/rd`를 쓰는 법을 담는다. 명령은 JSON 한 줄을 출력하고 성공하면 종료 코드 0으로 끝난다. 앱이 꺼져 있으면 명령이 앱을 연다.

```sh
RD="$HOME/Library/Application Support/RemoteDebug/agent/rd"
"$RD" build <프로젝트 폴더> [스킴]   # 연결하고 Debug 기기용으로 빌드해 게시
"$RD" schemes <프로젝트 폴더>         # 스킴 목록
"$RD" status                          # 공유 여부, 설치 페이지 주소, 연결한 프로젝트
"$RD" push <파일>                     # 파일을 iPhone RemoteDebug 앱으로 보낸다
"$RD" files                           # 보낸 파일 목록(구역 포함). files <프로젝트>는 그 구역만
```

두 파일은 저장소에 새 변경으로 남는다. 커밋할지는 그 프로젝트에서 정한다.

## 첫 실행: iPhone

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

Mac 앱 **네트워크** 화면의 "iPhone 자동 연결"에 Tailscale OAuth 클라이언트를 넣으면 iPhone에서 Tailscale 로그인을 하지 않아도 된다. 실제 Tailscale API와 실기기로는 확인하지 않음.

1. Mac이 로그인한 tailnet의 관리 콘솔에서 OAuth 클라이언트를 만든다([만드는 법](https://tailscale.com/kb/1215/oauth-clients)). 권한은 Auth Keys 쓰기(`auth_keys`)를 고르고 태그는 `tag:rd-phone`을 고른다. 태그가 목록에 없으면 정책 파일의 `tagOwners`에 `"tag:rd-phone": ["autogroup:admin"]`을 먼저 더한다. 기기 읽기 권한을 함께 주면 다음 단계에서 이 Mac이 같은 tailnet인지 확인한다.
2. 클라이언트 ID와 비밀값(`tskey-client-…`, 만들 때 한 번만 보여 준다)을 Mac 앱 **네트워크** > "iPhone 자동 연결"에 넣고 **확인하고 저장**을 누른다.
3. **기기** > **iPhone 페어링…**을 열면 QR 아래에 "이 QR에는 … Tailscale 키가 들어 있어"가 나온다. iPhone 카메라나 RemoteDebug 앱으로 QR을 찍으면 앱이 그 키로 VPN을 켜고 페어링을 요청한다. Mac에서 **허용**을 누르면 끝난다.

키는 15분 동안 한 번만 쓸 수 있고 미리 승인된, `tag:rd-phone`이 붙은 키다. QR을 찍은 기기는 이 tailnet에 들어오므로 QR을 다른 사람에게 보여 주지 않는다. 그 iPhone 노드는 태그가 붙은 노드라서, 정책 파일이 `tag:rd-phone`에서 이 Mac의 443 포트로 가는 연결을 허용해야 한다([tailnet 정책(ACL)](#tailnet-정책acl)).


이 절차는 실기기에서 확인하지 않음. 화면 문구는 시뮬레이터와 미리보기로만 봤다. iOS의 VPN 구성 추가 알림, 실제 로그인, iOS 설치 창, 설치된 앱 실행은 [실기기 확인 절차](device-test.md)의 U9, D9, D1에서 확인한다.

1. 앱의 VPN 카드에서 **VPN 켜기**를 누르고, iOS의 'VPN 구성 추가' 알림에서 허용을 누른다.
2. 상태가 "로그인 필요"가 되면 **로그인 페이지 열기**로 로그인하거나 **인증 키로 켜기**에 키를 넣는다. 상태가 "연결됨"이 될 때까지 기다린다.
3. "Mac 페어링"에서 **QR 코드 스캔**으로 Mac의 QR을 찍거나, Mac 주소와 8자 코드를 입력하고 **페어링 요청**을 누른다. Mac 주소는 Mac 앱 **네트워크** 화면의 "주소(FQDN)"에 있다. 페어링 시트에는 주소가 나오지 않는다. Mac에서 복사한 `remotedebug://pair?…` 링크는 iPhone에서 눌러 열 수 있다. 링크를 붙여 넣는 입력란은 없다.
4. "Mac의 승인을 기다리는 중"이 나오면 Mac에서 허용한다.
5. "빌드" 목록에서 **설치**를 누른다. "iOS 설치 창에서 ‘설치’를 누르세요"가 나오면 iOS 설치 창에서 **설치**를 누른다. 창을 닫았으면 **다시 열기**를 누른다.
6. "전송 완료"가 나오면 홈 화면에서 앱을 연다. 개발자를 신뢰하라는 알림이 나오면 설정 > 일반 > VPN 및 기기 관리에서 신뢰한 뒤 다시 연다. 앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드를 확인한다.

### iPhone 앱 업데이트

RemoteDebug iPhone 앱은 설치하는 동안 자기 VPN이 꺼지므로 자기 빌드를 스스로 설치하지 않는다. 업데이트 앱(RD 업데이트)에서 설치한다: RD 업데이트를 열고 RemoteDebug 빌드의 **업데이트**를 누른다. RD 업데이트는 RemoteDebug의 빌드 목록에서 설치한다. 규칙은 [`protocol-addenda.md`](protocol-addenda.md)의 M.

아래는 RD 업데이트 없이 Mac의 공식 Tailscale로 받는 방법이다. 규칙은 [`protocol-addenda.md`](protocol-addenda.md)의 I.

처음 한 번(Mac):

1. Mac에 공식 Tailscale 앱을 설치하고 로그인한다. iPhone의 공식 Tailscale도 같은 tailnet에 로그인한다.
2. RemoteDebug Mac 앱 **네트워크** 화면의 "iPhone 앱 업데이트"에서 **공식 Tailscale로 열기**를 누른다. "열림"과 주소가 나온다.

업데이트할 때마다:

1. Mac에서 이 저장소의 `RemoteDebug.xcodeproj`를 스킴 `RemoteDebugPhone`으로 빌드해 게시한다(프로젝트 화면이나 `rd build`). 업데이트 페이지는 가장 최근 빌드를 자동으로 내준다.
2. iPhone에서 공식 Tailscale 앱을 연결한다(RemoteDebug VPN은 꺼진다).
3. Mac 앱 **네트워크** 화면의 "iPhone 앱 업데이트"에 나온 주소를 iPhone의 Safari로 연다. Safari에서 **설치**, iOS 창에서 **설치**를 누른다.
4. 설치가 끝나면 RemoteDebug를 열고 VPN을 다시 켠다. 설정 > "이 앱"의 버전으로 확인한다.

- 업데이트 페이지 주소는 Mac의 공식 Tailscale tailnet 안에서만 열린다. Mac 앱이 꺼져 있으면 페이지가 응답하지 않는다.

### Mac에서 iPhone으로 파일 보내기

이미지, JSON, DB, 설정 파일처럼 디버그 중인 앱에 넣을 파일을 Mac에서 iPhone으로 보낸다. 실기기에서 확인하지 않음.

1. Mac 앱 사이드바의 **보낸 파일**에 파일을 끌어 놓거나 **파일 보내기…**로 고른다. 에이전트는 `remotedebug_push_file` 도구나 `rd push <파일>`을 쓴다. 이름이 같은 파일을 다시 보내면 바뀐다. 폴더는 압축해서 보낸다.
   - 프로젝트별 구역: 연결한 프로젝트가 있으면 도구 막대의 **넣을 구역**에서 프로젝트나 **공통**을 고른 뒤 보낸다. 프로젝트 화면의 더 보기 메뉴 **파일 보내기…**는 그 프로젝트 구역에 넣는다. 보낸 항목은 오른쪽 클릭 **구역 옮기기**로 옮긴다. 에이전트는 `remotedebug_push_file`·`remotedebug_push_link`의 `project`나 `rd push <파일> <프로젝트>`, `rd link <주소> <이름> <프로젝트>`로 정한다(프로젝트는 연결한 프로젝트의 이름이나 `.xcodeproj`·`.xcworkspace` 경로).
2. iPhone 앱의 **파일** 탭을 당겨 새로고침하면 Mac이 보낸 파일이 나온다. 프로젝트 구역에 넣은 항목이 있으면 프로젝트 이름별 칸으로 나뉘고 **공통**이 마지막에 온다. 파일을 눌러 상세 화면에서 **받기**를 누른다. 앱을 닫아도 계속 받고, 진행은 잠금 화면과 Dynamic Island에 보인다.
3. 상세 화면의 **다른 앱으로 보내기**로 디버그 중인 앱에 넘기거나, **파일 앱에서 보기**로 "나의 iPhone > RemoteDebug"를 연다.

- 링크도 보낸다: **링크 보내기…**나 웹 주소 끌어 놓기, `rd link <주소> [이름]`. 웹 주소는 Safari로, `앱스킴://…` 딥 링크는 그 앱으로 열려 디버그 중인 앱의 특정 화면을 바로 열 때 쓴다.
- Mac 앱이 공유 중이어야 iPhone이 받는다. 공유를 멈춘 동안 넣은 파일은 공유를 시작할 때 보낸다.
- RemoteDebug 앱은 다른 앱의 샌드박스에 직접 파일을 넣을 수 없다. 받는 앱이 파일 열기(공유 시트, 문서 선택기)를 지원해야 한다.

## iPhone에서 앱 없이 설치(웹 페이지)

RemoteDebug iPhone 앱 대신 공식 Tailscale 앱과 Safari로 페어링하고 설치한다. 실제 iPhone의 Safari, 실제 TLS 인증서, 공식 Tailscale 앱, Safari에서 여는 iOS 설치 창으로는 확인하지 않음. 화면 문구는 페이지 소스(`core/internal/host/web`)와 Mac 앱 소스에서 옮겼다. 실기기 확인은 [D14](device-test.md#d14-설치-웹-페이지공식-tailscale-앱)다.

### 준비

- iPhone: 공식 Tailscale 앱이 Mac과 같은 tailnet에 로그인되어 있고 VPN이 켜져 있다. RemoteDebug iPhone 앱이 있으면 그 앱의 VPN을 끈다. iOS는 VPN을 하나만 켜므로 그 앱의 VPN이 켜져 있으면 공식 앱의 VPN이 꺼진다.
- tailnet: MagicDNS와 HTTPS Certificates가 켜져 있다([tailnet](#tailnet)). 정책에 ACL 규칙을 더했다면 [tailnet 정책(ACL)](#tailnet-정책acl)의 웹 페이지 조건을 본다.
- Mac: 공유 중이고 **네트워크** 화면의 "HTTPS 인증서"가 "발급됨"이다. 같은 화면의 "설치 페이지" 줄에 `https://<Mac의 FQDN>/` 꼴의 주소가 보인다. "아직 없음"이면 아직 페어링할 수 없는 상태다.
- Mac에 Debug 빌드를 가져왔다([첫 실행: Mac](#첫-실행-mac)의 4~5단계).
- 그 iPhone이 설치할 빌드의 개발 프로필에 들어 있고, 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있다. 이 설정 경로는 실기기에서 확인하지 않음.
- 허용은 Mac 앱 화면에서만 한다. Mac에서 떨어져 있으면 Mac 화면을 조작할 방법이 따로 있어야 한다. 원격으로 Mac 화면을 조작해 허용하는 경로는 확인하지 않음.

### 순서

1. Mac: **기기** 화면에서 **iPhone 페어링…**을 누른다. "iPhone 페어링" 시트의 아래쪽 "앱 없이 Safari로 설치"에 QR, 링크(`https://<Mac의 FQDN>/#code=<코드>`), **링크 복사**, 그리고 "iPhone의 Tailscale 앱이 이 Mac과 같은 tailnet에 로그인되어 있고 VPN이 켜져 있어야 열립니다. 링크에는 위와 같은 코드가 들어 있습니다. 요청이 오면 이 Mac에서 허용하거나 거부하세요."가 나온다. 이 부분은 Mac이 페어링할 수 있는 상태이고 tailnet 주소를 받았을 때만 보인다. 코드는 5분 뒤 만료되고 한 번만 쓸 수 있다.
2. iPhone: 셋 중 하나로 페이지를 연다.
   - iPhone 카메라로 시트의 QR을 찍고 나오는 링크를 연다. 시트에도 "iPhone 카메라로 QR을 찍거나 Safari에서 링크를 여세요."라고 나온다.
   - **링크 복사**로 복사한 링크를 iPhone으로 보내 Safari에서 연다.
   - Safari 주소창에 **네트워크** 화면 "설치 페이지"의 주소를 넣는다. 이 주소에는 코드가 없으므로 3단계에서 코드를 직접 넣는다.

   Safari 밖의 브라우저는 확인하지 않음.
3. iPhone: 페이지가 "빌드 목록을 받는 중"을 거쳐 "Mac 페어링" 입력 화면을 보여 준다. 링크로 열었으면 "페어링 코드" 칸에 코드가 들어 있고, 요청은 아직 보내지 않은 상태다. 코드가 Mac 시트의 8자와 같은지 본다. 하이픈, 공백, 대소문자는 가리지 않는다. "기기 이름"의 기본값은 iPhone(Safari)이고 Mac의 승인 줄에 이 이름이 나온다.
4. iPhone: **페어링 요청**을 누른다. "Mac의 승인을 기다리는 중", "Mac 앱에서 ‘<기기 이름>’의 페어링 요청을 승인하세요."와 남은 시간이 나온다. 그만두려면 **페어링 취소**를 누른다.
5. Mac: 시트에 "코드가 쓰였습니다. 요청한 기기가 맞는지 확인하고 응답하세요."와 요청 줄 '‘iPhone(Safari)’(<노드 이름>)이 페어링을 요청했습니다'가 나온다. 기기 이름을 바꿨으면 그 이름이 나온다. [Mac에서 요청 확인하기](#mac에서-요청-확인하기)대로 확인한 뒤 **허용**을 누른다.
6. iPhone: 페이지가 "빌드" 목록으로 바뀐다. 빌드마다 이름, '버전 <버전> (<빌드 번호>) · <크기>', 번들 ID, **설치**가 있고, 페이지 아래쪽에 Mac 이름과 주소가 나온다.
7. iPhone: 설치할 빌드의 **설치**를 누른다. "Mac이 빌드를 확인하는 중" 뒤에 **설치 창 열기**와 "설치 창에서 ‘설치’를 누르세요"가 나온다.
8. iPhone: **설치 창 열기**를 누르고, iOS 설치 창이 뜨면 설치를 누른다. 창을 닫았으면 같은 자리의 **다시 열기**를 누른다. 그만두려면 **취소**를 누른다.
9. iPhone: 전송 중에는 '전송 중 <보낸 크기> / <전체 크기>'가 나온다. 끝나면 "전송 완료"와 "Mac이 빌드를 모두 보냈습니다. 설치 진행은 홈 화면의 앱 아이콘에서 확인하세요."가 나온다. **확인**으로 닫는다.
10. iPhone: 홈 화면에서 앱을 연다. 개발자를 신뢰하라는 알림이 나오면 설정 > 일반 > VPN 및 기기 관리에서 신뢰한 뒤 다시 연다. 앱이 실행되지 않으면 페이지에 나오는 "앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있는지 확인하세요."대로 개발자 모드를 확인한다.

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
| Mac 시트에 "앱 없이 Safari로 설치"가 없다. **네트워크** 화면의 "설치 페이지"가 "아직 없음"이다 | Mac이 아직 페어링할 수 없는 상태다(공유 중이 아님, 로그인 필요, HTTPS 인증서 꺼짐 또는 발급 중 등) | **네트워크** 화면의 상태 안내를 따른다. "HTTPS 인증서 꺼짐"이면 **DNS 설정 페이지 열기**에서 켠다 |
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
| `RDCore.xcframework 링크가 가리키는 폴더가 없습니다`, 또는 Xcode가 `RDCore.xcframework`를 찾지 못함 | 링크가 가리키는 빌드 폴더가 지워졌거나(작성 환경은 며칠 쓰지 않은 빌드 폴더를 자동으로 지운다) 다른 Mac에서 받은 저장소다 | `scripts/build-core.sh`를 실행하고 Xcode에서 패키지를 다시 읽는다 |
| `RDCore.xcframework가 core/ 소스보다 오래됐습니다.` | xcframework를 만든 뒤 `core/`가 바뀌었다 | `scripts/build-core.sh` |
| `exec: go: not found` | Go가 없다 | Go 1.27.3 이상을 설치한다 |
| `go.mod requires go >= 1.27.3` | Go가 오래됐다. `GOTOOLCHAIN=local`이라 자동으로 받지 않는다 | Go를 올린다 |
| `eyebuild: command not found`, `exec: eyebuild: not found`, 또는 `FAIL rdvalidate 빌드` | `eyebuild`가 없다(마지막 문구는 `rdvalidate` 빌드 실패에서도 나온다) | [대체 스크립트](#eyebuild가-없는-mac)를 둔다 |
| "HTTPS 인증서 꺼짐" | tailnet의 HTTPS Certificates가 꺼져 있다 | **DNS 설정 페이지 열기**에서 켠다. 앱은 공유를 다시 시작하지 않아도 잠시 뒤 열린다고 안내하며, 이 동작은 확인하지 않음 |
| "MagicDNS 꺼짐" | tailnet의 MagicDNS가 꺼져 있다 | **DNS 설정 페이지 열기**에서 켠다 |
| Mac: "코드가 만료됐거나 틀린 시도가 많아 더 쓸 수 없습니다. 새 코드를 만드세요." | 5분이 지났거나 다섯 번 틀렸다 | **새 코드 만들기** |
| iPhone: "페어링 코드가 맞지 않거나 만료되었습니다. Mac에 표시된 코드를 확인하고 다시 입력하세요." | 코드가 틀렸거나 만료됐다 | Mac의 코드를 다시 확인한다 |
| iPhone: "코드를 너무 많이 틀렸습니다. Mac에서 새 페어링 코드를 연 뒤 다시 시도하세요." | 코드가 폐기됐다. Mac은 폐기된 코드를 계속 보여 줄 수 있다 | Mac에서 **새 코드 만들기** |
| iPhone VPN 카드: "tailnet에 로그인해야 합니다. 로그인하면 자동으로 연결됩니다." | 이 기기가 tailnet에 로그인하지 않았다 | **로그인 페이지 열기** 또는 **인증 키로 켜기** |
| "이 기기에서는 VPN 확장을 쓸 수 없습니다(시뮬레이터)." | 시뮬레이터에서 실행했다 | 실기기에서 실행한다. 시뮬레이터에서는 화면만 볼 수 있다 |
| 설치한 앱이 실행되지 않는다("전송 완료" 뒤 홈 화면에서 열리지 않는다). 앱은 전송이 끝날 때마다 개발자 모드 안내를 보여 주며, 그 문구는 증상이 아니라 안내다 | 개발자 모드가 꺼져 있거나 기기가 빌드의 개발 프로필에 없다 | 설정 > 개인정보 보호 및 보안 > 개발자 모드를 켜고 재시동한다(이 설정 경로는 실기기에서 확인하지 않음). 그래도 열리지 않으면 프로필에 기기가 등록되어 있는지 본다 |
| Mac 거부 목록: "프로비저닝 프로필이 만료됐습니다. Xcode에서 프로필을 갱신하고 다시 빌드하세요." | 빌드의 프로필이 만료됐다 | Xcode에서 다시 빌드해 가져온다 |
| iPhone: "프로비저닝 프로파일이 …에 만료되었습니다. 설치해도 실행되지 않을 수 있습니다." | 게시된 빌드의 프로필이 만료됐다 | Mac에서 새 빌드를 가져온다 |
| "RemoteDebug가 이미 실행 중" | 다른 RemoteDebug가 같은 저장 폴더를 쓰고 있다 | **실행 중인 앱으로 전환**, 또는 그 앱을 종료하고 다시 실행한다 |
| "저장된 빌드 목록(…)을 읽지 못했습니다" | `builds.json`이 손상됐거나 읽을 수 없다. 앱 컨테이너의 Application Support/RemoteDebug에 있다 | 파일을 복구한 뒤 공유를 시작하거나 빌드를 다시 가져온다. 게시본은 지우지 않는다 |
| "백업에서 빼지 못했습니다(…)" | 저장 폴더에 백업 제외를 표시하지 못했다. 노드 키가 Time Machine 백업에 들어갈 수 있다 | 폴더 권한을 확인한 뒤 앱을 다시 실행한다. 공유와 가져오기는 그대로 쓸 수 있다 |

실기기 항목은 [실기기 확인 절차](device-test.md)에 있다.
