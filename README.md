# RemoteDebug

Mac 앱은 Debug(개발 서명) 빌드를 검사해 게시하고, 페어링한 iPhone은 그 빌드를 받아 iOS 설치기로 설치한다. 두 앱 모두 Tailscale을 내장해서 이 경로에는 별도의 Tailscale 앱이 필요 없다. 허용한 기기만 접근할 수 있고, 개발 서명 빌드만 게시한다. Debug 구성은 빌드 폴더 이름(`Debug-iphoneos`)이나 앱 안의 `*.debug.dylib`로 확인하고, 둘 다 없으면 사용자가 대화상자에서 Debug라고 확인해야 게시한다.

RemoteDebug iPhone 앱 없이 설치하는 두 번째 경로도 있다. Mac 호스트가 `https://<Mac의 FQDN>/`에서 설치 웹 페이지를 내주고, 공식 Tailscale 앱으로 같은 tailnet에 접속한 iPhone이 Safari로 그 페이지를 열어 페어링 코드를 넣고, Mac 앱에서 허용받은 뒤 빌드를 설치한다. 허용한 기기만, Debug 빌드만, 허용은 Mac 화면에서만이라는 규칙은 앱 경로와 같다. 실제 iPhone의 Safari에서는 한 번도 열어 보지 않았다. 절차는 [설정 문서](docs/setup.md#iphone에서-앱-없이-설치웹-페이지), 규칙은 [`docs/protocol-addenda.md`](docs/protocol-addenda.md)의 E에 있다.

다른 프로젝트는 Mac 앱에 연결해서 쓴다. 프로젝트 폴더나 `.xcodeproj`, `.xcworkspace`를 창이나 Dock 아이콘에 끌어 놓으면 앱이 스킴을 읽고 `xcodebuild`로 Debug 기기용 빌드를 만들어 게시한다. 연결한 프로젝트는 목록에 남고, Xcode에서 그 프로젝트를 기기용 Debug로 빌드할 때마다 결과를 자동으로 가져온다. 연결하지 않은 프로젝트의 기기용 Debug 빌드가 Xcode에서 보이면 등록할지 묻는다. 앱은 창을 닫아도 메뉴 막대에 남는다. 프로젝트 행의 **에이전트 연결…**은 그 프로젝트에 Claude 스킬과 `AGENTS.md` 단락을 써서 에이전트가 빌드·게시 명령을 쓰게 한다. 순서는 [설정 문서의 프로젝트 절](docs/setup.md#다른-프로젝트-연결)에 있다. Mac은 게시까지만 하고, 설치는 iPhone에서 누른다.

## 현재 상태

실기기, 실제 tailnet, 실제 TLS 인증서, 실제 iOS 설치기에서는 아무것도 시험하지 않았다. 실행 중인 두 앱의 화면을 직접 조작해 보지도 않았다. 아래 "확인함"은 표에 적은 범위까지만 뜻한다.

| 범위 | 상태 | 재현 명령 |
| --- | --- | --- |
| Go 코어: 페어링·세션·IPA 제공을 가짜 tailnet(`testcontrol`)으로 | 확인함 | `scripts/go.sh test -race -count=1 ./...` |
| Go 코어 터널 모드: 가짜 tailnet과 메모리 TUN으로 | 확인함 | `scripts/go.sh test -race -count=1 -run TestTunnel -v ./...` |
| `RDCore.xcframework` 생성(macOS, iOS, iOS 시뮬레이터 arm64) | 확인함 | `scripts/build-core.sh` |
| 디버그 빌드 검사와 IPA 묶기: 단위 시험, 픽스처, 작성 환경의 실제 Debug 빌드 | 확인함 | `swift test --package-path Packages/RemoteDebugKit`, `scripts/check-ipa-roundtrip.sh`, `scripts/check-real-builds.sh` |
| Mac 호스트: 실제 Go 코어와 가짜 tailnet, 앱 실행과 종료 | 확인함 | `RD_TEST_TMPDIR=<쓰기 가능한 폴더> swift test --package-path Packages/MacHost`, `RD_E2E_APP=1 scripts/e2e-mac.sh` |
| iPhone 로직과 앱: 단위 시험, 시뮬레이터 빌드·시험, 기기용 컴파일(서명 없음) | 확인함 | `swift test --package-path Packages/PhoneClient`, [설정 문서의 xcodebuild 명령](docs/setup.md#명령줄-빌드와-시험) |
| Mac과 iPhone 로직의 통합 흐름: 가짜 tailnet으로 페어링·목록·설치 세션·기기 제거 | 확인함 | `scripts/e2e-full.sh` |
| 프로젝트 연결 로직: 폴더에서 프로젝트 찾기, 스킴 목록 해석, 가짜 빌더로 빌드 뒤 가져오기, DerivedData 변화로 등록 제안, 에이전트 명령 스크립트 왕복, 스킬·`AGENTS.md` 쓰기 | 확인함 | `RD_TEST_TMPDIR=<쓰기 가능한 폴더> swift test --package-path Packages/MacHost` |
| 프로젝트 연결을 실제로 쓰기: 실제 `xcodebuild`로 다른 프로젝트 빌드, Xcode가 빌드를 시작한 시점의 감지와 시스템 알림, 메뉴 막대 상주와 로그인 항목, Dock 아이콘에 끌어 놓기, 프로젝트 화면 조작 | 확인하지 않음 | 절차 없음 |
| 화면 상태별 표시: 미리보기 시나리오 데이터를 저장소 밖 도구로 오프스크린에 그린 스크린샷 검토(Mac 10장, iPhone 18개 상태). 실제 앱 화면은 iPhone 시뮬레이터 첫 화면 1장뿐이다. VoiceOver, 다크 모드, 다이내믹 타입은 보지 않았다 | 확인함 | 재현 명령 없음(그린 도구가 저장소에 없다). 결과 `.agent-loop/remotedebug-bridge/evidence/ui/`, 방법 `.agent-loop/remotedebug-bridge/evidence/mac-app-a2-ui-smoke.log`, `.agent-loop/remotedebug-bridge/evidence/phone-app-a1-ui-smoke.log` |
| 설치 웹 페이지 Go 시험: 경로·보안 헤더·404·405·`denied` 이벤트 없음, 가짜 tailnet에서 허용 목록 밖 기기가 페이지를 받고 페어링 뒤 목록과 설치 세션을 여는 흐름 | 확인함 | `scripts/go.sh test -race -count=1 ./...` |
| 설치 웹 페이지 로직(`logic.js`)과 화면 도움 함수: JavaScriptCore 시험, 규칙과 문구를 iPhone 앱 로직과 비교 | 확인함 | `swift test --package-path Packages/WebPage` |
| 설치 웹 페이지 브라우저 엔진 E2E: WKWebView로 실제 Go 코어와 Mac 호스트 로직, 가짜 tailnet | 확인함 | `scripts/e2e-web.sh` |
| 설치 웹 페이지와 Mac 화면 연결의 독립 코드 검토(HTTP 보안, 페이지 JS, 앱과의 규칙 일치, 시험, Mac 화면, 명세) | 확인함 | 재현 명령 없음. 기록 `.agent-loop/remotedebug-bridge/decisions.jsonl` 65줄. 지적 사항의 처리 결과와 남긴 위험은 68~70줄 |
| 설치 웹 페이지를 실제 iPhone의 Safari에서 열기, 실제 TLS 인증서로 접속, 공식 Tailscale 앱으로 접속, Safari에서 `itms-services` 설치 창 열기 | 확인하지 않음 | [D14](docs/device-test.md#d14-설치-웹-페이지공식-tailscale-앱) |
| 실기기 설치와 실행 | 확인하지 않음 | [실기기 확인 절차](docs/device-test.md) |
| 실제 tailnet 로그인과 연결 | 확인하지 않음 | [실기기 확인 절차](docs/device-test.md) |
| 실제 TLS 인증서 발급과 HTTPS 제공 | 확인하지 않음 | [실기기 확인 절차](docs/device-test.md) |
| 실제 iOS 설치기(`itms-services`) | 확인하지 않음 | [실기기 확인 절차](docs/device-test.md) |
| Network Extension 동작(utun, 경로, DNS, 메모리 한도) | 확인하지 않음 | [실기기 확인 절차](docs/device-test.md) |
| 실행 중인 Mac 앱을 손으로 조작하기(공유 시작, 빌드 가져오기, 페어링 시트, 페어링 시트의 "앱 없이 Safari로 설치", 네트워크 화면의 "설치 페이지", 기기 제거) | 확인하지 않음 | [실기기 확인 절차](docs/device-test.md)의 D9(공유 시작), D1(가져오기), D12(페어링 시트), D14(설치 페이지 링크), D11(기기 제거)에서 함께 본다 |
| Debug 확인 대화상자(폴더 이름과 `*.debug.dylib` 어느 쪽으로도 Debug를 증명하지 못하는 빌드) | 확인하지 않음 | [D13](docs/device-test.md#d13-debug-확인-대화상자) |
| 폴더 감시의 실제 FSEvents 알림, 앱을 다시 실행한 뒤 샌드박스 북마크로 감시 폴더 다시 열기 | 확인하지 않음 | 절차 없음. 시험은 모두 FSEvents를 끄고 돌렸다 |
| 몇 시간 이상 이어지는 연결, Mac 재시동 뒤 다시 쓰기 | 확인하지 않음 | 절차 없음 |
| iPhone 앱의 Xcode 캔버스 미리보기 | 렌더링 실패 | 아래 "알려진 한계와 문제" |

## 구성과 문서

| 구분 | 이름 | 위치 | 내용 |
| --- | --- | --- | --- |
| 대상 | `RemoteDebugMac` | `Apps/Mac` | Mac 앱의 진입점과 수명 주기 |
| 대상 | `RemoteDebugPhone` | `Apps/iOS` | iPhone 앱 화면과 VPN 관리 |
| 대상 | `RemoteDebugTunnel` | `Apps/iOSTunnel` | 패킷 터널 확장 |
| 패키지 | `RemoteDebugKit` | `Packages/RemoteDebugKit` | 공용 모델, 디버그 빌드 검사, IPA와 매니페스트 생성, `rdvalidate` |
| 패키지 | MacHost | `Packages/MacHost` | `MacHostKit`(로직), `MacHostCore`(Go 코어 연결), `MacHostUI`(화면과 미리보기, Go 런타임 없음) |
| 패키지 | PhoneClient | `Packages/PhoneClient` | iPhone 앱 로직 `PhoneClientKit` |
| 패키지 | RDCore | `Packages/RDCore` | `RDCore.xcframework`와 Swift 브리지 `RDCoreBridge` |
| 패키지 | E2E | `Packages/E2E` | Mac과 iPhone 로직의 통합 시험, 설치 웹 페이지의 브라우저 엔진 시험. 제품 코드 없음 |
| 패키지 | WebPage | `Packages/WebPage` | 설치 웹 페이지 로직의 JavaScriptCore 시험. 제품 코드 없음 |
| 코어 | Go | `core/` | Tailscale 노드, 호스트 HTTP 서버, 터널 모드, C API |
| 코어 | 설치 웹 페이지 | `core/internal/host/web` | Mac 호스트가 `/`에서 내주는 HTML·CSS·JS(코어에 들어 있다) |
| 스크립트 | | `scripts/` | 코어 빌드, 시험, 문서 검사 |

| 문서 | 내용 |
| --- | --- |
| [docs/setup.md](docs/setup.md) | 요구 사항, 서명, 빌드, 첫 실행, 앱 없이 웹 페이지로 설치, 문제 해결 |
| [docs/device-test.md](docs/device-test.md) | 실기기 확인 절차 |
| [docs/device-test-results.md](docs/device-test-results.md) | 실기기 확인 결과 기록표 |
| [docs/protocol.md](docs/protocol.md) | Mac·iPhone·코어 사이의 프로토콜 v1 |
| [docs/protocol-addenda.md](docs/protocol-addenda.md) | `docs/protocol.md`를 고치고 더하는 규칙. 설치 웹 페이지는 E |
| [docs/tunnel.md](docs/tunnel.md) | iPhone 패킷 터널 |
| [docs/architecture.md](docs/architecture.md) | 구조와 초기 가정. 틀린 문장은 아래 "문서 정정" |
| [docs/appstore-review.md](docs/appstore-review.md) | App Store 제출 판정 |

문서가 서로 다르면 이 순서로 따른다.

1. `docs/tunnel.md`: `docs/protocol.md`의 §6 전체, §9의 프록시 관련 부분(`mode`가 `host`/`proxy`뿐이라는 문장, iPhone 쪽 `rd_proxy_start` 사용), `docs/architecture.md`의 가정 A1과 구성도를 대체한다.
2. `docs/protocol-addenda.md`: 터널이 다루지 않는 부분에서 `docs/protocol.md`보다 앞선다.
3. `docs/protocol.md`, `docs/architecture.md`의 나머지 부분. 단, 아래 "설계 문서와 달라진 구현"과 "문서 정정"에 적은 내용은 그 표를 따른다.

## 빠른 시작

Apple silicon Mac에 Xcode, Go, XcodeGen이 있어야 한다. 빌드 스크립트는 `eyebuild` 명령을 부르므로, 없으면 [대체 스크립트](docs/setup.md#eyebuild가-없는-mac)를 먼저 만든다.

```sh
scripts/build-core.sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig   # 개발 팀 ID를 넣는다
xcodegen generate --spec project.yml
open RemoteDebug.xcodeproj
```

Xcode에서 스킴 `RemoteDebugMac`을 Mac에서, `RemoteDebugPhone`을 iPhone에서 실행한다. tailnet 준비, 서명, 첫 실행 순서는 [설정 문서](docs/setup.md)에 있다.

iPhone에 RemoteDebug 앱을 설치하지 않으려면 Mac 앱만 실행하고, iPhone에서는 공식 Tailscale 앱으로 같은 tailnet에 접속한 뒤 Mac 페어링 시트의 "앱 없이 Safari로 설치" 링크를 Safari로 연다. 순서는 [설정 문서의 웹 페이지 절](docs/setup.md#iphone에서-앱-없이-설치웹-페이지)에 있다.

## App Store 판정

제출하지 않는다. iPhone 앱은 다른 앱의 설치를 요청하는 기능 때문에 지침 2.5.2에 걸리고, VPN 앱으로 보면 5.4의 조직 계정·고지 의무가 따르며, 심사자가 Mac·tailnet·개발 프로비저닝 없이는 핵심 기능을 볼 수 없어 승인 가능성이 매우 낮다고 판단했다. Mac 앱 단독 제출도 4.2.3(i)와 심사자 접근 때문에 권하지 않는다. 권장 배포는 Xcode 직접 설치나 Ad Hoc이고, TestFlight는 권하지 않는다. iPhone 앱의 Network Extension 권한 때문에 유료 멤버십이 필요할 수 있다. 무료 계정에서 이 권한을 쓸 수 있는지는 확인하지 않음. 판정은 이 프로젝트 구조를 바탕으로 한 추정이며 Apple의 실제 심사 결과가 아니다. 근거와 인용은 [판정서](docs/appstore-review.md)에 있다.

## 알려진 한계와 문제

- Apple silicon 전용이다. `RDCore.xcframework`의 슬라이스가 모두 arm64다.
- `docs/tunnel.md`의 실기기 미확인 항목 9개가 남아 있다. [실기기 확인 절차](docs/device-test.md)의 U1~U9에 같은 번호로 있다.
- iPhone 앱의 Xcode 캔버스 미리보기는 작성 환경에서 `Timed out waiting for signal to perform the initial JIT link`로 실패한다. 원인은 확인하지 못했다. 시뮬레이터 실행과 시험은 정상이다.
- Mac 앱의 미리보기는 렌더링되지만, 공유를 시작하는 시나리오는 정지 화면에 진행 표시만 찍힐 수 있다.
- iPhone을 백업에서 복원하면 터널 상태 폴더가 백업에서 빠져 있어 tailnet 로그인과 페어링을 다시 해야 한다. 설계상 예상이며 실기기에서 확인하지 않음([D6](docs/device-test.md#d6-백업에서-복원)).
- Mac도 노드 상태 폴더(`state`)와 `identity.json`을 Time Machine 백업과 마이그레이션에서 뺀다. 복원하거나 다른 Mac으로 옮긴 Mac은 새 노드 이름(`rd-mac-<새 8자>`)과 새 주소로 tailnet에 다시 로그인해야 하고, 그 Mac과 페어링했던 iPhone은 모두 새 코드로 다시 페어링해야 한다. 실제 복원으로는 확인하지 않음.
- 빌드 폴더 이름이나 `*.debug.dylib`로 Debug 구성을 증명할 수 없는 빌드는 사용자가 대화상자에서 Debug라고 확인하면 게시된다. 확인한 뒤 빌드가 바뀌었는지는 `.app`이면 파일 메타데이터(경로·종류·크기·수정 시각·inode)로, `.ipa`면 SHA-256으로 비교한다. `.app` 비교는 내용 해시가 아니다.
- 페어링 코드를 다섯 번 틀리면 코어는 코드를 폐기하지만 `denied` 이벤트가 5초에 하나로 제한되어, Mac 화면은 다음 이벤트가 올 때까지 폐기된 코드를 계속 보여 줄 수 있다. "새 코드 만들기"로 새 코드를 연다. 코어 쪽 수정은 하지 않았다.
- Mac 앱을 종료할 때 이미 진행 중인 가져오기는 저장 폴더 잠금이 풀린 뒤에도 파일을 쓸 수 있다. 종료 직후 앱을 다시 열면 두 프로세스가 잠시 같은 저장 폴더에 쓸 수 있으므로, 가져오기가 끝난 뒤 종료하고 바로 다시 열지 않는다.
- 두 앱 모두 VoiceOver, 다크 모드, 다이내믹 타입으로 확인하지 않았다. 페어링 요청의 VoiceOver 알림도 코드만 있고 실제로 들어 보지 않았다. 설치 웹 페이지는 오류 안내를 live region 대신 초점 이동으로 알리게 했지만 VoiceOver에서 읽히는지 확인하지 않았다.
- Mac 앱은 App Sandbox를 쓰지 않는다. 저장 폴더가 컨테이너(`~/Library/Containers/com.oozoofrog.app.RemoteDebugMac/Data/Library/Application Support/RemoteDebug`)에서 `~/Library/Application Support/RemoteDebug`로 바뀌었고, 옮겨 주는 코드는 없다. 샌드박스 빌드를 쓰던 Mac은 tailnet 로그인과 페어링을 다시 하거나, 앱을 끈 채 폴더를 직접 옮긴다.
- 프로젝트 빌드는 `xcodebuild`에 `-allowProvisioningUpdates`를 주지 않는다. 프로비저닝 프로필이 없거나 기기가 등록되지 않은 프로젝트는 Xcode에서 한 번 기기용으로 빌드해야 한다.
- 앱이 시작한 프로젝트 빌드의 결과 위치는 `xcodebuild -showBuildSettings`로 읽는다(실제 프로젝트 하나로 확인함). Xcode에서 한 빌드를 가져올 때는 DerivedData의 `info.plist`(`WorkspacePath`)와 Xcode의 빌드 위치 설정(기본, 또는 Custom > Relative to Workspace)으로 위치를 계산한다. 그 밖의 빌드 위치 설정은 찾지 못한다. 이 감시 경로는 실제 Xcode 빌드로 확인하지 않았다.
- Xcode 빌드 감지는 3초마다 DerivedData의 `Build/Products/Debug-iphoneos`와 빌드 기록의 수정 시각을 보는 방식이다. 빌드가 시작한 순간이 아니라 그 폴더가 바뀐 뒤에 등록을 묻는다. 그 프로젝트의 첫 기기용 빌드는 폴더가 생기는 시점만 기준으로 잡혀 다음 빌드에서 묻는다.
- 에이전트 명령(`~/Library/Application Support/RemoteDebug/agent/rd`)은 같은 사용자 계정의 어떤 프로세스든 쓸 수 있다. 연결한 프로젝트나 넘긴 경로의 프로젝트를 빌드해 게시하는 것까지만 한다.
- iOS는 VPN을 한 번에 하나만 켠다. 이 앱의 VPN이 켜진 동안 공식 Tailscale 앱의 VPN은 꺼진다.
- 설치 웹 페이지의 허용 단위는 브라우저가 아니라 iPhone의 tailnet 노드다. 한 번 허용하면 그 iPhone에서 Mac에 닿는 모든 앱과 브라우저가 같은 허용을 쓴다. 접근을 끊으려면 Mac의 **기기** 화면에서 그 기기를 제거한다.
- 설치 웹 페이지는 iPhone의 공식 Tailscale 앱 VPN이 켜져 있고 tailnet의 HTTPS Certificates가 켜져 있어야 열린다. tailnet 정책이 그 iPhone 노드에서 Mac의 443 포트를 막으면 페이지가 열리지 않는다([설정 문서의 ACL 설명](docs/setup.md#tailnet-정책acl)).
- 설치 웹 페이지를 새로고침하면 진행 중이던 설치의 확인을 이어 가지 않는다. Mac의 설치 세션은 제한 시간이 지나면 스스로 만료되고, 다시 설치하면 새 세션을 연다. 홈 화면에서 설치되었는지 직접 본다.

## 설계 문서와 달라진 구현

설계 문서의 다음 문장과 지금 코드가 다르다. 근거는 `.agent-loop/remotedebug-bridge/decisions.jsonl`의 줄 번호다.

| 설계 문서 | 현재 구현 | 근거 |
| --- | --- | --- |
| `docs/architecture.md` 구성도·가정 A1: 터널 확장의 로컬 CONNECT 프록시 | IP 패킷을 tailnet으로 중계하는 패킷 터널([`docs/tunnel.md`](docs/tunnel.md)). Apple TN3120이 패킷 터널 안의 리스너·프록시를 권장하지 않는다 | 5, 26 |
| `docs/protocol.md` §6: iPhone이 호스트별 `allowedTargets`를 터널에 설정 | 설정 없음. 패킷 터널에는 호스트별 허용 목록이 없어 다른 Mac 링크는 확인 후 교체한다 | 20 |
| `docs/architecture.md:53`: 화면을 Mac 앱 대상에 둠 | 화면과 미리보기는 `MacHostUI`(Go 런타임 없음). 앱 실행 파일의 Go 런타임이 Xcode 미리보기를 충돌시켰다 | 33, 34, 41 |
| `docs/protocol.md` §5: 허용 기기 저장 | 승인한 제어 서버 URL에 묶는다. 서버를 바꾸면 확인 후 다시 페어링한다 | 34, 43 |
| `docs/protocol.md:3`: 바꿀 때 이 문서를 먼저 고친다 | 바뀐 규칙은 [`docs/protocol-addenda.md`](docs/protocol-addenda.md)에 있다. 둘이 다르면 addenda를 따른다 | 6 |
| `docs/architecture.md:5`: 공식 Tailscale 앱 없이 각 앱에 내장한 Tailscale만으로 설치 | 내장 경로는 그대로 두고, 공식 Tailscale 앱만 있는 iPhone이 Safari로 여는 설치 웹 페이지를 더했다([`docs/protocol-addenda.md`](docs/protocol-addenda.md) E). 내장 VPN 경로를 끝낸 뒤 사용자가 요청했다 | 61, 62, 63, 64, 65 |
| `docs/architecture.md:86`: Xcode·TestFlight 내부 배포 | Xcode 직접 설치나 Ad Hoc. [판정서](docs/appstore-review.md)가 TestFlight를 권하지 않는다(지침 2.2) | 2 |

| `docs/appstore-review.md`의 2.4.5 해석: Mac 앱은 샌드박스와 호환(빌드 실행·xcodebuild 호출 없음), 로그인 시 자동 실행 없음 | App Sandbox를 쓰지 않고 연결한 프로젝트를 `xcodebuild`로 빌드한다. 메뉴 막대에 상주하고 "로그인할 때 열기"를 켤 수 있다. 사용자가 요청했다. Mac 앱의 App Store 제출 가능성 판단은 이 변경을 반영하지 않았다 | 기록 없음(2026-11-11 사용자 요청) |
| `docs/architecture.md` 가정 A3: App Sandbox를 켠 Mac 앱 | 같은 표의 대안("비샌드박스 배포로 전환")을 택했다 | 기록 없음(2026-11-11 사용자 요청) |

### 설계 문서에 없는 현재 동작

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
| `docs/architecture.md:84` | "iOS 자체도 배포 서명 IPA의 OTA 설치를 받지 않는다" | iOS는 Ad Hoc·Enterprise 서명 IPA도 OTA로 설치한다. Debug 한정은 Mac 앱의 검사 정책(개발 프로필, `get-task-allow`, Debug 구성)과 코어의 게시 시 재확인(`debug`, `getTaskAllow`, 크기·SHA-256)만으로 막는다 |
| `docs/architecture.md:85` | "비밀(인증 키)은 Keychain에만 저장" | 인증 키는 어디에도 저장하지 않는다. 입력한 키는 다음 시작 한 번에만 코어로 넘기고 지운다. Keychain은 쓰지 않는다. 노드 상태(노드 키)는 `stateDir`에 남고 그 폴더는 백업에서 뺀다 |
| `docs/protocol.md:11` | 클라이언트: "iPhone 앱. 패킷 터널 확장 안의 tsnet 노드로 tailnet에 올라 호스트를 호출한다." | 클라이언트는 iPhone 앱이거나, Safari에서 연 설치 웹 페이지(`platform` 값 `Web`)다 |
| `docs/protocol.md:17` | "노드 이름은 `rd-mac-<id8>`, `rd-phone-<id8>`이다." | RemoteDebug 앱의 노드만 그렇다. 설치 웹 페이지로 페어링한 iPhone은 공식 Tailscale 앱의 노드라서, 페어링 요청과 기기 목록에 그 iPhone의 tailnet 노드 이름이 나온다 |
| `docs/protocol.md:376` | "tailnet ACL 태그(`tag:rd-mac`, `tag:rd-phone`)로 `tcp:443`만 허용하면 네트워크 층에서도 한 번 더 막을 수 있다" | 이 태그 규칙만 남기면 공식 Tailscale 앱을 쓰는 iPhone(`tag:rd-phone`이 없는 사용자 노드)은 Mac에 닿지 못해 설치 웹 페이지가 열리지 않는다. [설정 문서의 ACL 설명](docs/setup.md#tailnet-정책acl)을 따른다 |

## 문서 검사

```
사용: scripts/check-docs.sh [--help]   (RD_QUOTES_CACHE_DIR=<폴더>를 주면 Apple 원문 사본으로 인용을 검사한다)
```

다음이 저장소와 다르면 어긋난 곳마다 한 줄을 출력하고 종료 코드 1로 끝난다: 코드 조각과 코드 블록(json 제외)의 경로(`scripts/`, `docs/`, `Packages/`, `Apps/`, `core/`, `Config/`, `.agent-loop/` 아래와 `project.yml` 같은 루트 파일), 문서에 적은 스크립트, 대상·스킴·모듈·번들 ID 이름, U 항목과 `docs/tunnel.md`의 실기기 항목, D 항목과 실행 순서 표, 상대 링크와 `#` 제목 앵커, 설치 웹 페이지 절차(`docs/setup.md`의 웹 페이지 절, `docs/device-test.md`의 D14)에 굵은 글씨나 큰따옴표로 적은 화면 문구(페이지 소스 `core/internal/host/web`, Mac 앱 소스 `Packages/MacHost/Sources`와 글자 그대로 비교). 필요한 문서나 `scripts/check_quotes.py`, `scripts/check_protocol_examples.py`가 없어도 실패한다. 코드 조각 밖 본문의 경로는 검사하지 않는다. Apple 원문을 받지 못하면 인용 검사는 경고만 남긴다.
