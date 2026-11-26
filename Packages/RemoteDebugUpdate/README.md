# RemoteDebugUpdate

RemoteDebug로 설치한 개발 앱이 자신의 최신 업데이트 정보를 확인하고, RemoteDebug iPhone 앱을 통해 바로 업데이트할 수 있게 해 주는 Swift 패키지다. iOS 17 이상에서 쓴다.

**Debug 빌드에서만 동작하고 화면에 표시된다.** 배포 빌드(App Store, TestFlight 등 `DEBUG`가 없는 빌드)에는 네트워크 코드, `remotedebug://` URL 스킴, 화면 문구가 컴파일되지 않으며 모든 뷰는 `EmptyView`를 돌려준다.

## Debug 빌드와 배포 빌드

| | Debug 빌드 | 배포 빌드(`DEBUG`가 없는 빌드) |
| --- | --- | --- |
| 업데이트 확인 | Mac의 `GET /v1/updates/<번들 ID>`(이전 Mac 앱은 `GET /v1/builds`)로 최신 빌드와 업데이트 내역을 조회한다 | 코드가 없다. `check()`는 `.unavailable(.disabledInRelease)`를 돌려준다 |
| 업데이트 설치 | `remotedebug://update?bundleId=…&buildId=…`로 RemoteDebug 앱을 열어 설치를 시작한다 | 코드가 없다. `openUpdater()`는 아무것도 하지 않고 `false`를 돌려준다 |
| 화면 표시 | `RemoteDebugUpdateBanner`, `.remoteDebugUpdateBanner()`, `RemoteDebugUpdateSection`이 표시된다 | `EmptyView`를 돌려주어 화면에 나타나지 않는다 |

## 넣는 차례

1. 프로젝트에 Swift 패키지 `https://github.com/oozoofrog/remotedebug`를 추가하고 제품 `RemoteDebugUpdate`를 앱 대상에 연결한다.
2. Mac 앱에서 넣을 코드를 받는다.
   - 사람: Mac 앱의 앱 목록에서 그 앱 줄의 더 보기 메뉴 > **앱 안 업데이트 추가…**를 누른다.
   - 에이전트: `remotedebug_update_setup`(명령은 `rd update-setup <프로젝트 폴더>`)을 부르면 이 Mac의 주소가 `#if DEBUG` 안에 든 코드와 할 일을 받는다.
3. 앱을 시작할 때 `#if DEBUG` 안에서 `start(macHost:)`를 한 번 부른다. Mac 주소 글자가 배포판 실행 파일에 남지 않게 반드시 `#if DEBUG` 안에 둔다.

   ```swift
   import RemoteDebugUpdate

   #if DEBUG
   RemoteDebugUpdate.start(macHost: "rd-mac-1a2b3c4d.tail0001.ts.net")
   #endif
   ```

4. 원하는 곳에 업데이트 UI를 붙인다. 두 뷰 모두 **Debug 빌드에서만 표시된다.**

   ```swift
   // 화면 상단에 새 업데이트가 있을 때만 배너 표시
   ContentView()
       .remoteDebugUpdateBanner()

   // 설정 화면의 Form / List 안에 업데이트 확인 및 설치 구역 표시
   RemoteDebugUpdateSection()
   ```

5. 직접 업데이트 상태를 읽고 버튼을 만들려면 아래 API를 쓴다.

   ```swift
   let status = await RemoteDebugUpdate.check()
   if case .available(let info) = status {
       // info.versionLabel, info.releaseNotes, info.publishedAt
       await RemoteDebugUpdate.openUpdater(buildId: info.buildId)
   }
   ```

6. (선택) 코드에서 `RemoteDebugUpdate.canOpenUpdater`로 RemoteDebug 앱 설치 여부를 확인하려면 앱의 `Info.plist`에 `LSApplicationQueriesSchemes` 항목으로 `remotedebug`를 추가한다. 넣지 않아도 `openUpdater` 호출은 동작한다.

## 동작 방식

- **업데이트 판정**: 버전(`CFBundleShortVersionString`)과 빌드 번호(`CFBundleVersion`)를 숫자 순서로 비교해 더 높으면 새 빌드로 본다. 둘 다 같으면(Debug 빌드에서 번호를 올리지 않은 경우) 이 빌드를 처음 실행한 시각과 Mac 게시 시각을 비교한다.
- **설치 흐름**: 사용자가 **업데이트**를 누르면 `remotedebug://update?bundleId=<번들 ID>&buildId=<빌드 ID>`로 RemoteDebug 앱이 열리고, RemoteDebug 앱이 최신 목록을 받아 설치 세션과 iOS 설치기(`itms-services`)를 시작한다.
- **네트워크 조건**: 업데이트 정보를 조회할 때는 iPhone에서 RemoteDebug 앱의 VPN(또는 같은 tailnet의 공식 Tailscale VPN)이 켜져 있어야 한다.
- **문구와 언어**: Debug 빌드의 기본 문구는 기기 언어(한국어, 영어, 일본어, 중국어 간체, 중국어 번체)를 따른다. 문구는 카탈로그 리소스가 아니라 `#if DEBUG` 코드 안에 있으므로 배포판 묶음에 들어가지 않는다.
- **개인정보 매니페스트**: `PrivacyInfo.xcprivacy`가 리소스로 포함되며, 추적·수집 데이터·Required Reason API(`UserDefaults`, 파일 수정 시각 등)를 쓰지 않는다.
