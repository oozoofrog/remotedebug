# RemoteDebug 프로토콜 (v1)

Mac 호스트와 iPhone 클라이언트가 공유하는 계약이다. Mac 앱과 호스트 노드 사이의 Swift 경계(`HostCore`)도 §9–§10에서 다룬다. 구현은 이 문서를 따르고, 바꿀 때는 이 문서를 먼저 고친다.
JSON 키는 camelCase, 시각은 UTC ISO-8601(`Z`), 문자열은 UTF-8이다.

## 1. 역할과 용어

| 용어 | 뜻 |
| --- | --- |
| 호스트 | Mac 앱. 내장 Swiftail 노드로 tailnet에 올라 HTTPS로 빌드를 제공한다. |
| 클라이언트 | iPhone 앱. 패킷 터널 확장 안의 Swiftail 노드로 tailnet에 올라 호스트를 호출한다. 공식 Tailscale 앱으로 연 설치 웹 페이지(addenda E)도 클라이언트다. |
| 노드 | tailnet 안의 기기. 호스트는 연결의 원격 노드 신원(`StableID`, 노드 이름, 로그인 이름)으로 식별하고, 이 신원은 호스트의 Swiftail 노드가 알려 준다. |
| 허용 목록 | 호스트가 승인한 클라이언트 노드 목록. 이 목록에 없는 노드는 어떤 빌드도 보거나 받을 수 없다. |
| 빌드 | 호스트에 게시된 개발 서명 IPA 한 개와 그 메타데이터(`BuildDescriptor`). |
| 설치 세션 | 허용된 노드 하나가 빌드 하나를 받기 위해 여는 1회용·만료형 권한. 토큰으로 구분한다. |

노드 이름은 `rd-mac-<id8>`, `rd-phone-<id8>`이다. `<id8>`은 앱이 처음 실행할 때 만들어 저장하는 무작위 4바이트의 16진수다.
호스트는 tailnet TCP 443에서 TLS(MagicDNS 인증서)로 응답한다. 호스트 주소는 `https://<fqdn>`이다.

## 2. 페어링 동선

페어링은 두 동선이 있고 사용자가 iPhone의 상황으로 고른다. 어느 쪽이든 승인은 호스트 화면에서만 하고, 승인되면 그 노드가 허용 목록(§5)에 들어간다. 권한 판정은 허용 목록 하나로 한다.

| 동선 | iPhone | 절차 | 상세 |
| --- | --- | --- | --- |
| 앱 QR | RemoteDebug 앱이 있다 | 호스트가 QR·링크(제안, `remotedebug://pair#…` 또는 연결 도메인 `https://<호스트><경로>#…`)를 연다 → 앱이 읽고 페어링 포트로 짝 맺기 → 양쪽 화면의 확인 숫자 6자리 비교 → 호스트에서 승인 | addenda B.5 |
| 설치 페이지 코드 | 앱이 아직 없다 | tailnet에 든 iPhone의 Safari로 설치 페이지(addenda E)를 연다 → 호스트가 연 8자 코드 입력 → 호스트에서 승인 → 페이지에서 RemoteDebug 앱 설치 → 앱은 앱 QR 동선으로 따로 페어링 | 아래, §4.3 |

설치 페이지 코드: 호스트가 코드 하나를 만든다(8자, Crockford base32, 표시는 `K7M2-9QXD`). 화면은 코드를 넣은 설치 페이지 링크 `https://<fqdn>/#code=<code>`를 QR과 복사 텍스트로, 코드 없는 주소와 코드를 글자로 보여 준다. 코드는 5분 뒤 만료되고 한 번만 쓸 수 있다. 잘못된 코드는 같은 코드에 5번까지만 시도할 수 있고 5번째 실패에 코드를 폐기한다. 에이전트 명령(`rd pair`, `remotedebug_pairing_code`)은 이 동선의 코드만 연다. 그 응답에는 코드, 설치 페이지 링크(`installPage`), 만료 시각, 쓰임 안내(`usage`)만 있다. iPhone 앱으로 여는 링크는 없다.

한 번에 한 동선만 열린다: 앱 QR을 열면 열린 코드를 닫고, 코드를 열면 열린 QR을 닫는다. 한쪽으로 요청이 오면 다른 쪽도 닫는다.

설치 페이지로 승인되는 것은 공식 Tailscale 앱의 노드다. RemoteDebug 앱은 자기 터널 확장의 Swiftail 노드(`rd-phone-<id8>`, 다른 `StableID`)로 호스트에 닿으므로, 앱을 설치한 뒤 앱 QR 동선으로 따로 페어링한다. iOS는 VPN 하나만 켜 두므로 앱의 VPN을 켜면 공식 앱의 VPN은 꺼진다.

## 3. 인증 규칙

모든 `/v1/*` 요청은 연결의 원격 노드 신원으로 노드를 확인한다.

| 구분 | 규칙 |
| --- | --- |
| 허용 목록 인증 | 노드 신원을 알 수 있고 노드 `StableID`가 허용 목록에 있어야 한다. 아니면 403 `not_paired`와 `denied` 이벤트. |
| 페어링 코드 인증 | 열려 있는 코드와 일치해야 한다. 아니면 403 `pair_code_invalid`. |
| 세션 인증 | 경로의 토큰이 열려 있는 세션과 같고, 요청 노드가 세션을 만든 노드와 같아야 한다. 아니면 403 `token_invalid`. |

출하 코드에는 인증을 건너뛰는 경로가 없다. 테스트는 가짜 tailnet(§11)을 쓴다.

상태를 바꾸는 요청(`/v1/*`의 `POST`, `PUT`, `DELETE`)에는 다음을 강제한다. 요청 본문이 있으면 `Content-Type`은 `application/json`이어야 하고(아니면 415 `unsupported_media_type`), `Sec-Fetch-Site`가 `cross-site`이거나 `Origin` 헤더가 호스트 자신의 주소와 다르면 403 `origin_not_allowed`다. 호스트 자신의 주소는 tailnet으로 온 요청에서는 `https://<fqdn>`(평문 시험 설정에서는 `http://`), 같은 네트워크 직접 연결에서는 `https://<요청의 Host>`다.

## 4. REST API

| 메서드·경로 | 인증 | 설명 |
| --- | --- | --- |
| `GET /v1/info` | 허용 목록 | 호스트 정보 |
| `GET /v1/builds` | 허용 목록 | 게시된 빌드 목록 |
| `POST /v1/pair/request` | 페어링 코드 | 페어링 요청 생성(호스트 사용자가 승인해야 확정) |
| `GET /v1/pair/request/{requestId}` | 요청한 노드 | 페어링 요청 상태 |
| `POST /v1/builds/{id}/sessions` | 허용 목록 | 설치 세션 생성 |
| `GET /v1/sessions/{sessionId}` | 세션을 만든 노드 | 세션 진행 상태 |
| `GET /i/{token}/manifest.plist` | 세션 | OTA 매니페스트(`text/xml`) |
| `GET /i/{token}/app.ipa` | 세션 | IPA(`application/octet-stream`, Range 지원) |

모든 응답에 `X-RD-Protocol: 1`을 붙인다. 오류는 §8 형식이다.

### 4.1 `BuildDescriptor`

```json
{
  "id": "b_9f3a1c2e",
  "bundleId": "com.example.app.Sample",
  "displayName": "Sample",
  "version": "1.4.0",
  "buildNumber": "128",
  "minOS": "26.0",
  "debug": true,
  "configuration": "Debug",
  "configurationEvidence": "path",
  "signing": {
    "teamId": "ABCDE12345",
    "profileName": "iOS Team Provisioning Profile: com.example.app.Sample",
    "profileExpires": "2027-05-01T00:00:00Z",
    "provisionedDeviceCount": 27,
    "getTaskAllow": true
  },
  "ipa": {
    "size": 52428800,
    "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
  },
  "publishedAt": "2026-11-11T09:00:00Z"
}
```

- `id` = `"b_"` + `sha256(bundleId + "\n" + ipa.sha256)`의 앞 8자리 16진수.
- `configurationEvidence`는 `path`(`<Config>-iphoneos` 폴더 이름), `debug-dylib`(`*.debug.dylib` 존재), `user-confirmed`(사용자가 Debug임을 직접 확인) 중 하나다.
- 클라이언트에는 IPA 경로를 절대 보내지 않는다. 게시 호출(§9)만 `ipaPath`를 받는다.

### 4.2 `GET /v1/info`, `GET /v1/builds`

```json
{
  "hostId": "h_4be0c7a1",
  "hostName": "작업용 Mac",
  "fqdn": "rd-mac-ab12cd34.example-tailnet.ts.net",
  "protocol": 1,
  "appVersion": "0.1.0",
  "buildCount": 1
}
```

```json
{
  "builds": []
}
```

### 4.3 페어링(설치 페이지 코드)

앱 QR 동선은 REST를 쓰지 않는다(addenda B.5). 그 동선으로 짝이 된 앱은 허용 목록 인증으로 `GET /v1/info`(§4.2)를 불러 아래 `host`와 같은 값(`hostId`, `hostName`, `fqdn`)을 얻는다.

```json
{
  "code": "K7M29QXD",
  "deviceName": "내 iPhone",
  "platform": "iOS 26.1",
  "clientVersion": "0.1.0"
}
```

`POST /v1/pair/request` 응답(202):

```json
{
  "requestId": "pr_7c1e55d0",
  "state": "pending",
  "expiresAt": "2026-11-11T09:07:00Z"
}
```

`GET /v1/pair/request/{requestId}` 응답. `state`는 `pending`, `approved`, `denied`, `expired`. `approved`일 때만 `host`가 있다.

```json
{
  "requestId": "pr_7c1e55d0",
  "state": "approved",
  "host": {
    "hostId": "h_4be0c7a1",
    "hostName": "작업용 Mac",
    "fqdn": "rd-mac-ab12cd34.example-tailnet.ts.net"
  }
}
```

호스트는 요청 시점의 노드 신원(`StableID`, 이름, 로그인 이름)을 요청에 묶어 두고 `pair-request` 이벤트로 알린다. 호스트 사용자가 승인해야 허용 목록에 들어간다. 요청 대기 시간은 120초다.

### 4.4 설치 세션

`POST /v1/builds/{id}/sessions` 응답(201):

```json
{
  "sessionId": "s_52d9a07e",
  "state": "created",
  "manifestUrl": "https://rd-mac-ab12cd34.example-tailnet.ts.net/i/Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE/manifest.plist",
  "installUrl": "itms-services://?action=download-manifest&url=https%3A%2F%2Frd-mac-ab12cd34.example-tailnet.ts.net%2Fi%2FZm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE%2Fmanifest.plist",
  "expiresAt": "2026-11-11T09:03:00Z"
}
```

`GET /v1/sessions/{sessionId}` 응답. `state`는 `created`, `manifest_served`, `downloading`, `completed`, `expired`, `failed`.

```json
{
  "sessionId": "s_52d9a07e",
  "buildId": "b_9f3a1c2e",
  "state": "downloading",
  "bytesServed": 10485760,
  "size": 52428800,
  "expiresAt": "2026-11-11T09:03:00Z"
}
```

세션 규칙:

- 토큰은 무작위 32바이트의 base64url(패딩 없음, 43자)이다. 세션은 만든 노드의 `StableID`에 묶인다.
- 세션 생성 때 호스트는 게시본 IPA의 크기와 SHA-256을 다시 확인한다. 다르면 409 `build_changed`.
- 만료는 생성 후 180초, IPA 요청이 시작되면 총 600초까지 연장한다.
- 매니페스트는 5번까지, IPA는 완료 전까지 여러 번(Range 재개 포함) 받을 수 있다. IPA 본문을 끝까지 한 번 보내면 `completed`가 되고 토큰은 즉시 무효다. 이후 요청은 410 `session_expired`.
- 호스트는 매니페스트·IPA 요청의 `User-Agent`와 노드를 `session` 이벤트에 남긴다(설치기가 실제로 접근했는지 확인하는 용도).

### 4.5 OTA 매니페스트

`GET /i/{token}/manifest.plist`는 아래 구조의 XML plist를 돌려준다. `url`은 같은 토큰의 `app.ipa` 절대 주소이고 반드시 `https`다.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key><string>software-package</string>
          <key>url</key><string>https://rd-mac-ab12cd34.example-tailnet.ts.net/i/TOKEN/app.ipa</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key><string>com.example.app.Sample</string>
        <key>bundle-version</key><string>1.4.0</string>
        <key>kind</key><string>software</string>
        <key>title</key><string>Sample</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
```

## 5. 허용 목록 항목 (`DeviceEntry`)

```json
{
  "id": "d_9c2e41b7",
  "name": "내 iPhone",
  "nodeStableId": "nSTABLE1CNTRL",
  "nodeName": "rd-phone-ab12cd34",
  "loginName": "user@example.com",
  "pairedAt": "2026-11-11T09:05:00Z"
}
```

Swift 앱이 허용 목록을 저장한다. 시작할 때 `HostCore.setDevices`로 호스트에 밀어 넣고, 승인되면 호스트가 `device-added` 이벤트를 보내 Swift 앱이 저장한다. 앱이 저장하기 전에 종료되면 그 기기는 다시 페어링해야 한다.

선택 필드 `directTokenHash`(같은 네트워크 직접 연결에 등록한 기기의 토큰 해시)는 [protocol-addenda.md](protocol-addenda.md)의 O.4에 있다. 등록하지 않은 기기에는 키가 없다.

선택 필드 `push`(기기의 APNs 토큰 등록: `token`, `bundleId`, `environment`)와 등록·삭제 경로 `PUT`·`DELETE /v1/devices/self/push-token`은 [protocol-addenda.md](protocol-addenda.md)의 P절에 있다. 등록하지 않은 기기에는 키가 없다. 두 리스너가 모두 받는다.

## 6. 클라이언트 동작 (iPhone)

터널 확장은 IP 패킷을 tailnet으로 중계하는 패킷 터널이다. 앱의 `URLSession`은 호스트의 REST API를 호출하고, 설치는 `installUrl`을 `UIApplication.open`으로 열어 iOS 설치기에 맡긴다. 터널·DNS·MTU 규칙은 [tunnel.md](tunnel.md)가 정한다. 터널 확장에는 호스트별 허용 목록이나 프록시가 없다.

## 7. 디버그 한정 정책 (`DebugBuildPolicy`)

호스트 앱은 게시 전에 아래를 모두 만족하는 빌드만 받는다. 하나라도 어기면 사유 코드와 함께 거부한다.

| # | 조건 | 거부 사유 코드 |
| --- | --- | --- |
| 1 | iOS 앱 번들(`DTPlatformName == iphoneos` 또는 `CFBundleSupportedPlatforms`에 `iPhoneOS`) | `not_ios_app` |
| 2 | 코드 서명이 있고 정적 검증을 통과 | `unsigned`, `invalid_signature` |
| 3 | 서명된 엔타이틀먼트의 `get-task-allow`가 `true` | `get_task_allow_missing` |
| 4 | `embedded.mobileprovision`이 있음 | `no_provisioning_profile` |
| 5 | 개발 프로필: `Entitlements.get-task-allow == true`, `ProvisionedDevices`가 비어 있지 않음, `ProvisionsAllDevices != true`, `aps-environment`가 없거나 `development` | `not_development_profile` (detail: `enterprise`, `ad_hoc`, `app_store`) |
| 6 | 프로필 `ExpirationDate`가 지나지 않음 | `profile_expired` |
| 7 | 구성: 앱이 `<Config>-iphoneos` 폴더 안에 있으면 `Config == "Debug"`(허용 구성 목록으로 확장 가능). 폴더 정보가 없으면 `*.debug.dylib` 존재로 갈음. 둘 다 없으면 사용자가 Debug임을 직접 확인해야 통과 | `configuration_not_debug`, `configuration_unverified` |
| 8 | 대상 기기 UDID가 주어졌다면 `ProvisionedDevices`에 포함 | `device_not_provisioned` |

호스트 로직(`RDHostLogic`)은 게시 호출에서 `debug == true`, `signing.getTaskAllow == true`, IPA 크기·SHA-256 일치를 다시 확인한다. 어기면 422 `not_debug_build` 또는 `hash_mismatch`.

## 8. 오류 형식과 코드

```json
{
  "error": {
    "code": "not_paired",
    "message": "허용 목록에 없는 기기입니다."
  }
}
```

| HTTP | code | 의미 |
| --- | --- | --- |
| 400 | `bad_request` | 형식 오류 |
| 403 | `not_paired` | 노드가 허용 목록에 없거나 노드 신원을 알 수 없음 |
| 403 | `pair_code_invalid` | 코드 없음·불일치·만료 |
| 403 | `token_invalid` | 토큰 불일치 또는 다른 노드 |
| 403 | `origin_not_allowed` | 상태를 바꾸는 요청의 출처가 호스트 자신과 다름(§3) |
| 404 | `build_not_found` | 없는 빌드 |
| 405 | `method_not_allowed` | 경로는 있지만 메서드가 다름 |
| 409 | `build_changed` | 서빙 직전 크기·SHA-256 불일치 |
| 410 | `session_expired` | 세션 만료 또는 완료 |
| 415 | `unsupported_media_type` | 상태를 바꾸는 요청의 본문이 `application/json`이 아님(§3) |
| 422 | `not_debug_build` | 게시 조건 위반 |
| 429 | `too_many_attempts` | 코드 시도 초과 |
| 500 | `internal` | 내부 오류 |

`HostCore` 경계에서 던지는 코드: `invalid_config`, `not_running`, `unknown_handle`, `path_outside_publish_dir`, `hash_mismatch`.

## 9. Mac 앱과 호스트 노드 사이의 Swift 경계 (`HostCore`)

Mac 앱의 모델(`HostModel`, `MacHostKit`)은 호스트 노드를 `HostCore` 프로토콜(`Packages/MacHost/Sources/MacHostKit/HostCore.swift`)로만 부른다. 실제 구현은 `SwiftailHostCore`(`MacHostCore`)다. 이것이 Swiftail 노드, 호스트 로직(`RDHostLogic`: 경로·페어링·세션·게시), HTTP 전송(`SwiftailHostServer`)을 묶는다. 시험은 같은 프로토콜의 가짜 구현이나 노드 층만 가짜인 실제 구현을 쓴다. 같은 프로세스 안의 Swift 호출이라 C 문자열이나 핸들은 없다. 실패는 `APIErrorBody`(§8 코드)를 던진다.

| 메서드 | 입력 | 결과 |
| --- | --- | --- |
| `start(_ config: CoreConfig)` | 아래 설정 | 노드와 호스트 로직을 시작한다. 이미 실행 중이면 `invalid_config` |
| `stop()` | | 노드를 멈추고 열린 세션을 `failed`로 끝낸 뒤 이벤트 스트림을 닫는다 |
| `status()` | | `CoreStatus`(아래 상태) |
| `publish(_:)` / `unpublish(buildID:)` | `PublishRequest`(`BuildDescriptor` + `ipaPath`) / 빌드 id | 없는 id의 `unpublish`는 `build_not_found` |
| `publishResource(_:)` / `unpublishResource(id:)` | 파일 게시(addenda H) | 없는 id의 `unpublishResource`는 `resource_not_found` |
| `setAgentBoard(_:)` | `GET /v1/agent`가 낼 JSON(addenda K) | |
| `setDevices(_:)` | `[DeviceEntry]`(허용 목록 전체) | 모델은 이 호출을 한 번에 하나씩 순서대로 보낸다 |
| `setDirect(_:)` | 켜기·끄기 | 같은 네트워크 직접 연결 리스너(addenda O). 결과는 다음 `status()`의 `direct` |
| `openPairing(ttlSeconds:)` | | `PairingCode`: `{"code":"K7M29QXD","expiresAt":"…"}`. 열린 앱 QR은 닫는다 |
| `openPairingOffer(_:)` | `PairingInviteRequest`(수명 초, OAuth 클라이언트) | `PairingInvite`(링크, QR 그림, 만료, 키 결과, tailnet lock 여부). 열린 코드는 닫는다(addenda B.5) |
| `closePairingOffer()` | | 열린 앱 QR을 닫는다 |
| `checkOAuthClient(_:)` | OAuth 클라이언트 | 형식이 틀렸으면 그 까닭. 관리 API에 보내지 않는다 |
| `decidePairing(requestID:allow:)` | | 두 동선의 요청을 함께 받는다. 승인하면 허용 목록에 들어간 `DeviceEntry`, 거절하면 `nil` |
| `events()` | | `start` 이후의 `CoreEvent` 스트림. `stop`하면 끝난다 |
| `logOut(_:)` | `CoreConfig` | 제어 서버에 이 노드의 로그아웃을 알린다. `stop()`이 끝난 뒤 상태 폴더를 지우기 전에 부르고, 실패해도 돌아온다 |

설정(`CoreConfig`):

```json
{
  "mode": "host",
  "stateDir": "/path/to/state",
  "hostname": "rd-mac-ab12cd34",
  "authKey": "",
  "controlURL": "",
  "ephemeral": false,
  "listenTLS": true,
  "port": 443,
  "publishDir": "/path/to/published",
  "allowedTargets": [],
  "goMemLimitMiB": 0,
  "logPath": ""
}
```

- `SwiftailHostCore`는 `mode`가 `host`일 때만 시작한다(다른 값은 `invalid_config`). `stateDir`와 `hostname`은 비면 안 되고 `port`는 1~65535, `controlURL`은 비었거나 `http(s)` 주소여야 한다(아니면 `invalid_config`). `controlURL`이 비면 Tailscale 기본 제어 서버를 쓴다.
- `listenTLS`가 `false`면 평문 HTTP로 듣고 인증서를 받지 않는다. 이때 매니페스트·설치 주소가 `http://`가 되므로 iOS 설치기는 쓸 수 없다. 시험 전용이다.
- `publishDir`: 게시본 IPA는 이 폴더 안의 일반 파일이어야 한다(아니면 `path_outside_publish_dir`). 호스트는 게시 시점에 크기·SHA-256을 계산해 `BuildDescriptor`의 값과 비교한다(아니면 `hash_mismatch`).
- `allowedTargets`, `goMemLimitMiB`와 터널 전용 필드(`utunFd`, `mtu`)는 Mac 호스트가 쓰지 않는다. `CoreConfig`의 JSON 키로만 남아 있다.
- 선택 필드 `hostDisplayName`, `appVersion`은 `/v1/info`에 실린다. 선택 필드 `directListen`: `true`면 시작할 때 같은 네트워크 직접 연결 리스너를 함께 연다. 없으면 열지 않는다. [protocol-addenda.md](protocol-addenda.md)의 O.1.

상태(`CoreStatus`):

```json
{
  "backendState": "Running",
  "authURL": "",
  "hostname": "rd-mac-ab12cd34",
  "fqdn": "rd-mac-ab12cd34.example-tailnet.ts.net",
  "tailscaleIPs": ["100.64.0.10"],
  "certDomains": ["rd-mac-ab12cd34.example-tailnet.ts.net"],
  "tlsReady": true,
  "listening": true,
  "publishedBuilds": 1,
  "pairedDevices": 1,
  "rssMiB": 31.5
}
```

`backendState`는 `Stopped`, `Starting`, `NeedsLogin`, `NeedsMachineAuth`, `Running`, `Error` 중 하나다. `NeedsLogin`이면 `authURL`을 채운다.

선택 필드 `peerPaths`(페어링한 기기까지의 경로, 직접·중계)와 터널의 `peerPath`는 [protocol-addenda.md](protocol-addenda.md)의 N.3에 있다. 값이 없으면 키도 없다.

선택 필드 `direct`(같은 네트워크 직접 연결 리스너의 `listening`, `port`, `id`)는 [protocol-addenda.md](protocol-addenda.md)의 O.1에 있다. 리스너를 켠 적이 없으면 키가 없다. 리스너를 켜고 끄는 `setDirect`와 이벤트 `device-updated`도 O절에 있다.

## 10. 이벤트

`HostCore.events()`가 내는 `CoreEvent`는 JSON으로 쓰면 `type` 필드로 구분한다.

```json
{
  "type": "pair-request",
  "requestId": "pr_7c1e55d0",
  "deviceName": "내 iPhone",
  "nodeName": "rd-phone-ab12cd34",
  "loginName": "user@example.com",
  "expiresAt": "2026-11-11T09:07:00Z"
}
```

| type | 추가 필드 |
| --- | --- |
| `state` | `status`(§9 상태) |
| `pair-request` | 위 예시. 앱 QR 요청은 Swift 값에 `confirmationCode`(확인 숫자 6자리)가 더 있다. 승인 화면에만 쓰고 JSON에는 싣지 않는다 |
| `pair-decided` | `requestId`, `state`(`approved`/`denied`/`expired`) |
| `device-added` | `device`(`DeviceEntry`) |
| `denied` | `path`, `reason`(오류 코드), `nodeName`(알 수 있을 때) |
| `session` | `sessionId`, `buildId`, `nodeName`, `state`, `userAgent`, `bytesServed` |
| `log` | `level`, `message` |

## 11. 가짜 tailnet 테스트

호스트 시험은 tailnet만 가짜로 둔다. 노드 층(`HostNodeLayer`)을 가짜로 바꿔 iPhone마다 루프백 평문 리스너를 하나씩 세우고, 그 리스너로 온 요청을 그 iPhone의 노드 신원으로 호스트 로직에 넘긴다(`Packages/MacHost/Tests/MacHostE2ETests`). 이 시험에는 Swiftail 노드, TLS, 인증서가 없다. 이때 매니페스트·설치 주소는 `http://`가 된다(iOS 설치기는 `https`만 받으므로 시험 전용). 실제 tailnet에는 사용자 허가 없이 노드를 추가하지 않는다.

## 12. 보안 속성과 비목표

- 허용 목록 밖의 노드는 목록·세션·IPA에 접근할 수 없다. 설치기의 요청도 세션을 만든 노드에서 온 것이어야 한다.
- 호스트는 디버그 조건을 만족하지 않는 IPA를 게시하지 않고, 서빙 직전에도 크기·해시를 확인한다.
- 상태를 바꾸는 요청은 JSON 본문과 같은 출처만 받는다(§3).
- tailnet ACL 태그(`tag:rd-mac`, `tag:rd-phone`)로 `tcp:443`만 허용하면 네트워크 층에서도 한 번 더 막을 수 있다(선택, docs/setup.md).
- 비목표: 침해된 Mac·iPhone 방어, 다중 사용자 권한, Apple 서명 외의 IPA 변조 방지, App Store 배포.
