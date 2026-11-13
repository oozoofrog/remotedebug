# RemoteDebug

[English](README.md)

RemoteDebug는 Mac의 Debug(개발 서명) 빌드를 Tailscale을 거쳐 iPhone으로 보낸다. Mac 앱이 빌드를 검사해 게시하면, 페어링한 iPhone 앱이 목록을 받아 iOS 설치기로 설치한다. 두 앱 모두 Tailscale을 내장하고, 허용한 기기만 접근할 수 있으며, 개발 서명 Debug 빌드만 게시한다. Debug 구성은 빌드 폴더 이름(`Debug-iphoneos`)이나 앱 안의 `*.debug.dylib`로 확인하고, 둘 다 없으면 대화상자에서 직접 확인해야 게시한다.

`docs/`의 자세한 문서는 한국어로 쓰여 있다.

## 에이전트를 위한 안내

### 에이전트에서 RemoteDebug 쓰기

Mac 앱의 **에이전트에 설치…**는 Claude Code와 Codex에 MCP 서버 `remotedebug`와 스킬을 설치한다. MCP 서버는 같은 Mac 앱 실행 파일을 `--mcp`로 띄운 것이고, 명령은 실행 중인 앱에 넘긴다.

| 도구 | 하는 일 |
| --- | --- |
| `remotedebug_status` | 공유 중인지, 설치 페이지 주소, 연결한 프로젝트 |
| `remotedebug_schemes` | Xcode 프로젝트(`project_path`)를 연결하고 스킴 목록을 돌려준다 |
| `remotedebug_build` | `project_path`(선택 `scheme`)를 Debug 기기용으로 빌드해 게시한다. 빌드가 끝날 때까지 기다린다 |
| `remotedebug_pairing_code` | 5분짜리 페어링 코드를 연다. 코드와 `remotedebug://pair?…` 링크(Tailscale 키 없음)를 돌려준다 |
| `remotedebug_pair_requests` | 허용을 기다리는 페어링 요청(기기 이름, tailnet 노드 이름, 로그인, 만료 시각) |
| `remotedebug_pair_decide` | 요청을 허용하거나 거부한다(`request_id`, `approve`) |
| `remotedebug_device_logs` | iPhone 앱이 보낸 진단 로그(앱 시작, VPN, 페어링, 빌드 목록, 설치, 업데이트) |
| `remotedebug_crash_logs` | iPhone이 보낸 크래시 기록 목록과 원문 |
| `remotedebug_push_file`, `remotedebug_push_link`, `remotedebug_files` | 페어링한 iPhone에 파일·링크를 보내고, 보낸 목록을 본다 |

MCP가 없으면 `~/Library/Application Support/RemoteDebug/agent/rd`로 같은 명령을 쓴다(`rd status`, `rd build <프로젝트> [스킴]`, `rd pair`, `rd requests`, `rd approve <id>`, `rd deny <id>`, `rd push <파일>`, `rd link <주소>`).

에이전트가 지킬 것:

- Mac은 게시까지만 한다. 설치는 사람이 iPhone에서 **설치**를 누른다.
- 페어링 요청은 사람이 방금 요청했다고 말했고 노드 이름이 맞을 때만 허용한다(RemoteDebug 앱은 `rd-phone-<8자>`).
- 페어링 코드와 Tailscale 키는 비밀이다. 에이전트 응답에는 Tailscale 키를 넣지 않으므로, 에이전트가 받은 페어링 링크로는 iPhone에서 Tailscale 로그인이 필요하다.
- iPhone에서 무언가 실패하면 먼저 `remotedebug_device_logs`를 본다.

### 이 저장소에서 작업하기

- 요구 사항: Apple silicon Mac, Xcode, Go, XcodeGen. 앱을 빌드하기 전에 `scripts/build-core.sh`로 Go 코어를 `Packages/RDCore/RDCore.xcframework`로 만든다.
- 시험: `swift test --package-path Packages/PhoneClient`, `swift test --package-path Packages/RemoteDebugKit`, `RD_TEST_TMPDIR=<쓰기 가능한 폴더> swift test --package-path Packages/MacHost`, `scripts/go.sh test -race -count=1 ./...`. 나머지는 [설정 문서](docs/setup.md#명령줄-빌드와-시험)에 있다.
- `README.md`, `README.ko.md`, `docs/`를 고친 뒤에는 `scripts/check-docs.sh`가 통과해야 한다.
- 문서가 서로 다르면 `docs/tunnel.md`, `docs/protocol-addenda.md`, `docs/protocol.md` 순서로 따른다(아래 자세히).
- iPhone 번들 ID는 `Config/Signing.xcconfig`의 `RD_BUNDLE_PREFIX`로 시작한다. 터널 확장 ID는 늘 앱 ID에 `.Tunnel`을 붙인 값이다.

## 하는 일

- **빌드와 게시**: 프로젝트 폴더나 `.xcodeproj`, `.xcworkspace`를 Mac 창이나 Dock 아이콘에 끌어 놓으면 스킴을 읽고 `xcodebuild`로 Debug 기기용 빌드를 만들어 게시한다. 연결한 프로젝트는 목록에 남고, Xcode에서 기기용 Debug로 빌드할 때마다 결과를 자동으로 가져온다. 창을 닫아도 메뉴 막대에 남는다.
- **iPhone에 설치**: iPhone 앱이 게시된 빌드를 앱별로 묶어 아이콘과 함께 보여 주고 설치한다. 다른 앱의 무선 설치는 실제 iPhone에서 확인했다.
- **iPhone 앱 자체 설치**: Mac의 **iPhone 앱 설치…**가 이 저장소의 iPhone 앱을 사용자의 서명 팀으로 빌드해 케이블로 연결한 iPhone에 설치한다([설정 문서](docs/setup.md#mac-앱으로-iphone-앱-설치)).
- **iPhone 앱 업데이트**: RemoteDebug 앱은 자기 VPN으로는 스스로 업데이트하지 못한다. 설치 중에 iOS가 터널을 멈추기 때문이다. 대신 Mac이 공식 Tailscale 앱을 거치는 업데이트 페이지를 내준다([설정 문서](docs/setup.md#iphone-앱-업데이트)).
- **페어링**: Mac 앱의 QR을 찍고 Mac에서 허용한다. 선택 기능으로 Tailscale OAuth 클라이언트를 넣으면 QR에 1회용 Tailscale 키가 들어가 iPhone이 로그인 없이 연결된다([설정 문서](docs/setup.md#qr-한-번으로-연결tailscale-oauth-클라이언트)). iPhone이 Mac과 다른 tailnet에 로그인했으면 앱이 알려 주고 **다른 계정으로 로그인**을 제안한다([설정 문서](docs/setup.md#mac과-다른-계정으로-로그인했을-때)).
- **파일과 링크**: Mac의 **보낸 파일** 화면에 파일을 끌어 놓거나 에이전트가 보내면, iPhone이 백그라운드에서 받아 파일 앱이나 공유 시트로 넘긴다([설정 문서](docs/setup.md#mac에서-iphone으로-파일-보내기)).
- **진단 로그**: iPhone 앱이 로그를 쌓아 Mac에 보내고, Mac의 **iPhone 로그** 화면에서 본다.
- **크래시 기록**: iPhone 앱이 비정상 종료되면 다음 실행 때 기록을 Mac에 보낸다. 다른 앱의 기록은 iPhone 설정 > 개인정보 보호 및 보안 > 분석 및 향상 > 분석 데이터에서 열어 공유로 RemoteDebug에 넘긴다. iPhone 앱의 설정과 Mac의 **크래시** 화면에서 보고 공유한다.
- **설치된 버전**: iPhone 빌드 목록에 그 앱이 지금 어떤 버전으로 설치돼 있는지 보인다(iOS 비공개 API를 써서 읽지 못하는 기기에서는 보이지 않는다).
- **iPhone 앱 없이 설치**: Mac은 `https://<Mac의 FQDN>/`에서 설치 웹 페이지도 내준다. 공식 Tailscale 앱을 켠 iPhone이 Safari로 열어 페어링 코드를 넣고, Mac에서 허용받은 뒤 설치한다. 실제 iPhone에서는 아직 열어 보지 않았다([설정 문서](docs/setup.md#iphone에서-앱-없이-설치웹-페이지)).
- **시작하기**: Mac 빌드 화면의 **시작하기** 목록이 순서를 보여 준다. Tailscale 연결, 설치 주소 열기, iPhone 연결, 첫 빌드 게시.

## 빠른 시작

```sh
scripts/build-core.sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig   # DEVELOPMENT_TEAM을 넣는다
xcodegen generate --spec project.yml
open RemoteDebug.xcodeproj
```

1. 스킴 `RemoteDebugMac`을 Mac에서 실행하고 **공유 시작**을 누른다. 열리는 브라우저 창에서 Tailscale에 로그인한다. tailnet의 MagicDNS와 HTTPS 인증서가 켜져 있어야 한다.
2. iPhone을 케이블로 연결하고 **기기** 화면의 **iPhone 앱 설치…**를 쓰거나, Xcode에서 스킴 `RemoteDebugPhone`을 실행한다. VPN 권한 때문에 유료 Apple Developer Program 팀이 필요하다.
3. iPhone 앱에서 VPN을 켜고 Mac과 같은 Tailscale 계정으로 로그인한다. Mac의 페어링 QR을 찍고 Mac에서 허용한다.
4. Xcode 프로젝트를 Mac 창에 끌어 놓는다. iPhone에서 **설치**를 누른다.

빌드 스크립트는 `eyebuild` 명령을 부르므로, 없으면 [대체 스크립트](docs/setup.md#eyebuild가-없는-mac)를 먼저 만든다. tailnet 정책, 서명, 문제 해결은 [설정 문서](docs/setup.md)에 있다.

## 앱의 크래시와 피드백 받기

RemoteDebug로 설치한 앱에서 생긴 문제를 Mac에서 바로 볼 수 있다. 받은 것은 Mac 앱의 **크래시·피드백** 화면과 에이전트 도구 `remotedebug_crash_logs`에 모인다.

- RemoteDebug iPhone 앱: 비정상 종료되면 다음 실행 때 기록을 보낸다. 설정 > 크래시·피드백에서 피드백을 적어 보낼 수 있다.
- 내 앱: 저장소 주소(`https://github.com/oozoofrog/remotedebug`)를 Swift 패키지로 추가해 `RemoteDebugFeedback`을 넣는다. Mac 앱의 프로젝트 화면에서 **추가 방법**을 누르면 Mac 주소가 든 코드가 나온다.

```swift
import RemoteDebugFeedback

RemoteDebugFeedback.start(.init(
    macHost: "<Mac 주소>",              // RemoteDebug로 설치한 빌드가 Mac으로 바로 보낸다
    email: "<받을 메일 주소>",           // 선택. Mac에 닿지 않을 때와 배포 빌드의 경로
    publicKeyBase64: "<공개키>"         // 선택. Debug 빌드가 메일에 로그·화면 사진을 암호화해 붙인다
))
.remoteDebugFeedback(isPresented: $showsFeedback)      // 글, 화면 사진, 최근 로그를 받는 피드백 화면
```

- 메일로 온 암호화 첨부(`.afdiag`)는 Mac 앱의 **크래시·피드백** 화면에 끌어다 놓으면 풀린다. 키는 그 Mac의 키체인에만 있다.
- 패키지는 iOS 17 이상이다.

- 패키지를 넣지 않은 앱: iPhone 빌드 목록의 **크래시 기록**에서 iPhone 설정을 열고, 분석 데이터의 `.ips` 파일을 공유로 RemoteDebug에 넘긴다.

보낼 때는 iPhone에서 RemoteDebug 앱의 VPN이 켜져 있어야 한다. 꺼져 있으면 앱이 저장해 두었다가 다음에 보낸다. 패키지를 넣은 다른 앱이 실제 iPhone에서 Mac까지 보내는 것은 아직 확인하지 않았다.

## 현재 상태

"확인함"은 그 행에 적은 범위까지만 뜻한다. 실기기 확인은 2026-11-12에 iPhone 한 대(iOS 27.2)로 했다.

| 범위 | 상태 | 재현 방법 |
| --- | --- | --- |
| Go 코어: 페어링·세션·IPA 제공을 가짜 tailnet(`testcontrol`)으로 | 확인함 | `scripts/go.sh test -race -count=1 ./...` |
| Go 코어 터널 모드: 가짜 tailnet과 메모리 TUN으로 | 확인함 | `scripts/go.sh test -race -count=1 -run TestTunnel -v ./...` |
| `RDCore.xcframework` 생성(macOS, iOS, iOS 시뮬레이터 arm64) | 확인함 | `scripts/build-core.sh` |
| 디버그 빌드 검사와 IPA 묶기: 단위 시험, 픽스처, 작성 환경의 실제 Debug 빌드 | 확인함 | `swift test --package-path Packages/RemoteDebugKit`, `scripts/check-ipa-roundtrip.sh`, `scripts/check-real-builds.sh` |
| Mac 호스트: 실제 Go 코어와 가짜 tailnet, 앱 실행과 종료 | 확인함 | `RD_TEST_TMPDIR=<쓰기 가능한 폴더> swift test --package-path Packages/MacHost`, `RD_E2E_APP=1 scripts/e2e-mac.sh` |
| iPhone 로직과 앱: 단위 시험, 시뮬레이터 빌드·시험, 기기용 컴파일(서명 없음) | 확인함 | `swift test --package-path Packages/PhoneClient`, [설정 문서의 xcodebuild 명령](docs/setup.md#명령줄-빌드와-시험) |
| Mac과 iPhone 로직의 통합 흐름: 가짜 tailnet으로 페어링·목록·설치 세션·기기 제거 | 확인함 | `scripts/e2e-full.sh` |
| 프로젝트 연결 로직(프로젝트 찾기, 스킴, 가짜 빌더, DerivedData 등록 제안, 에이전트 명령, 스킬·`AGENTS.md`) | 확인함 | `RD_TEST_TMPDIR=<쓰기 가능한 폴더> swift test --package-path Packages/MacHost` |
| 실제 iPhone의 RemoteDebug 앱: 내장 Tailscale 로그인, VPN, 페어링, 빌드 목록, 다른 앱 설치(실제 TLS, `itms-services`), 진단 로그, 파일 받기 | 일부 확인함 | 작성자가 사용함. 큰 파일은 앱이 백그라운드로 가면 끊겼고, 백그라운드 받기 수정은 확인하지 않음. [실기기 확인 절차](docs/device-test.md)를 모두 거치지는 않음 |
| RemoteDebug 앱이 자기 VPN으로 스스로 업데이트 | 실패 | 설치 중에 iOS가 터널을 멈춘다. 공식 Tailscale 앱을 거치는 업데이트 페이지를 쓴다 |
| 공식 Tailscale 앱으로 내보낸 페이지(`tailscale serve`)에서 iPhone 앱 설치 | 앞서 손으로 만든 페이지로 확인함 | 지금 Mac 앱의 업데이트 페이지를 실제 iPhone에서 쓴 기록은 없음 |
| Mac 앱 화면을 직접 조작: 공유 시작, 페어링 시트, 요청 허용, 네트워크 화면, 설치 창 | 일부 확인함 | 창 캡처와 손쉬운 사용 클릭. VoiceOver, 다크 모드, 다이내믹 타입은 보지 않음 |
| Mac 앱이 실제 `xcodebuild`로 다른 프로젝트 빌드 | 확인함 | 작성자의 에이전트가 게시한 빌드 |
| Xcode 빌드 감지와 알림, 메뉴 막대 상주와 로그인 항목, Dock 아이콘에 끌어 놓기 | 확인하지 않음 | 절차 없음 |
| 설치 웹 페이지: Go 시험, JavaScriptCore의 `logic.js`, 가짜 tailnet의 WKWebView E2E | 확인함 | `scripts/go.sh test -race -count=1 ./...`, `swift test --package-path Packages/WebPage`, `scripts/e2e-web.sh` |
| 설치 웹 페이지를 공식 Tailscale 앱으로 실제 iPhone의 Safari에서 열기 | 확인하지 않음 | [D14](docs/device-test.md#d14-설치-웹-페이지공식-tailscale-앱) |
| 페어링 QR의 1회용 Tailscale 키(OAuth 클라이언트, 실제 Tailscale API) | 확인하지 않음 | 가짜 API로 로직만 시험 |
| Mac 앱이 케이블로 연결한 iPhone에 iPhone 앱 설치 | 확인하지 않음 | 가짜 도구로 로직 시험, 앞부분별 번들 ID는 `xcodebuild -showBuildSettings`로 확인 |
| 실제 iPhone에서 **다른 계정으로 로그인** | 확인하지 않음 | 시뮬레이터에서 초기화 옵션만 시험 |
| Debug 확인 대화상자 | 확인하지 않음 | [D13](docs/device-test.md#d13-debug-확인-대화상자) |
| Network Extension 한도(메모리, 경로, DNS 세부) | 확인하지 않음 | [실기기 확인 절차](docs/device-test.md) |
| 감시 폴더의 실제 FSEvents, 다시 실행한 뒤 감시 폴더 다시 열기 | 확인하지 않음 | 시험은 FSEvents를 끄고 돌렸다 |
| 몇 시간 이상 이어지는 연결, Mac 재시동 뒤 다시 쓰기 | 확인하지 않음 | 절차 없음 |
| iPhone 앱의 Xcode 캔버스 미리보기 | 렌더링 실패 | 아래 "알려진 한계와 문제" |

## 구성과 문서

| 구분 | 이름 | 위치 | 내용 |
| --- | --- | --- | --- |
| 대상 | `RemoteDebugMac` | `Apps/Mac` | Mac 앱의 진입점과 수명 주기 |
| 대상 | `RemoteDebugPhone` | `Apps/iOS` | iPhone 앱 화면과 VPN 관리 |
| 대상 | `RemoteDebugTunnel` | `Apps/iOSTunnel` | 패킷 터널 확장 |
| 대상 | `RemoteDebugWidgets` | `Apps/iOSWidgets` | 파일 전송 라이브 액티비티 |
| 패키지 | `RemoteDebugKit` | `Packages/RemoteDebugKit` | 공용 모델, 디버그 빌드 검사, IPA와 매니페스트 생성, `rdvalidate` |
| 패키지 | MacHost | `Packages/MacHost` | `MacHostKit`(로직), `MacHostCore`(Go 코어 연결), `MacHostUI`(화면과 미리보기, Go 런타임 없음) |
| 패키지 | PhoneClient | `Packages/PhoneClient` | iPhone 앱 로직 `PhoneClientKit` |
| 패키지 | RDCore | `Packages/RDCore` | `RDCore.xcframework`와 Swift 브리지 `RDCoreBridge` |
| 패키지 | E2E | `Packages/E2E` | Mac과 iPhone 로직의 통합 시험, 설치 웹 페이지의 브라우저 엔진 시험. 제품 코드 없음 |
| 패키지 | WebPage | `Packages/WebPage` | 설치 웹 페이지 로직의 JavaScriptCore 시험. 제품 코드 없음 |
| 코어 | Go | `core/` | Tailscale 노드, 호스트 HTTP 서버, 터널 모드, 업데이트 페이지, C API |
| 코어 | 설치 웹 페이지 | `core/internal/host/web` | Mac 호스트가 `/`에서 내주는 HTML·CSS·JS(코어에 들어 있다) |
| 스크립트 | | `scripts/` | 코어 빌드, 시험, 문서 검사 |

| 문서 | 내용 |
| --- | --- |
| [docs/setup.md](docs/setup.md) | 요구 사항, 서명, 빌드, 첫 실행, iPhone 앱 설치, 페어링, 파일, 업데이트, 문제 해결 |
| [docs/device-test.md](docs/device-test.md) | 실기기 확인 절차 |
| [docs/device-test-results.md](docs/device-test-results.md) | 실기기 확인 결과 기록표 |
| [docs/protocol.md](docs/protocol.md) | Mac·iPhone·코어 사이의 프로토콜 v1 |
| [docs/protocol-addenda.md](docs/protocol-addenda.md) | `docs/protocol.md`를 고치고 더하는 규칙: 설치 웹 페이지(E), 아이콘(F), 로그(G), 파일(H), 업데이트 페이지(I), 페어링 링크의 Tailscale 키(J) |
| [docs/tunnel.md](docs/tunnel.md) | iPhone 패킷 터널 |
| [docs/architecture.md](docs/architecture.md) | 구조와 초기 가정. 틀린 문장은 아래 "문서 정정" |
| [docs/appstore-review.md](docs/appstore-review.md) | App Store 제출 판정 |

문서가 서로 다르면 이 순서로 따른다.

1. `docs/tunnel.md`: `docs/protocol.md`의 §6 전체, §9의 프록시 관련 부분(`mode`가 `host`/`proxy`뿐이라는 문장, iPhone 쪽 `rd_proxy_start` 사용), `docs/architecture.md`의 가정 A1과 구성도를 대체한다.
2. `docs/protocol-addenda.md`: 터널이 다루지 않는 부분에서 `docs/protocol.md`보다 앞선다.
3. `docs/protocol.md`, `docs/architecture.md`의 나머지 부분. 단, 아래 "설계 문서와 달라진 구현"과 "문서 정정"에 적은 내용은 그 표를 따른다.

## App Store 판정

제출하지 않는다. iPhone 앱은 다른 앱의 설치를 요청하는 기능 때문에 지침 2.5.2에 걸리고, VPN 앱으로 보면 5.4의 조직 계정·고지 의무가 따르며, 심사자가 Mac·tailnet·개발 프로비저닝 없이는 핵심 기능을 볼 수 없어 승인 가능성이 매우 낮다고 판단했다. Mac 앱 단독 제출도 4.2.3(i)와 심사자 접근 때문에 권하지 않는다. 권장 배포는 Xcode 직접 설치나 Ad Hoc이고, TestFlight는 권하지 않는다. 판정은 이 프로젝트 구조를 바탕으로 한 추정이며 Apple의 실제 심사 결과가 아니다. 근거와 인용은 [판정서](docs/appstore-review.md)에 있다.

## 알려진 한계와 문제

- Apple silicon 전용이다. `RDCore.xcframework`의 슬라이스가 모두 arm64다.
- iPhone 앱의 VPN 권한(Network Extension) 때문에 유료 Apple Developer Program 팀이 필요하다.
- iOS는 VPN을 한 번에 하나만 켠다. RemoteDebug VPN이 켜진 동안 공식 Tailscale VPN은 꺼지고, 반대도 같다.
- RemoteDebug iPhone 앱은 자기 VPN으로 스스로 업데이트하지 못한다. 공식 Tailscale 앱을 거치는 업데이트 페이지를 쓰거나 Mac에서 케이블로 설치한다.
- `docs/tunnel.md`의 실기기 미확인 항목 9개가 남아 있다. [실기기 확인 절차](docs/device-test.md)의 U1~U9에 같은 번호로 있다.
- iPhone 앱의 Xcode 캔버스 미리보기는 작성 환경에서 `Timed out waiting for signal to perform the initial JIT link`로 실패한다. 원인은 확인하지 못했다. 시뮬레이터 실행과 시험은 정상이다.
- Mac 앱의 미리보기는 렌더링되지만, 공유를 시작하는 시나리오는 진행 표시만 찍힐 수 있다.
- iPhone을 백업에서 복원하면 터널 상태 폴더가 백업에서 빠져 있어 tailnet 로그인과 페어링을 다시 해야 한다. 실기기에서 확인하지 않음([D6](docs/device-test.md#d6-백업에서-복원)).
- Mac도 노드 상태 폴더(`state`)와 `identity.json`을 Time Machine 백업과 마이그레이션에서 뺀다. 복원하거나 옮긴 Mac은 새 노드(`rd-mac-<새 8자>`)로 다시 로그인하고, 모든 iPhone이 다시 페어링해야 한다. 실제 복원으로는 확인하지 않음.
- 폴더 이름이나 `*.debug.dylib`로 Debug 구성을 증명할 수 없는 빌드는 대화상자에서 확인하면 게시된다. 확인한 뒤 바뀌었는지는 `.app`이면 파일 메타데이터(경로·종류·크기·수정 시각·inode)로, `.ipa`면 SHA-256으로 비교한다. `.app` 비교는 내용 해시가 아니다.
- 페어링 코드를 다섯 번 틀리면 코어는 코드를 폐기하지만 `denied` 이벤트가 5초에 하나로 제한되어, Mac 화면은 다음 이벤트가 올 때까지 폐기된 코드를 보여 줄 수 있다. **새 코드 만들기**로 새 코드를 연다.
- 가져오는 중에 Mac 앱을 종료하면 저장 폴더 잠금이 풀린 뒤에도 파일을 쓸 수 있다. 가져오기가 끝난 뒤 종료하고 바로 다시 열지 않는다.
- 두 앱 모두 VoiceOver, 다크 모드, 다이내믹 타입으로 확인하지 않았다.
- Mac 앱은 App Sandbox를 쓰지 않는다. 저장 폴더가 샌드박스 컨테이너에서 `~/Library/Application Support/RemoteDebug`로 바뀌었고, 옮겨 주는 코드는 없다.
- Mac 앱이 시작한 프로젝트 빌드는 `-allowProvisioningUpdates`를 주지 않는다. 프로필이 없거나 기기가 등록되지 않은 프로젝트는 Xcode에서 한 번 기기용으로 빌드해야 한다. iPhone 앱 자체 설치는 이 옵션을 준다.
- Xcode 빌드는 DerivedData의 `info.plist`(`WorkspacePath`)와 Xcode의 빌드 위치 설정(기본, 또는 Custom > Relative to Workspace)으로 찾는다. 그 밖의 빌드 위치 설정은 찾지 못한다.
- Xcode 빌드 감지는 3초마다 `Build/Products/Debug-iphoneos`와 빌드 기록을 보는 방식이라, 빌드가 시작한 순간이 아니라 그 폴더가 바뀐 뒤에 묻는다.
- 에이전트 명령(`~/Library/Application Support/RemoteDebug/agent/rd`)은 같은 사용자 계정의 어떤 프로세스든 쓸 수 있고, 페어링 요청 허용도 할 수 있다.
- 설치 웹 페이지의 허용 단위는 브라우저가 아니라 iPhone의 tailnet 노드다. 한 번 허용하면 그 iPhone의 모든 앱이 Mac에 닿는다. 끊으려면 Mac의 **기기** 화면에서 그 기기를 제거한다.
- 설치 웹 페이지는 iPhone의 공식 Tailscale VPN과 tailnet의 HTTPS 인증서가 켜져 있어야 열린다. tailnet 정책이 그 iPhone 노드에서 Mac의 443 포트를 막으면 열리지 않는다([설정 문서의 ACL 설명](docs/setup.md#tailnet-정책acl)).
- 설치 웹 페이지를 새로고침하면 진행 중이던 설치의 확인을 이어 가지 않는다. Mac의 설치 세션은 제한 시간이 지나면 스스로 만료된다.

## 설계 문서와 달라진 구현

근거의 숫자는 `.agent-loop/remotedebug-bridge/decisions.jsonl`의 줄 번호다.

| 설계 문서 | 현재 구현 | 근거 |
| --- | --- | --- |
| `docs/architecture.md` 구성도·가정 A1: 터널 확장의 로컬 CONNECT 프록시 | IP 패킷을 tailnet으로 중계하는 패킷 터널([`docs/tunnel.md`](docs/tunnel.md)). Apple TN3120이 패킷 터널 안의 리스너·프록시를 권장하지 않는다 | 5, 26 |
| `docs/protocol.md` §6: iPhone이 호스트별 `allowedTargets`를 터널에 설정 | 설정 없음. 패킷 터널에는 호스트별 허용 목록이 없어 다른 Mac 링크는 확인 후 교체한다 | 20 |
| `docs/architecture.md:53`: 화면을 Mac 앱 대상에 둠 | 화면과 미리보기는 `MacHostUI`(Go 런타임 없음). 앱 실행 파일의 Go 런타임이 Xcode 미리보기를 충돌시켰다 | 33, 34, 41 |
| `docs/protocol.md` §5: 허용 기기 저장 | 승인한 제어 서버 URL에 묶는다. 서버를 바꾸면 확인 후 다시 페어링한다 | 34, 43 |
| `docs/protocol.md:3`: 바꿀 때 이 문서를 먼저 고친다 | 바뀐 규칙은 [`docs/protocol-addenda.md`](docs/protocol-addenda.md)에 있다. 둘이 다르면 addenda를 따른다 | 6 |
| `docs/architecture.md:5`: 각 앱에 내장한 Tailscale만으로 설치 | 내장 경로는 그대로 두고, 공식 Tailscale 앱만 있는 iPhone이 Safari로 여는 설치 웹 페이지를 사용자 요청으로 더했다([`docs/protocol-addenda.md`](docs/protocol-addenda.md) E) | 61, 62, 63, 64, 65 |
| `docs/architecture.md:86`: Xcode·TestFlight 내부 배포 | Xcode 직접 설치나 Ad Hoc. [판정서](docs/appstore-review.md)가 TestFlight를 권하지 않는다(지침 2.2) | 2 |
| `docs/appstore-review.md`의 2.4.5 해석: 샌드박스 호환, 로그인 시 자동 실행 없음 | App Sandbox를 쓰지 않고 연결한 프로젝트를 `xcodebuild`로 빌드한다. 메뉴 막대에 상주하고 로그인할 때 열 수 있다. 사용자 요청이며 Mac App Store 판단은 이 변경을 반영하지 않았다 | 기록 없음(2026-11-11 사용자 요청) |
| `docs/architecture.md` 가정 A3: App Sandbox를 켠 Mac 앱 | 같은 표의 대안("비샌드박스 배포로 전환")을 택했다 | 기록 없음(2026-11-11 사용자 요청) |

설계 문서에 없는 현재 동작:

- iPhone 터널은 tailnet 접미사와 역방향 영역만 `100.100.100.100`으로 보내고 기기 전체 DNS는 가로채지 않는다(19, 26).
- 팀 ID는 `Config/Signing.local.xcconfig`에 둔다. `Config/Signing.xcconfig`가 읽으므로 `xcodegen`을 다시 돌려도 남는다(38, 39).
- Debug 확인은 `.app`이면 번들 트리의 메타데이터 지문(내용 해시 아님), `.ipa`면 SHA-256에 묶는다. 번들 ID·버전·빌드 번호도 같아야 게시한다(40, 43).
- 노드 키가 든 상태 폴더는 백업에서 뺀다(31, 34, 35).
- Mac 앱은 저장 폴더 잠금으로 한 번에 하나만 실행된다(34, 44).
- 로직은 `MacHostKit`, `PhoneClientKit`에 있어 앱 서명 없이 `swift test`로 시험한다(14, 15).
- 대상 설정은 `Apps/Mac/project-mac.yml`, `Apps/iOS/project-ios.yml`에 있고 루트 `project.yml`이 두 파일을 포함한다(25).
- Mac 앱은 `ARCHS=arm64`로만 빌드한다(10).
- 통합 시험은 `Packages/E2E`와 `scripts/e2e-full.sh`다(29, 46).

## 문서 정정

아래 문장은 구현과 다르다. 해당 문서는 고치지 않았으므로 오른쪽 열을 따른다.

| 위치 | 문서의 문장 | 맞는 내용 |
| --- | --- | --- |
| `docs/architecture.md:84` | "iOS 자체도 배포 서명 IPA의 OTA 설치를 받지 않는다" | iOS는 Ad Hoc·Enterprise 서명 IPA도 OTA로 설치한다. Debug 한정은 Mac 앱의 검사(개발 프로필, `get-task-allow`, Debug 구성)와 코어의 게시 시 재확인(`debug`, `getTaskAllow`, 크기·SHA-256)으로 막는다 |
| `docs/architecture.md:85` | "비밀(인증 키)은 Keychain에만 저장" | Tailscale 인증 키는 저장하지 않는다. 입력한 키는 다음 시작 한 번에만 코어로 넘긴다. 선택 기능인 Tailscale OAuth 클라이언트는 Mac 키체인에 저장한다. 노드 상태(노드 키)는 `stateDir`에 남고 그 폴더는 백업에서 뺀다 |
| `docs/protocol.md:11` | 클라이언트: "iPhone 앱. 패킷 터널 확장 안의 tsnet 노드로 tailnet에 올라 호스트를 호출한다." | 클라이언트는 iPhone 앱이거나, Safari에서 연 설치 웹 페이지(`platform` 값 `Web`)다 |
| `docs/protocol.md:17` | "노드 이름은 `rd-mac-<id8>`, `rd-phone-<id8>`이다." | RemoteDebug 앱의 노드만 그렇다. 설치 웹 페이지로 페어링한 iPhone은 공식 Tailscale 앱의 노드 이름을 쓴다 |
| `docs/protocol.md:376` | "tailnet ACL 태그(`tag:rd-mac`, `tag:rd-phone`)로 `tcp:443`만 허용하면 네트워크 층에서도 한 번 더 막을 수 있다" | 이 태그 규칙만 남기면 공식 Tailscale 앱을 쓰는 iPhone(`tag:rd-phone`이 없는 사용자 노드)은 Mac에 닿지 못한다. [설정 문서의 ACL 설명](docs/setup.md#tailnet-정책acl)을 따른다 |

## 문서 검사

```
사용: scripts/check-docs.sh [--help]   (RD_QUOTES_CACHE_DIR=<폴더>를 주면 Apple 원문 사본으로 인용을 검사한다)
```

다음이 저장소와 다르면 어긋난 곳마다 한 줄을 출력하고 종료 코드 1로 끝난다: 코드 조각과 코드 블록(json 제외)의 경로(`scripts/`, `docs/`, `Packages/`, `Apps/`, `core/`, `Config/`, `.agent-loop/` 아래와 `project.yml` 같은 루트 파일), 문서에 적은 스크립트, 대상·스킴·모듈·번들 ID 이름, U 항목과 `docs/tunnel.md`의 실기기 항목, D 항목과 실행 순서 표, 상대 링크와 `#` 제목 앵커, 설치 웹 페이지 절차(`docs/setup.md`의 웹 페이지 절, `docs/device-test.md`의 D14)에 굵은 글씨나 큰따옴표로 적은 화면 문구(페이지 소스 `core/internal/host/web`, Mac 앱 소스 `Packages/MacHost/Sources`와 글자 그대로 비교). 필요한 문서나 `scripts/check_quotes.py`, `scripts/check_protocol_examples.py`가 없어도 실패한다. 코드 조각 밖 본문의 경로는 검사하지 않는다. Apple 원문을 받지 못하면 인용 검사는 경고만 남긴다.
