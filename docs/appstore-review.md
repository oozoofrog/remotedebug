# App Store 제출 판정

기준: Apple App Review Guidelines 공식 페이지(2026-10-16판), 조회일 2026-11-11.
인용(`>`)은 공식 영문 원문이고 `python3 -I scripts/check_quotes.py docs/appstore-review.md`가 원문 일치를 검사한다. "해석"과 "판정"은 이 프로젝트 구조를 바탕으로 한 추정이며 Apple의 실제 심사 결과를 보장하지 않는다.

## 결론

| 대상 | 판정 | 핵심 근거 |
| --- | --- | --- |
| iPhone 앱 `RemoteDebugPhone` + 터널 확장 | **제출하지 않는다.** 설치 기능을 넣은 채로는 승인 가능성이 매우 낮다고 본다. | 2.5.2(다른 앱 설치), 5.4(VPN으로 보면 조직 계정·고지 의무), 4.2.3(i), 제출 전 점검(심사자 접근) |
| Mac 앱 `RemoteDebugMac` | 단독 제출도 권하지 않는다(높은 위험). | 4.2.3(i)(짝이 되는 iPhone 앱을 스토어에서 받을 수 없음), 제출 전 점검(심사자 접근) |
| 권장 배포 | 내부 배포: Xcode 직접 설치 또는 Ad Hoc. iPhone 앱의 Network Extension 권한 때문에 유료 멤버십이 필요할 수 있다. | 지침 서문이 가족·지인용 앱에 이 방법을 안내함 |

가장 큰 차단 요인은 2.5.2다. 5.4가 적용된다면 조직 계정이 필요하고, 조직 계정이 있어도 고지 의무와 심사자 접근 문제가 남는다. 기능을 줄여서 통과시키는 방법은 앱의 목적이 사라지므로 선택지가 아니다. Mac 앱에는 명시적 금지 조항이 없고, 위험 판단은 4.2.3(i)과 심사자 접근에 기댄다.

## 심사자가 보게 될 동작

1. iPhone 앱이 VPN 구성(Packet Tunnel Provider)을 추가하고 켠다.
2. iPhone 앱이 Mac이 제공하는 개발 서명 IPA를 `itms-services` 주소로 iOS 설치기에 넘겨 설치하게 한다.
3. Mac 앱이 사용자 Mac의 디버그 빌드를 읽어 tailnet으로 제공한다.
4. 두 앱 모두 사용자의 tailnet 계정, Mac, 개발 프로비저닝이 있어야 동작한다.

## 조항별 판정

### 2.5.2 — 다른 앱의 설치 (iPhone 앱: 높은 위험)

> [guidelines 2.5.2] Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app, including other apps.

해석: iPhone 앱이 코드를 직접 내려받아 실행하지는 않는다. 그러나 앱의 목적이 다른 앱의 설치를 요청하는 것이라서 "install ... other apps"에 해당한다고 보는 것이 자연스럽다. 설치 기능을 빼면 앱의 존재 이유가 사라진다. 기능을 숨기고 제출하는 방법은 아래 2.3.1(a) 때문에 선택지가 아니다. Mac 앱은 빌드를 제공할 뿐 설치하지 않으므로 이 조항의 문언에는 더 멀다.

### 5.4 — VPN 앱 (iPhone 앱: 적용되면 높음, 적용 여부는 불확실)

> [guidelines 5.4] Apps offering VPN services must utilize the NEVPNManager API and may only be offered by developers enrolled as an organization.

> [guidelines 5.4] You must make a clear declaration of what user data will be collected and how it will be used on an app screen prior to any user action to purchase or otherwise use the service.

> [guidelines 5.4] Apps offering VPN services may not sell, use, or disclose to third parties any data for any purpose, and must commit to this in their privacy policy.

> [guidelines 5.4] Apps that do not comply with this guideline will be removed from the App Store and blocked from installing via alternative distribution and you may be removed from the Apple Developer Program.

해석: 이 앱이 "VPN services"를 제공하는 것으로 볼지는 원문이 판정하지 않는다. 사용자 자신의 tailnet에 접속하는 클라이언트이고 TN3120도 격리된 네트워크의 자원 접근을 정상 용례로 든다. 그래도 VPN 구성(Packet Tunnel)을 추가하므로 적용된다고 가정하고 위험을 잡는다. 적용되면 개인 계정으로는 제출할 수 없고, 조직 계정이어도 앱 화면의 데이터 고지, 제3자에 데이터 비공개 약속(Tailscale 조정 서버가 기기 정보를 받는 점은 별도 검토 필요, 기억 기반), 면허가 필요한 지역의 면허 정보가 필요하다. 위반의 결과로 개발자 프로그램 제재까지 명시돼 있으므로 개인 계정으로 시험 삼아 제출하는 것은 피한다. `NETunnelProviderManager`가 `NEVPNManager`의 하위 클래스라 이 API 조건을 충족한다는 점은 제공한 원문에 없다(기억 기반, 확인 필요). 이 Mac의 Xcode 프로필에는 팀 이름이 `oozoofrog`인 것과 개인 이름인 것이 함께 있어, 계정 유형은 로컬 정보만으로 알 수 없다.

### 2.5.1과 TN3120 — Network Extension의 용도 (설계 변경 사유)

> [guidelines 2.5.1] Apps should use APIs and frameworks for their intended purposes and indicate that integration in their app description.

> [TN3120] Do use a packet tunnel provider to access secure resources on an isolated network.

> [TN3120] Do not use a packet tunnel provider to host a network listener or proxy server.

> [TN3120] This path is simply not a recommended use case for a packet tunnel provider or any other Network Extension.

해석: 초기 설계는 터널 확장이 로컬 프록시를 띄우고 시스템 프록시로 지정하는 방식이었다(architecture.md의 가정 A1). TN3120이 명시적으로 권장하지 않는 사용이므로 이 설계는 App Store 여부와 무관하게 버린다. 대신 IP 패킷을 tailnet으로 중계하는 일반 VPN 방식(패킷 수준 터널)을 기본으로 한다. 이 변경은 docs/tunnel.md에 기록한다.

### 4.2.3(i) — 다른 앱 없이 동작 (iPhone 앱: 중간, Mac 앱 단독 제출: 높음)

> [guidelines 4.2.3] Your app should work on its own without requiring installation of another app to function.

해석: 원문은 "다른 앱"이 같은 기기에 있어야 하는지를 한정하지 않는다. iPhone 앱은 Mac 앱과 그 Mac의 빌드가 있어야 동작한다. Mac 앱만 스토어에 내면 짝이 되는 iPhone 앱을 스토어에서 받을 수 없으므로 문제가 더 크다.

### 제출 전 점검 목록과 2.1 — 심사자 접근 (두 앱: 높은 위험)

> [guidelines Before You Submit] Provide App Review with full access to your app.

> [guidelines Before You Submit] If your app includes account-based features, provide either an active demo account or fully-featured demo mode, plus any other hardware or resources that might be needed to review your app (such as login credentials or a sample QR code).

> [guidelines 2.1] Ensure the demo mode exhibits your app's full features and functionality.

해석: 심사자가 핵심 기능을 보려면 실행 중인 Mac, tailnet 접근, 그리고 심사자 기기가 등록된 개발 프로비저닝의 디버그 빌드가 필요하다(개발 서명 앱이 등록된 기기에만 설치된다는 점은 Devices 원문의 기기 등록 개념에 근거한 해석). 이 조건을 심사자에게 갖춰 주기는 사실상 어렵다. 2.1이 허용하는 내장 데모 모드는 "전체 기능"을 보여 줘야 하는데, 다른 앱의 실제 설치는 데모로 대신할 수 없다.

### 2.4.5 — Mac App Store (Mac 앱)

> [guidelines 2.4.5] They must be appropriately sandboxed

> [guidelines 2.4.5] They may not download or install standalone apps, kexts, additional code, or resources to add functionality or significantly change the app from what we see during the review process.

> [guidelines 2.4.5] They may not auto-launch or have other code run automatically at startup or login without consent nor spawn processes that continue to run without consent after a user has quit the app.

해석: Mac 앱은 샌드박스와 호환되도록 만들고(빌드 실행·xcodebuild 호출 없음), Mac에 아무것도 설치하지 않으며, 로그인 시 자동 실행을 넣지 않고 앱을 종료하면 서버도 멈춘다. 2.4.5 자체는 충족할 수 있어 차단 요인이 아니다. 2.5.2 앞부분의 "outside the designated container area"는 사용자가 직접 고른 폴더를 읽는 동작이라 샌드박스가 허용하는 방식으로 보지만 이는 기억 기반이다.

### 2.3.1(a) — 기능을 숨기지 않는다

> [guidelines 2.3.1] All new features, functionality, and product changes must be described with specificity in the Notes for Review section of App Store Connect (generic descriptions will be rejected) and accessible for review.

해석: 설치 기능과 VPN 사용을 심사 메모에 구체적으로 적어야 한다. 빼고 제출한 뒤 나중에 켜는 방식은 쓰지 않는다.

### 낮은 위험으로 본 항목

- 3.2.2(i): 목록은 사용자의 Mac이 올린 빌드만 보여 주고 스토어 같은 탐색 기능이 없다.

> [guidelines 3.2.2] Creating an interface for displaying third-party apps, extensions, or plug-ins similar to the App Store or as a general-interest collection.

- 4.8과 5.1.1(v): tailnet 로그인은 특정 외부 서비스의 클라이언트이고 핵심 기능과 직접 관련된다.

> [guidelines 4.8] Your app is a client for a specific third-party service and users are required to sign in to their mail, social media, or other third-party account directly to access their content.

> [guidelines 5.1.1] Apps may not require users to enter personal information to function, except when directly relevant to the core functionality of the app or required by law.

- 5.1.1(i): 수집하는 데이터가 없어도 개인정보 처리방침 링크는 필요하다.

> [guidelines 5.1.1] All apps must include a link to their privacy policy in the App Store Connect metadata field and within the app in an easily accessible manner.

## 배포 대안

> [guidelines preface] If you build an app that you just want to show to family and friends, the App Store isn't the best way to do that. Consider using Xcode to install your app on a device for free or use Ad Hoc distribution available to Apple Developer Program members.

| 경로 | 근거와 조건 |
| --- | --- |
| Xcode 직접 설치 | 개발 서명이므로 기기가 프로필에 등록돼야 한다. 무료 계정은 기기 3대·앱 3개·7일 만료의 제한이 있고, 멤버십 계정은 멤버십 연도마다 제품군별 100대이며 연도 중에 비활성화해도 한도는 늘지 않는다. 첫 설치는 이 방법이다. iPhone 앱은 Network Extension 권한이 필요하므로 무료 계정에서 가능한지 확인이 필요하다(아래). |
| Ad Hoc | Developer Program 멤버용이다. 프로필에 기기를 등록한다. |
| TestFlight | 권하지 않는다. 비공개 도구는 아래 2.2의 "공개 배포 의도" 조건과 맞지 않는다. |
| Mac 앱 직접 서명 | Mac App Store 밖에서 배포하면 2.4.5가 적용되지 않는다. Developer ID 서명·공증 절차는 이 문서에서 검증하지 않았다. |

> [guidelines 2.2] Any app submitted for beta distribution via TestFlight should be intended for public distribution and should comply with the App Review Guidelines.

> [Devices] Members of the Apple Developer Program and Apple Developer Enterprise Program can register up to 100 of the following devices, per product family, per membership year

> [Devices] You may disable a device on your list during the year, but doing so won't increase your number of available devices.

> [Devices] You can remove specific devices, remove all devices to restore your available device count to 100 per product family, or continue without removing any devices.

> [AccountOverview] You can register up to 3 devices, which expire after 7 days.

> [AccountOverview] You can install up to 3 apps per device.

> [AccountOverview] To build more advanced app capabilities and distribute apps, you'll need to be an Apple Developer Program member or Apple Developer Enterprise Program member.

무료 계정에서 Network Extension 권한을 쓸 수 있는지는 확인하지 못했다. 마지막 문장은 고급 기능에 멤버십이 필요하다는 일반 안내일 뿐이다. 불가능하다면 iPhone 앱은 유료 멤버십 없이 만들 수 없다(기억 기반).

## 확인하지 못한 것

1. Apple Developer 계정 유형(개인/조직)과 멤버십 종류.
2. Apple Developer Program License Agreement의 해당 조항(이 세션에서 원문을 열지 않음).
3. Apple의 실제 심사 결정, 지역별 VPN 관련 법규(5.4가 면허 정보를 요구하는 지역).
4. Tailscale 이름·로고 사용 조건.
5. TestFlight 내부 테스트가 심사 없이 배포되는지. 공식 개요 문서는 외부 테스터에 심사가 따른다고 하고, 그룹에 첫 빌드를 추가하면 App Review로 보낸다고도 한다. 위 2.2 때문에 어느 쪽이든 권하지 않는다.

> [TestFlight] If you invite external testers, your beta build may require review.

> [TestFlight] When you add the first build of your app to a group, the build gets sent to App Review to make sure it follows the App Review Guidelines .

## 참고 원문

- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- TN3120: https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers
- TestFlight 개요: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- 기기 등록: https://developer.apple.com/help/account/devices/devices-overview/
- Developer account overview(아래 주소가 보여 주는 도움말 페이지): https://developer.apple.com/support/compare-memberships/
