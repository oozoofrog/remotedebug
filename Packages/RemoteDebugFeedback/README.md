# RemoteDebugFeedback

앱 안에서 피드백을 받는 Swift 패키지다. Debug 빌드는 개발자의 Mac(RemoteDebug Mac 앱)으로 바로 보내고, 배포 빌드는 사용자의 메일 앱으로 보낸다. iOS 17 이상에서 쓴다. Apple Watch 앱의 로그를 함께 보내려면 watchOS 10 이상의 Watch 앱에도 넣는다.

이 문서는 앱에 패키지를 넣는 개발자와 에이전트가 차례대로 따라 하도록 썼다. 법률 조언이 아니다. 개인정보 처리방침과 App Store 답변은 앱마다 직접 확인해 정한다.

## Debug 빌드와 배포 빌드

| | Debug 빌드 | 배포 빌드(App Store, TestFlight 등 `DEBUG`가 없는 빌드) |
| --- | --- | --- |
| 보내는 길 | Mac으로 바로(`POST /v1/crashes`). 닿지 않으면 메일이나 저장 후 다시 보내기 | 메일만. 패키지는 네트워크 요청을 하지 않는다 |
| 로그 기록 | 동의 없이 남긴다 | 사용자가 동의하기 전에는 남기지도 모으지도 않는다 |
| 크래시 수집(MetricKit) | Mac 주소가 있으면 한다 | 코드가 없다 |
| 확인 목록 | 있다 | 코드가 없다 |
| Mac 주소(`macHost`) | 쓴다 | 쓰지 않는다. `start(host:)`와 `send`는 아무것도 하지 않고 `false`를 돌려준다 |

배포 빌드에는 Mac으로 보내는 코드(`FeedbackClient`, `FeedbackReport`), 크래시 수집, 확인 목록(`FeedbackCheckItem`, `RemoteDebugFeedback.checklist`)과 그 문구가 컴파일되지 않는다. 이 이름들을 앱 코드에서 직접 쓴다면 `#if DEBUG` 안에 둔다.

## 넣는 차례

1. 프로젝트에 Swift 패키지 `https://github.com/oozoofrog/remotedebug`를 추가하고 제품 `RemoteDebugFeedback`을 앱 대상에 연결한다.
2. Mac 앱에서 넣을 코드를 받는다. 에이전트는 `remotedebug_feedback_setup`(명령은 `rd feedback <프로젝트 폴더> [메일]`)을 부르면 이 Mac의 주소와 그 프로젝트의 공개키가 든 코드를 받는다. 사람은 Mac 앱의 앱 화면에서 그 앱 줄의 더 보기 메뉴 > **크래시·피드백 보내기 추가…**를 누른다.
3. 앱을 시작할 때 한 번 `start`를 부른다. Mac 주소는 `#if DEBUG` 안에만 둔다. 밖에 두면 주소 글자가 배포판 실행 파일에 남는다.

   ```swift
   import RemoteDebugFeedback

   #if DEBUG
   RemoteDebugFeedback.start(.init(
       macHost: "rd-mac-1a2b3c4d.tail0001.ts.net",
       email: "dev@example.com",
       publicKeyBase64: "<공개키>"
   ))
   #else
   RemoteDebugFeedback.start(.init(email: "dev@example.com", publicKeyBase64: "<공개키>"))
   #endif
   ```

4. 피드백을 띄울 화면에 시트를 붙인다.

   ```swift
   .remoteDebugFeedback(isPresented: $showsFeedback)
   ```

5. 배포 빌드에서도 로그를 받으려면 설정 화면의 `Form`이나 `List` 안, 피드백 근처에 동의 스위치를 둔다.

   ```swift
   RemoteDebugFeedbackConsentSection()
   ```

6. 남길 가치가 있는 순간에 로그를 남긴다(선택). `os.Logger`로 남긴 이 앱의 로그는 보낼 때 따로 모은다.

   ```swift
   RemoteDebugFeedback.log("결제 화면 열림")
   ```

7. 배포 전에 아래 "배포 전 확인"을 따른다.

## 로그 기록 동의

배포 빌드는 사용자가 동의하기 전에는 로그를 기기에 남기지 않는다. 보낼 때 묻는 것만으로는 부족하다고 보고, 남기는 것부터 동의를 받는다.

- 동의는 꺼진 채로 시작한다. `RemoteDebugFeedbackConsentToggle`(스위치만)이나 `RemoteDebugFeedbackConsentSection`(스위치와 아래 설명)을 켜면 무엇을 남기는지 설명이 뜨고, **동의하고 켜기**를 눌러야 켜진다.
- 동의가 없으면 `RemoteDebugFeedback.log`는 아무것도 남기지 않고, 시스템 로그도 모으지 않으며, 피드백 화면에 **최근 로그 붙이기** 스위치가 보이지 않는다.
- 동의한 뒤에도 로그를 붙일지는 보낼 때마다 따로 고른다. 배포 빌드에서는 꺼진 채로 시작한다.
- 스위치를 끄면 패키지가 기기에 남긴 것을 바로 지운다: 메모리의 로그, 임시 폴더의 진단 파일, 다른 기기에서 받아 둔 로그 묶음, (Debug 빌드) Mac에 보내지 못해 쌓아 둔 기록.
- 동의 여부는 앱 데이터 폴더의 `RemoteDebugFeedback/recording-consent`라는 빈 파일이 있느냐로 남긴다. `UserDefaults`를 쓰지 않는다.
- 코드에서 다룰 때: `RemoteDebugFeedback.hasRecordingConsent`, `isRecordingAllowed`, `requiresRecordingConsent`, `setRecordingConsent(_:)`, `deleteRecorded()`. `setRecordingConsent(true)`는 사용자가 설명을 읽고 동의한 뒤에만 부른다.
- Debug 빌드는 동의 없이 남긴다. 동의 화면을 Debug 빌드에서 확인하려면 `Configuration(requiresConsentInDebug: true)`로 시작한다.
- 문구는 `RemoteDebugFeedbackLabels().consent`(`RemoteDebugFeedbackConsentLabels`)에서 바꾼다. 기본 설명은 기기 언어로 보이고 이 패키지가 하는 일만 말한다. 앱이 `log`에 무엇을 넣는지에 맞게 `explanation`을 고쳐 쓴다(고쳐 쓴 글은 앱이 번역한다).
- 동의는 기기마다 따로다. iPhone에서 동의해도 Apple Watch의 패키지는 모른다. 스위치의 `onChange`에서 앱이 Watch에 동의를 전해 그쪽에서 `setRecordingConsent`를 부르고, 끌 때도 전해서 그쪽 기록을 지운다("다른 기기의 로그 함께 보내기").

## 무엇을 남기고 보내는가

| 항목 | 한도 | 어디에 |
| --- | --- | --- |
| `log`로 남긴 줄 | 최근 500줄, 한 줄 2,000자 | 메모리. 앱을 끄면 사라진다 |
| 보낼 때 모으는 로그 | 위의 줄과 이 앱의 최근 15분 시스템 로그를 합쳐 최근 300줄 | 보낼 때만 만든다 |
| 암호화한 진단 파일(`.afdiag`) | 평문 2MB까지, 기기에 한 개 | 임시 폴더 `AppFeedback`. 앱을 시작할 때와 새로 만들기 전에 지운다 |
| 사용자가 고른 사진과 파일 | 5개, 하나 1MB, 합쳐 1.5MB. 사진은 300KB 아래로 줄인다 | 보낼 때까지 메모리 |
| Mac에 보내지 못한 기록(Debug) | 30개, 합쳐 16MB | 앱 데이터 폴더 `RemoteDebugFeedback` |
| 확인 목록의 답(Debug) | 항목 50개, 메모 200자 | 앱 데이터 폴더 `RemoteDebugFeedbackChecks` |

- 글은 비어 있어도 된다. 첨부, 로그, 확인 목록의 답 가운데 하나가 있으면 보낼 수 있다. Mac에는 첫 줄이 `(글 없이 보냄)`인 기록으로 들어간다.
- 화면을 저절로 찍지 않는다. 사진과 파일은 사용자가 고른 것만 붙는다.
- 앱 버전과 빌드 번호, OS 버전(`iOS 18.1`), 기기 종류(`iPhone16,2` 같은 모델 식별자)가 함께 간다. 사용자가 붙인 기기 이름, 계정, 광고 식별자는 읽지 않는다.
- 메일 본문은 이 차례다(영어 기기의 예). 제목(`Sample feedback`, 한국어 기기에서는 `Sample 피드백`)과 `---` 아래 첫 줄은 기기 언어를 따르고, 줄 이름 `App:`·`OS:`·`Device:`와 표시 줄 `[rdfeedback:<번들 ID>:<빌드>]`는 어느 언어든 같아서 메일함 검색에 쓴다.

  ```
  <사용자가 쓴 글>

  ---
  The information below is used only to look into this problem and may be deleted.
  App: Sample 1.2 (3)
  OS: iOS 18.1
  Device: iPhone16,2
  [rdfeedback:com.example.sample:3]
  ```

  안내 줄은 `labels.mail.usageNotice`에 값을 넣어 바꿀 수 있다.
- 메일 계정이 없는 기기에서는 `mailto:` 링크를 연다. 링크로는 파일을 붙일 수 없어서, 화면이 그 사실을 알리고 사진·파일은 메일 앱에서 직접 붙이게 한다.

## 첨부

- 사진은 긴 변 1,600픽셀 아래의 JPEG로 다시 만들어 붙인다. 이때 위치 같은 사진 정보는 빠진다.
- 사진이 아닌 파일은 그대로 붙는다. 파일 안의 정보는 패키지가 지우지 않는다.
- 첨부는 암호화하지 않는다. 메일에서는 작성 화면에 그대로 보이고, 암호화되는 것은 로그가 든 진단 파일뿐이다.
- 사진에는 다른 사람이 찍혀 있을 수 있다. 사용자가 직접 골라 붙인다는 점을 처리방침에 적는다.

## 문구와 언어

패키지의 기본 문구는 기기 언어를 따른다. 한국어, 영어, 일본어, 중국어 간체, 중국어 번체가 들어 있고, 그 밖의 언어에서는 영어로 보인다.

- 문구는 패키지 묶음(`RemoteDebugFeedback_RemoteDebugFeedback.bundle`)의 문자열 카탈로그 `Localizable.xcstrings`에 있다. 앱의 묶음이 아니라 패키지 묶음에서 읽으므로 앱에 번역을 넣지 않아도 된다.
- 언어는 사용자가 정한 언어 차례(설정의 앱별 언어 포함)에서 카탈로그에 있는 첫 언어를 고른다. 앱 자체가 그 언어로 번역돼 있지 않아도 패키지 문구는 그 언어로 보인다. 예를 들어 영어로만 만든 앱도 한국어 기기에서는 피드백 화면과 메일 제목이 한국어다.
- 개수와 크기 한도("사진과 파일을 5개까지…")는 문구 안의 자리표시에 코드의 한도 값을 채운다. 영어는 단수와 복수를 가린다.
- 일본어와 중국어 문구는 기계가 옮긴 것이고 그 언어를 쓰는 사람이 읽어 보지 않았다.

### 앱의 문구로 바꾸기

문구 묶음의 값을 바꿔 넣으면 그 값이 언어와 상관없이 그대로 보인다. 바꾸지 않은 값은 계속 기기 언어를 따른다. 앱의 번역을 쓰려면 앱의 카탈로그에서 꺼낸 글을 넣는다.

```swift
var labels = RemoteDebugFeedbackLabels()
labels.title = String(localized: "문제 알리기")
labels.mail.usageNotice = String(localized: "아래 정보는 이 문제를 살펴보는 데만 씁니다.")
labels.consent.explanation = String(localized: "화면 이름과 오류 번호만 남깁니다. …")

.remoteDebugFeedback(isPresented: $showsFeedback, labels: labels)
RemoteDebugFeedbackConsentSection(labels: labels.consent)
```

- 화면: `RemoteDebugFeedbackLabels`. 메일과 상태 글: 그 안의 `mail`(`FeedbackLabels`). 동의 스위치: `consent`(`RemoteDebugFeedbackConsentLabels`).
- 메일 제목은 `FeedbackSession`을 직접 만들 때 `content`로 넘기는 `FeedbackContent(subject:body:)`에서 바꾼다. 피드백 화면은 기본 제목(`<앱 이름> 피드백`, 기기 언어)을 쓴다.

### 언어와 상관없이 같은 글

아래는 일부러 번역하지 않는다. 받는 쪽이 글자 그대로 찾거나 읽기 때문이다.

| 글 | 어디에 | 까닭 |
| --- | --- | --- |
| `App:`, `OS:`, `Device:` | 메일 본문의 줄 이름 | 메일함 검색과 본문을 읽는 도구가 이 글자에 기댄다 |
| `[rdfeedback:<번들 ID>:<빌드>]` | 메일 본문의 표시 줄 | 제목이 어느 언어든 같은 글로 찾는다 |
| `(글 없이 보냄)`, `앱:`, `기기:`, `보낸 시각:`, `첨부:`, `최근 로그` | Debug 빌드가 Mac으로 보내는 기록의 글 | Mac 앱이 이 줄로 글·기기 정보·로그를 가르고(`FeedbackIssue`), 에이전트가 같은 원문을 읽는다. 사용자의 화면에는 보이지 않는다 |
| `통과`, `실패`, `확인 못함` | 확인 목록의 기본 답으로 저장하고 보내는 값 | 기기의 `answers.json`과 Mac에 이 글자로 남고, Mac의 기본 답과 같아야 하며, `확인 못함`으로 해 보지 못함을 가린다. 화면에 보이는 이름만 기기 언어를 따른다(`labels.mail.passed`, `failedCheck`, `untested`) |
| `unchecked`, `passed`, `failed`, `untested`, 진단 파일의 키 | 메일에 붙는 암호화한 진단 파일 | Mac 앱이 읽는 형식이다 |
| OS 이름과 버전(`iOS 18.1`), 기기 종류(`iPhone16,2`), 파일 이름(`photo-1.jpg`, `feedback-….afdiag`) | 메일과 기록 | 값이지 문구가 아니다 |

Debug 빌드 전용 문구(Mac으로 보내는 길, 확인 목록)도 다섯 언어로 보이지만, 카탈로그가 아니라 `#if DEBUG` 안의 코드(`FeedbackDebugStrings`)에 있다. 카탈로그는 리소스라서 배포판 묶음에도 들어가는데, 이 문구는 배포판에 있으면 안 되기 때문이다.

## 확인 목록(Debug 빌드)

실기기에서 사람이 확인해야 하는 것을 피드백 화면 위쪽에 보여 주고, 고른 답을 피드백과 함께 보낸다.

- 앱이 코드로 정하거나(`RemoteDebugFeedback.checklist`), 에이전트가 Mac에 남긴다(`remotedebug_feedback_checklist`, `rd checklist <번들 ID> <항목 JSON 파일>`). Mac에 남긴 목록이 있으면 그것이 보인다.
- 마지막으로 받은 목록을 기기에 남겨 두므로 Mac에 닿지 않는 곳에서도 보인다.
- 고를 답을 주지 않으면 `통과`, `실패`, `확인 못함`이다. `확인 못함`은 해 보지 못했다는 답이라, 실패나 잊은 것과 섞이지 않는다. 이 셋은 화면에서 기기 언어의 이름(영어 기기에서 `Passed`, `Failed`, `Could not test`)으로 보이지만, 저장하고 Mac에 보내는 값은 언제나 이 한국어 글자다. 목록이 따로 정한 답은 적힌 그대로 보이고 그대로 간다.
- 메모만 적은 항목은 답한 것으로 세지 않는다.
- **답하지 않은 것만 보기**로 남은 항목만 볼 수 있고, **답 모두 지우기**로 처음부터 다시 답할 수 있다.
- 항목의 `since`(그 항목이 바뀐 빌드 번호)보다 앞선 빌드에서 고른 답은 세지 않고 "바뀌기 전 빌드에서 고른 답"으로만 보인다.
- 메일로 보낼 때는 답이 암호화한 진단 파일 안에 들어간다.

항목을 쓰는 규칙과 받은 피드백을 다루는 규칙은 Mac 앱이 에이전트에게 주는 안내(스킬과 도구 설명)에 있다.

## 다른 기기의 로그 함께 보내기

Apple Watch 앱이 있는 앱은 Watch가 남긴 로그를 iPhone의 피드백에 함께 붙일 수 있다. 패키지는 watchOS 10 이상에서도 빌드된다(Watch에서는 로그와 동의, 묶음 만들기만 쓴다. 피드백 화면은 iPhone에만 있다). 기기 사이로 옮기는 일은 앱이 WatchConnectivity로 한다.

```swift
// Watch: iPhone이 요청하면, 또는 운동이 끝났을 때 묶음을 만들어 보낸다.
if let data = await RemoteDebugFeedback.capturePeerReport(source: "watch") {
    session.sendMessageData(data, replyHandler: nil)        // 답으로 돌려주거나 transferUserInfo로 보낸다
}

// iPhone: 받은 묶음을 넘긴다. 기기 이름마다 가장 최근에 수집한 하나만 남는다.
RemoteDebugFeedback.storePeerReport(data)

// iPhone: 보낼 때 Watch에 지금 요청하는 방법을 앱 시작 때 정해 둔다.
RemoteDebugFeedback.setPeerRequest {
    await watchLink.requestReport().map { [$0] } ?? []      // 닿지 않으면 빈 배열
}
```

- 사용자가 **최근 로그 붙이기**를 켜고 보내면 패키지가 `setPeerRequest`로 정한 요청을 부르고 3초까지 기다린다. 그 안에 온 묶음은 "보내면서 요청해 받음"으로 붙는다. 답이 없으면 앞서 받아 둔 묶음이 "요청에 답이 없어 N분 전에 받아 둔 기록"이라는 글과 함께 붙는다. 늦게 온 답은 받아 두어 다음에 쓴다.
- 묶음마다 기기 종류, OS, 앱 버전, 수집한 시각(그 기기의 시계), iPhone이 받은 시각, 담긴 첫 줄과 마지막 줄의 시각, 줄 수, 한도에 걸려 앞부분이 빠졌는지가 함께 간다. 받는 사람은 이것으로 묶음이 문제의 시각을 담고 있는지 본다.
- Mac으로 바로 보낼 때는 글의 `최근 로그` 아래에 `기기 기록: watch (…)` 단락으로 붙고, 메일로 보낼 때는 암호화한 진단 파일의 `peers`에 들어간다.
- 한도: 묶음 하나 256 KiB(넘으면 오래된 줄부터 빠진다), 받아 두는 기기 3개. 받아 둔 묶음은 앱 데이터 폴더의 `RemoteDebugFeedback/peers/`에 기기 이름마다 파일 하나로 있고, 새 묶음이 오면 덮어쓴다.
- 동의가 없는 기기는 묶음을 만들지 않고(`capturePeerReport`가 `nil`), 동의가 없는 iPhone은 받은 묶음을 두지 않는다. iPhone에서 동의를 끄면 받아 둔 묶음이 지워진다. Watch에 남은 로그를 지우는 것은 앱이 Watch에 알려 그쪽에서 `setRecordingConsent(false)`를 불러야 한다. 닿지 않으면 다음에 닿을 때 전한다.
- 운동처럼 끝난 뒤에 Watch가 닿지 않는 일이 잦으면, 끝날 때 Watch가 먼저 묶음을 보내 두게 한다. 그러면 요청에 답이 없어도 그 운동이 담긴 묶음이 붙는다.

## 앱이 맡아야 하는 것

패키지가 대신할 수 없는 일이다.

- **무엇을 로그에 넣을지.** 패키지는 `log`에 넘긴 글을 그대로 남긴다. 건강 수치, 위치와 좌표, 사용자가 입력한 글, 이름, 계정, 토큰은 넣지 않는다. 상태 이름, 개수, 걸린 시간처럼 사람을 가리키지 않는 값만 넣는다. `os.Logger`로 남기는 줄도 보낼 때 함께 모이므로 같은 기준으로 쓴다.
- **앱마다 다른 키.** 공개키는 Mac 앱이 프로젝트마다 따로 만들고, 개인키는 그 Mac의 키체인에만 둔다. 여러 앱이 키 하나를 함께 쓰지 않는다. 개인키를 저장소에 올리지 않는다.
- **받는 메일 주소와 문구.** 주소는 앱이 정한다. 화면 문구는 기본값이 기기 언어를 따르고, 앱이 바꿔 넣을 수 있다("문구와 언어"). 동의 설명은 앱이 로그에 남기는 것에 맞게 앱이 고쳐 쓴다.
- **다른 기기.** Watch 같은 짝 기기와 주고받는 일(전송, 동의 전달, 끌 때 지우라고 알리기)은 앱이 한다. 패키지는 묶음을 만들고 받아 두고 합친다("다른 기기의 로그 함께 보내기").
- **개인정보 처리방침과 App Store 답변.** 아래 점검 목록을 따른다.
- **배포판 확인.** 아래 "배포 전 확인"을 릴리스 절차에 넣는다.

## 개인정보 처리방침 점검 목록

앱의 처리방침과 App Store Connect의 개인정보 답변에서 확인할 것이다. 문구는 공개하기 전에 책임자가 읽는다.

- [ ] 피드백으로 받는 것: 사용자가 쓴 글, 사용자가 고른 사진과 파일, 앱 버전과 빌드, OS 버전, 기기 종류.
- [ ] 로그: 동의한 사용자의 기기에만 남고, 사용자가 보낼 때 붙이기를 켠 경우에만 암호화해 보낸다는 것. 무엇이 로그에 들어가는지.
- [ ] 쓰는 목적: 문의한 문제를 살펴보는 데만 쓴다는 것.
- [ ] 보관 기간: 기기에는 위 표의 한도만큼만 남고, 개발자가 받은 파일은 문의를 처리한 날부터 90일 뒤에 지운다는 것.
- [ ] 동의를 거두는 방법(설정의 스위치)과, 거두면 기기의 기록이 지워진다는 것.
- [ ] 이미 보낸 것을 지워 달라고 요청할 연락처. 피드백을 받는 주소와 같은 주소로 맞춰 두면 찾기 쉽다.
- [ ] 메일로 보내므로 보낸 사람의 메일 주소가 개발자에게 보인다는 것.
- [ ] App Store 개인정보 답변: **정해지지 않은 점이 있다.** 사용자가 동의하고, 직접 붙여, 자기 메일 앱으로 보내는 암호화된 진단 파일이 "수집하는 진단 데이터(Diagnostics)"에 해당하는지는 결론이 나지 않았다. 결론이 날 때까지는 해당한다고 보고(진단 데이터를 수집한다고 답하고) 준비한다. 사진·파일과 메일 주소도 같은 눈으로 본다.
- [ ] 패키지의 개인정보 매니페스트는 수집 데이터 종류를 적지 않는다(아래). 위에서 수집한다고 정했다면 앱의 `PrivacyInfo.xcprivacy`에 앱이 적는다.

## 개인정보 매니페스트

패키지는 `PrivacyInfo.xcprivacy`를 리소스로 갖고 있어, 앱을 빌드하면 `RemoteDebugFeedback_RemoteDebugFeedback.bundle` 안에 들어간다.

- 추적: 하지 않는다(`NSPrivacyTracking`이 `false`, 추적 도메인 없음).
- 이유를 적어야 하는 API(`NSPrivacyAccessedAPITypes`): 없다. 배포 빌드의 코드는 `UserDefaults`, 파일 시각(생성·수정 날짜, `stat` 계열), 시스템 가동 시간, 디스크 남은 공간을 쓰지 않는다. 파일 크기는 `fileSizeKey`로만 읽는데, 이것은 Apple의 목록에 없다.
- 수집 데이터 종류(`NSPrivacyCollectedDataTypes`): 비워 두었다. 패키지는 어디로도 보내지 않고, 사용자가 자기 메일로 앱 개발자에게 보낸다. 무엇을 수집한다고 적을지는 위 점검 목록대로 앱이 정한다.

패키지를 고쳐 위 API를 쓰게 되면 매니페스트도 함께 고친다. 기준은 Apple 문서 "Describing use of required reason API"다.

## 암호화와 수출 규정

배포 빌드는 로그를 붙일 때 Apple의 CryptoKit으로 암호화한다(HPKE: X25519, HKDF-SHA256, ChaCha20-Poly1305). 패키지에 직접 구현한 암호 알고리즘은 없다.

App Store Connect의 수출 규정 질문(`ITSAppUsesNonExemptEncryption`)에 어떻게 답할지는 이 사실과 앱의 나머지 부분을 놓고 직접 확인한다. 이 문서는 결론을 내리지 않는다.

## 받은 것의 보관과 삭제

- 개발자가 받은 기록과 첨부는 문의를 처리한 날부터 90일 뒤에 지운다.
- Mac 앱의 **크래시·피드백** 화면에서 기록을 고르고 **처리함으로 표시**를 누르거나, 에이전트가 `rd handled <기록 id>`(MCP는 `remotedebug_crash_logs`에 `id`와 `handled: true`)로 표시한다. 그날부터 90일이 지나면 Mac 앱이 그 기록과 첨부 파일을 지운다. 지우는 때는 앱을 켤 때, 새 기록을 받을 때, 목록을 볼 때다.
- 표시하지 않은 기록은 수 한도(전체 200개, 기기마다 50개)로만 밀려난다. 문의를 끝냈으면 표시해야 90일 규칙이 지켜진다.
- 메일함에 남은 메일과 첨부, 풀어서 다른 곳에 둔 파일은 Mac 앱이 지우지 못한다. 같은 기준으로 직접 지운다.
- 풀어 낸 로그는 개인 정보로 다룬다. 읽은 뒤 지우고, 저장소나 이슈에 올리지 않는다.

## 받은 피드백을 이슈로 올리기

RemoteDebug Mac 앱이 받은 피드백을 그 앱의 GitHub 저장소에 이슈로 올릴 수 있다. 저장소와 자동 등록은 Mac의 주인이 Mac 앱의 앱 화면에서 프로젝트의 더 보기 메뉴 > **이슈 저장소…**로 정한다. 에이전트는 `rd issue-target <프로젝트 폴더>`로 지금 값을 읽을 수만 있고 바꾸지 못한다. 이 Mac에 GitHub CLI(`gh`)가 설치되어 로그인돼 있어야 한다.

- 이슈에는 사용자가 쓴 글, 앱 버전과 빌드, OS, 기기 종류, 받은 시각, 확인 목록의 답, 첨부 수와 로그가 붙었는지만 올라간다. 로그와 첨부 파일, 기기 이름은 올라가지 않는다. 공개 저장소면 이 내용을 누구나 본다.
- 글과 확인 목록의 답은 올리기 전에 가린다. 주소(`스킴://…`)는 모두 `[주소]`로 가리고, `https://github.com/<owner>/<repo>`와 그 아래의 `/issues`, `/issues/<번호>`, `/pull/<번호>`만 남긴다(쿼리, 조각, 포트, 로그인 정보가 붙으면 가린다). 그 밖에 메일 주소(`@`의 앞뒤에 글자가 붙은 것), 토큰(`Bearer`, JWT, `ghp_`·`github_pat_`·`sk-`·`xox?-`·`AKIA`, 16진수·base64 32자 이상), 경로(줄 끝까지), IP와 MAC 주소, 기기 UDID, 호스트 이름(`.ts.net`, `.local`, `rd-mac-…`, `호스트:포트`), 전화번호처럼 보이는 숫자열을 가린다. 규칙이 넉넉해서 긴 식별자나 `이름:숫자` 같은 글도 가려질 수 있다. 가린 결과는 **이슈로 등록…**의 미리보기에서 볼 수 있다.
- **자동 등록**은 주인이 켜기 전에는 꺼져 있다(저장소를 정하는 것만으로는 켜지지 않는다). 켜져 있으면 Debug 빌드가 Mac으로 바로 보낸 피드백이 받는 대로 올라간다. 프로젝트마다 한 시간에 5개까지이고, 넘는 기록은 올리지 않은 채 까닭을 보이며 직접 올릴 수 있다. 원문에서 사용자가 쓴 글과 로그를 가를 수 없는 기록(글을 따로 적어 보내지 않는 옛 패키지가 `---` 줄 없이 보낸 것)은 저절로 올라가지 않고, 미리보기에서 글을 직접 적어야 한다. 메일로 온 진단 파일(`.afdiag`)에서 넣은 기록은 저절로 올라가지 않는다. **크래시·피드백** 화면의 **이슈로 등록…**이 제목과 본문을 보여 주고, 고친 뒤 **등록**을 눌러야 올라간다. 메일 본문의 글은 진단 파일에 없으므로 필요하면 그때 옮겨 적는다.
- 에이전트는 `rd issue <기록 id>`로 올라갈 내용을 먼저 보고 `rd issue <기록 id> confirm`으로 올린다. 같은 기록은 한 번만 올라간다.
- 메일 경로(배포 빌드)의 처리방침에는 받은 글의 요약을 개발자의 이슈 관리 도구에 옮길 수 있다는 점을 앱에 맞게 적는다.

## 예제 앱으로 실기기 확인

저장소의 `Examples/FeedbackSample/FeedbackSample.xcodeproj`(스킴 `FeedbackSample`, iOS 17 이상, 번들 ID `$(RD_BUNDLE_PREFIX).FeedbackSample`)는 이 패키지를 로컬 경로로 넣은 작은 앱이다. 피드백 화면을 여는 단추, 설정 화면의 동의 스위치, 코드로 정한 확인 목록(세 항목, 두 묶음), 로그 남기기 단추, 빌드 번호가 있다.

1. `Config/Signing.local.xcconfig`에 개발 팀(`DEVELOPMENT_TEAM`)이 있어야 한다(RemoteDebug iPhone 앱과 같은 파일이다).
2. RemoteDebug Mac 앱에 `Examples/FeedbackSample` 폴더를 연결하고 `rd feedback <그 폴더> [메일]`로 코드를 받는다. 그 코드의 `macHost`와 `publicKeyBase64` 값을 같은 `Config/Signing.local.xcconfig`에 넣는다. 이 값들은 저장소에 올리지 않는다.

   ```
   RD_FEEDBACK_MAC_HOST = rd-mac-1a2b3c4d.tail0001.ts.net
   RD_FEEDBACK_PUBLIC_KEY = <공개키(base64)>
   RD_FEEDBACK_EMAIL = dev@example.com
   ```

   `RD_FEEDBACK_EMAIL`은 없어도 된다(Mac에 닿지 않을 때와 Release 구성에서 메일로 받을 주소). xcconfig는 `//`부터 줄 끝을 주석으로 읽으므로 공개키에 `//`가 있으면 그 자리를 `/$()/`로 적는다.
3. Mac 앱에서 스킴 `FeedbackSample`을 빌드해 게시하고 iPhone에 설치한다. 첫 화면의 "피드백을 보내는 곳"이 지금 빌드의 경로를 보여 준다.
4. Mac 주소는 Debug 구성의 Info.plist(`RDFeedbackMacHost`)에만 들어간다. Release 구성으로 빌드한 앱에는 주소가 없고, `scripts/check-feedback-release.sh`로 확인할 수 있다.

## 배포 전 확인

1. 배포판 실행 파일에 Debug 전용 코드와 Mac 주소가 없는지 확인한다. 저장소의 `scripts/check-feedback-release.sh`를 릴리스 절차에서 부른다.

   ```sh
   scripts/check-feedback-release.sh --host rd-mac-1a2b3c4d.tail0001.ts.net <스토어에 올릴 App.app 또는 App.ipa>
   ```

   확인 목록과 Mac 전송의 이름·경로·문구, `rd-mac-…`과 `.ts.net` 주소(대소문자를 가리지 않는다)를 찾으면 종료 코드 1로 끝난다. `.ipa`와 `.zip`은 임시 폴더에 풀어서 본다. 패키지가 아예 들어 있지 않은 경로를 주면(다른 폴더를 준 경우가 많다) 실패로 끝나고, 패키지 없는 빌드를 일부러 확인하려면 `--allow-absent`를 붙인다. 파일을 읽지 못하거나 묶음을 풀지 못하면 종료 코드 3이다. 패키지를 올린 뒤에는 같은 앱의 Debug 빌드에 `--expect-debug`로 돌려, 찾는 표시가 아직 맞는지 본다. `scripts/test-check-feedback-release.sh`가 이 스크립트의 갈래를 모두 시험한다.

   **스토어에 올리는 바로 그 구성으로 만든 결과물에 돌린다.** 패키지는 구성의 이름이 아니라 컴파일 조건 `DEBUG`로 갈린다. Debug를 복사해 만든 `Beta`나 `Staging` 같은 구성에 `DEBUG`가 남아 있으면(Swift Compiler - Custom Flags의 Active Compilation Conditions), 그 구성으로 만든 앱에는 Mac으로 보내는 코드와 확인 목록이 들어가고 로그 기록 동의도 묻지 않는다. Release 구성을 따로 빌드해 확인한 것으로는 그 앱을 확인한 것이 아니다. 보관(Archive)한 앱이나 내보낸 `.ipa`를 그대로 넘긴다.
2. 동의하지 않은 상태에서 피드백 화면에 **최근 로그 붙이기**가 보이지 않는지 본다.
3. 동의를 켰다 끄면 설정이 꺼진 채로 남는지 본다.
4. 처리방침 점검 목록을 마쳤는지 본다.

## 확인하지 않은 것

- 다른 기기의 로그 함께 보내기: 실제 Apple Watch와 WatchConnectivity로는 확인하지 않았다. 단위 시험과 watchOS·iOS 빌드(Debug와 배포 구성)만 했다.
- 실기기의 메일 작성 화면에서 암호화한 진단 파일과 사진이 함께 붙는지, 메일 계정이 없는 기기의 `mailto:` 흐름.
- 동의 스위치와 확인 목록의 거르기·지우기 화면(단위 시험과 컴파일만 했다).
- 언어마다 실기기 화면에 문구가 어떻게 보이는지(줄바꿈, 잘림). 문구가 다섯 언어의 묶음에 있고 자리표시가 채워지는 것은 단위 시험으로 봤다. 일본어와 중국어 문구는 그 언어를 쓰는 사람이 읽어 보지 않았다.
- 받은 피드백을 실제 `gh`로 이슈에 올리는 것(가짜로 바꾼 단위 시험만 했다), 예제 앱의 서명한 빌드와 실기기 설치.
- 앱 보관(archive) 결과물에서 개인정보 매니페스트가 Xcode의 개인정보 보고서에 잡히는지.
