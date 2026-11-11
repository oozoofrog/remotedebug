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
