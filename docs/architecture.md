# RemoteDebug 구조

## 목표와 비목표

- 목표: Mac에서 만든 개발 서명(디버그) 빌드를, 공식 Tailscale 앱 없이 각 앱에 내장한 Tailscale만으로 페어링한 iPhone에 설치한다.
- 비목표: App Store 제출, xcodebuild 대행, 사용자 tailnet 정책 수정, 다중 사용자 권한. 제출 가능 여부는 `appstore-review.md`에 판정으로 남긴다.

## 구성

```
 Mac 앱 (RemoteDebugMac)                          iPhone 앱 (RemoteDebugPhone)
 ┌──────────────────────────────┐                 ┌───────────────────────────────┐
 │ SwiftUI: 빌드·기기·네트워크   │                 │ SwiftUI: 연결·페어링·빌드 목록 │
 │ RemoteDebugKit: 검증·IPA 생성 │                 │ NETunnelProviderManager        │
 │ RDCoreBridge(Swift) ─ C API   │                 └──────────────┬────────────────┘
 │  └ RDCore(Go, tsnet, host)    │                                │ providerConfiguration / 메시지
 └──────────────┬───────────────┘                 ┌──────────────▼────────────────┐
                │ tailnet(WireGuard)               │ RemoteDebugTunnel (Packet Tunnel)│
                │  HTTPS :443 (ts.net 인증서)      │  RDCore(Go, tsnet, proxy)       │
                └──────────────◄──────────────────┤  127.0.0.1:P  HTTP CONNECT 프록시 │
                                                   │  NEProxySettings(matchDomains=ts.net)│
                                                   └──────────────┬────────────────┘
                                         시스템 프록시를 따르는 │ URLSession(앱), iOS 설치기(가정 A1)
```

## 설치 경로

1. 호스트 사용자가 Debug 빌드를 가져온다(폴더 감시 또는 선택). `DebugBuildPolicy`를 통과해야 IPA로 묶여 게시된다.
2. iPhone 앱이 `GET /v1/builds`로 목록을 받고 `POST /v1/builds/{id}/sessions`로 설치 세션을 만든다.
3. 앱이 `installUrl`(`itms-services://…manifestUrl`)을 연다. iOS 설치기가 `manifest.plist`와 `app.ipa`를 호스트 HTTPS 주소에서 받아 설치한다.
4. 호스트는 매 요청마다 WhoIs 노드와 세션 결속을 확인하고, 완료되면 토큰을 폐기한다.

개발 서명 앱은 iPhone의 개발자 모드가 켜져 있고 프로필에 그 기기가 들어 있어야 실행된다.

## 핵심 가정과 검증 계획

| ID | 가정 | 확인 방법 | 실패 시 |
| --- | --- | --- | --- |
| A1 | iOS 설치기(`appstored`/`itunesstored`)가 NE의 `NEProxySettings`를 따라 호스트 HTTPS에 접속한다 | 실기기: 호스트 `session` 이벤트에 설치기 `User-Agent`의 매니페스트·IPA 요청이 찍히는지 | ① PAC(`autoProxyConfiguration`)로 교체 ② 패킷 수준 터널(utun→gVisor→tsnet Dial, DNS 응답기 포함) ③ iPhone은 공식 Tailscale 앱 사용(사용자 선택지 2) ④ Funnel 임시 세션(공개 엔드포인트라 사용자 승인 필요) |
| A2 | tsnet이 NE 메모리 한도(보고치 50MiB) 안에서 상주한다 | 실기기: `rssMiB` 기록, `GOMEMLIMIT`·`ts_omit_*` 태그 조정 | 기능 태그 축소, 그래도 초과하면 ②의 경량 경로 |
| A3 | App Sandbox 켠 Mac 앱에서 tsnet이 동작한다 | 로컬: 샌드박스 앱으로 가짜 tailnet E2E | 샌드박스 예외 최소 추가, 안 되면 비샌드박스 배포로 전환하고 판정서에 반영 |
| A4 | 개발 서명 IPA가 OTA(`itms-services`)로 설치된다 | 실기기 설치 | Ad Hoc 서명 또는 USB 설치 안내 |

A1·A2·A4는 실기기 없이는 확정할 수 없다. 확정 전에는 "동작함"이라고 보고하지 않는다.

## 책임과 디렉터리

| 구성요소 | 위치 | 책임 |
| --- | --- | --- |
| 코어 | `core/` (Go) | tsnet 노드, 호스트 HTTP 서버(WhoIs 허용 목록·페어링·세션·IPA 제공), 클라이언트 CONNECT 프록시, C API, 가짜 tailnet 테스트, `cmd/rdtestenv` |
| 코어 패키지 | `Packages/RDCore/` | `RDCore.xcframework`(macOS arm64, iOS arm64, iOS 시뮬레이터 arm64)와 Swift 브리지 `RDCoreBridge` |
| 킷 | `Packages/RemoteDebugKit/` | 공용 모델, 디버그 빌드 검증, IPA·매니페스트 생성, `rdvalidate` CLI |
| Mac 앱 | `Apps/Mac/` | 호스트 UI와 흐름 |
| iPhone 앱 | `Apps/iOS/`, `Apps/iOSTunnel/` | 클라이언트 UI, VPN 관리, 터널 확장 |
| 문서 | `docs/` | 프로토콜, 구조, 판정서, 설정·실기기 절차 |

### 킷 공개 API (구현 계약)

```swift
// RDModels (iOS+macOS)
public struct BuildDescriptor: Codable, Sendable, Hashable, Identifiable   // protocol §4.1
public struct DeviceEntry: Codable, Sendable, Hashable, Identifiable       // protocol §5
public struct CoreConfig: Codable, Sendable      // protocol §9 설정
public struct CoreStatus: Codable, Sendable      // protocol §9 상태
public enum CoreEvent: Codable, Sendable         // protocol §10
// RDBuildInspection (macOS)
public struct InspectionOptions: Sendable { confirmedDebug: Bool; targetUDID: String?; allowedConfigurations: Set<String>; now: Date }
public enum RejectionCode: String, Codable, Sendable   // protocol §7 사유 코드 (rawValue는 표의 snake_case)
public struct Rejection: Codable, Sendable { code: RejectionCode; detail: String }
public struct InspectionResult: Codable, Sendable { accepted: Bool; reasons: [Rejection]; warnings: [String]; descriptor: BuildDescriptor? }
public enum BuildInspector {
    public static func inspect(appAt: URL, options: InspectionOptions) throws -> InspectionResult
    public static func inspect(ipaAt: URL, options: InspectionOptions, workDirectory: URL) throws -> InspectionResult
}
// RDPackaging (macOS)
public enum IPABuilder { public static func package(appAt: URL, to ipaURL: URL) throws -> (size: Int64, sha256: String) }
public enum OTAManifest { public static func make(bundleId: String, version: String, title: String, ipaURL: URL) -> Data }
```

## 보안 모델

- 신원은 tailnet(WireGuard 노드 키)이 보증하고, 호스트가 WhoIs로 읽는다. 페어링 코드 + 호스트 사용자 승인으로 허용 목록에 들어간다.
- 설치 토큰은 1회용·노드 결속·만료형이다. 세션 없이는 IPA에 접근할 수 없다.
- 디버그 한정은 Mac 앱(정책)과 코어(재검증)가 이중으로 막고, iOS 자체도 배포 서명 IPA의 OTA 설치를 받지 않는다.
- 비밀(인증 키)은 Keychain에만 저장하고 로그에 남기지 않는다. 인증 키는 처음 로그인에만 쓰고 노드 상태는 `stateDir`에 남는다.
- 판정서가 다루는 App Store 규정과 별개로, 이 앱은 내부 배포(Xcode·TestFlight 내부 테스트)를 전제로 한다.

## 빌드와 검증 체계

- Xcode 대상은 Xcode MCP로 열어 빌드·테스트한다. 서명 없는 기기 컴파일처럼 플래그나 증거 위치가 필요한 경우만 `eyebuild xcodebuild`를 쓴다.
- Go·SwiftPM·스크립트는 `scripts/go.sh`, `eyebuild swift` 등으로 실행해 캐시를 `/Volumes/eyedisk/build/remotedebug/` 아래에 둔다.
- 가짜 tailnet(`testcontrol`)으로 E2E를 돌린다. 사용자 tailnet은 허가 전까지 건드리지 않는다.
- 실기기 검증 절차는 `docs/device-test.md`에 둔다.

## 현지화

Mac 앱, iPhone 앱 두 개(RemoteDebugPhone, RemoteDebugVPN), 위젯·터널 확장, 설치 웹 페이지는 한국어(ko, 원문), 영어(en), 일본어(ja), 중국어 간체(zh-Hans), 중국어 번체(zh-Hant)로 보인다. 다른 언어로 설정한 기기는 영어로 보인다.

### 문자열 쓰는 법

- 한국어 원문이 그대로 키다. 소스에 한국어를 쓰고, 번역은 `Localization/Localizable.xcstrings`(원문 언어 ko) 하나에 모은다.
- 이 카탈로그를 앱·확장 대상 여섯 개(RemoteDebugMac, RemoteDebugPhone, RemoteDebugTunnel, RemoteDebugWidgets, RemoteDebugVPN, RemoteDebugVPNTunnel)의 리소스로 넣는다. 패키지 코드(MacHostKit, MacHostUI, PhoneClientKit, RDModels …)도 `Bundle.main`에서 찾으므로 패키지에는 카탈로그나 `bundle: .module`을 두지 않는다.
- SwiftUI의 `Text("…")`, `Button("…")`, `Label("…", …)`, `.navigationTitle("…")` 같은 리터럴은 그대로 번역된다.
- `String`으로 만들어 나중에 보이는 문구(모델의 오류 문구, enum의 이름·설명, 알림·경고 문구, AppKit·UIKit 제목, 접근성 이름)는 만드는 곳에서 `String(localized: "…")`로 쓴다. `Text(문자열 변수)`는 번역하지 않는다.
- 보간: `String` 값은 `%@`, `Int`는 `%lld`(자릿수 구분이 붙는다), `Double`은 `%lf`가 된다. 포트·연도·빌드 번호·크기·날짜처럼 모양이 정해진 값은 `String(port)`처럼 먼저 문자열로 만든다. `+`로 이은 조각은 키가 되지 못하므로 문장 하나를 보간으로 쓴다.
- 번역하지 않는 것: 로그, 진단 파일, 프로토콜·JSON 값, 식별자, 키체인·UserDefaults 키, 오류 코드, 코드가 비교하는 문자열, 미리보기 전용 코드.
- 표시 이름과 권한 문구(`CFBundleDisplayName`, `NSLocalNetworkUsageDescription`, `NSCameraUsageDescription`), 문서 종류 이름은 대상마다 `Localization/InfoPlist/<대상>/InfoPlist.xcstrings`에 있다. `Apps/*/project-*.yml`의 Info.plist 값을 바꾸면 그 카탈로그의 ko 값도 같이 바꾼다.
- `swift test`에는 카탈로그가 없어 `String(localized:)`가 한국어 원문을 돌려준다. 시험은 한국어 원문과 비교하고, 스킴 RemoteDebugMac·RemoteDebugPhone의 시험 언어도 ko다.

### 키 맞추기와 번역 검사

- `scripts/sync-strings.sh`: 세 스킴(RemoteDebugMac, RemoteDebugPhone, RemoteDebugVPN)을 `SWIFT_EMIT_LOC_STRINGS=YES`, 서명 없이 빌드해 컴파일러가 뽑은 키(`.stringsdata`)를 `xcrun xcstringstool sync` 한 번으로 카탈로그에 합친다. 화면 문구를 바꾼 뒤 실행한다. 새 키가 들어오고, 코드에서 사라진 키는 번역이 없으면 지워지며 번역이 있으면 `stale`로 남는다. 번역은 지우지 않는다. 다시 실행해도 결과가 같다.
- Xcode에서 빌드할 때는 문자열을 뽑지 않는다(`project.yml`의 `SWIFT_EMIT_LOC_STRINGS: NO`). 대상마다 카탈로그를 고치면 다른 플랫폼에서만 쓰는 키가 `stale`이 되기 때문이다. 번역은 Xcode의 카탈로그 편집기에서 넣어도 된다.
- Debug 빌드가 컴파일하지 않는 분기(`#if targetEnvironment(simulator)`, `#if DEBUG`의 `#else`)의 문구는 `Localization/manual-keys.txt`에 적는다. 스크립트가 `extractionState: manual`로 넣고, sync는 이 키를 건드리지 않는다.
- `python3 -I scripts/check_strings.py`: 모든 카탈로그와 웹 페이지 번역표에서 en, ja, zh-Hans, zh-Hant 번역이 빠졌거나 형식 지정자(`%@`, `%lld`, 웹은 `{이름}`)가 원문과 다르면 종료 코드 1이다. `shouldTranslate: false`인 키는 검사하지 않는다.
- `python3 -I scripts/audit_strings.py --stringsdata-root <빌드 폴더> <소스 폴더…>`: 소스의 한국어 리터럴 가운데 키로 뽑히지 않은 것을 보인다. 로그 줄은 빼고 본다.

### 언어 고르기

- 앱: 각 번들의 `CFBundleDevelopmentRegion`이 en이다. 기기 언어 목록에서 앞쪽부터 ko, en, ja, zh-Hans, zh-Hant 중 하나를 찾고, 없으면 en을 쓴다. 고른 언어에 번역이 없는 키는 한국어 원문으로 보인다.
- 설치 웹 페이지: `core/internal/host/web/logic.js`의 `// RD-STRINGS-BEGIN`과 `// RD-STRINGS-END` 사이가 번역표(JSON, 언어별로 같은 키, 빈 값은 아직 번역하지 않음)다. `RDLogic.pickLanguage`가 `navigator.languages`를 앞부터 보고 `ko*`는 ko, `en*`은 en, `ja*`는 ja, 스크립트 Hant나 지역 TW·HK·MO의 `zh`는 zh-Hant, 나머지 `zh*`는 zh-Hans를 고르며, 맞는 것이 없으면 en이다. 문구는 고른 언어, en, 한국어 원문 순서로 찾는다. HTML의 기본 문구는 한국어다.

### 아직 번역하지 않는 것

- Go 코어가 돌려주는 API 오류 문구(한국어)는 그대로 보인다.
- `Packages/RemoteDebugFeedback`(다른 앱에 넣는 패키지)와 `rdvalidate` CLI는 현지화하지 않았다.
- 코딩 에이전트용 문구(MCP 도구 설명, `rd` 명령의 응답, 에이전트 지침 파일)는 한국어로 둔다.
- 알림은 Mac이 `title-loc-key`·`loc-key`·`loc-args`를 함께 보내 iPhone의 언어로 보인다([`docs/protocol-addenda.md`](protocol-addenda.md) P).
