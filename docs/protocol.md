# RemoteDebug 프로토콜 (v1)

Mac 호스트와 iPhone 클라이언트, 그리고 Go 코어(C API)가 공유하는 계약이다. 구현은 이 문서를 따르고, 바꿀 때는 이 문서를 먼저 고친다.
JSON 키는 camelCase, 시각은 UTC ISO-8601(`Z`), 문자열은 UTF-8이다.

## 1. 역할과 용어

| 용어 | 뜻 |
| --- | --- |
| 호스트 | Mac 앱. 내장 tsnet 노드로 tailnet에 올라 HTTPS로 빌드를 제공한다. |
| 클라이언트 | iPhone 앱. 패킷 터널 확장 안의 tsnet 노드로 tailnet에 올라 호스트를 호출한다. |
| 노드 | tailnet 안의 기기. WhoIs가 돌려주는 `StableID`로 식별한다. |
| 허용 목록 | 호스트가 승인한 클라이언트 노드 목록. 이 목록에 없는 노드는 어떤 빌드도 보거나 받을 수 없다. |
| 빌드 | 호스트에 게시된 개발 서명 IPA 한 개와 그 메타데이터(`BuildDescriptor`). |
| 설치 세션 | 허용된 노드 하나가 빌드 하나를 받기 위해 여는 1회용·만료형 권한. 토큰으로 구분한다. |

노드 이름은 `rd-mac-<id8>`, `rd-phone-<id8>`이다. `<id8>`은 앱이 처음 실행할 때 만들어 저장하는 무작위 4바이트의 16진수다.
호스트는 tailnet TCP 443에서 TLS(MagicDNS 인증서)로 응답한다. 호스트 주소는 `https://<fqdn>`이다.

## 2. 페어링 링크

호스트가 페어링을 열면 코드 하나를 만든다(8자, Crockford base32, 표시는 `K7M2-9QXD`). 화면에는 다음 링크를 QR과 복사 텍스트로 보여 준다.

```
remotedebug://pair?host=<fqdn>&code=<code>
```

코드는 5분 뒤 만료되고 한 번만 쓸 수 있다. 잘못된 코드는 같은 코드에 5번까지만 시도할 수 있고 5번째 실패에 코드를 폐기한다.

## 3. 인증 규칙

모든 `/v1/*` 요청은 호스트가 연결의 원격 주소로 WhoIs를 조회해 노드를 확인한다.

| 구분 | 규칙 |
| --- | --- |
| 허용 목록 인증 | WhoIs 성공 + 노드 `StableID`가 허용 목록에 있어야 한다. 아니면 403 `not_paired`와 `denied` 이벤트. |
| 페어링 코드 인증 | 열려 있는 코드와 일치해야 한다. 아니면 403 `pair_code_invalid`. |
| 세션 인증 | 경로의 토큰이 열려 있는 세션과 같고, 요청 노드가 세션을 만든 노드와 같아야 한다. 아니면 403 `token_invalid`. |

출하 코드에는 인증을 건너뛰는 경로가 없다. 테스트는 가짜 tailnet(§11)을 쓴다.

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

### 4.3 페어링

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

호스트는 요청 시점의 WhoIs 노드(`StableID`, 이름, 로그인 이름)를 요청에 묶어 두고 `pair-request` 이벤트로 알린다. 호스트 사용자가 승인해야 허용 목록에 들어간다. 요청 대기 시간은 120초다.

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

Swift 앱이 허용 목록을 저장한다. 시작할 때 `rd_host_set_devices`로 코어에 밀어 넣고, 승인되면 코어가 `device-added` 이벤트를 보내 Swift가 저장한다. 앱이 저장하기 전에 종료되면 그 기기는 다시 페어링해야 한다.

선택 필드 `directTokenHash`(같은 네트워크 직접 연결에 등록한 기기의 토큰 해시)는 [protocol-addenda.md](protocol-addenda.md)의 O.4에 있다. 등록하지 않은 기기에는 키가 없다.

선택 필드 `push`(기기의 APNs 토큰 등록: `token`, `bundleId`, `environment`)와 등록·삭제 경로 `PUT`·`DELETE /v1/devices/self/push-token`은 [protocol-addenda.md](protocol-addenda.md)의 P절에 있다. 등록하지 않은 기기에는 키가 없다. 두 리스너가 모두 받는다.

## 6. 클라이언트 동작 (iPhone)

1. 터널 확장이 `mode: "proxy"`로 노드를 시작하고 `rd_proxy_start("127.0.0.1:0")`로 로컬 HTTP CONNECT 프록시를 연다.
2. 확장이 `NEPacketTunnelNetworkSettings`에 `NEProxySettings`(HTTP·HTTPS 서버 = 로컬 프록시 주소, `matchDomains = ["ts.net"]`)를 넣는다. 터널 경로(`includedRoutes`)는 비워 둔다.
3. 프록시는 `allowedTargets`에 있는 `host:port`로의 CONNECT만 중계한다. 그 외 대상과 CONNECT가 아닌 요청은 거부한다. 페어링 링크를 읽는 순간 `allowedTargets`는 `["<fqdn>:443"]` 하나가 된다.
4. 앱의 `URLSession`은 시스템 프록시를 통해 호스트의 REST API를 호출한다. 설치는 `installUrl`을 `UIApplication.open`으로 열어 iOS 설치기에 맡긴다.

2~3의 시스템 프록시 경로가 iOS 설치기에도 적용되는지는 실기기에서만 확인할 수 있다(architecture.md의 가정 A1).

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

호스트(코어)는 게시 호출에서 `debug == true`, `signing.getTaskAllow == true`, IPA 크기·SHA-256 일치를 다시 확인한다. 어기면 422 `not_debug_build` 또는 `hash_mismatch`.

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
| 403 | `not_paired` | 노드가 허용 목록에 없거나 WhoIs 실패 |
| 403 | `pair_code_invalid` | 코드 없음·불일치·만료 |
| 403 | `token_invalid` | 토큰 불일치 또는 다른 노드 |
| 404 | `build_not_found` | 없는 빌드 |
| 409 | `build_changed` | 서빙 직전 크기·SHA-256 불일치 |
| 410 | `session_expired` | 세션 만료 또는 완료 |
| 422 | `not_debug_build` | 게시 조건 위반 |
| 429 | `too_many_attempts` | 코드 시도 초과 |
| 500 | `internal` | 내부 오류 |

C API 전용 코드: `invalid_config`, `not_running`, `unknown_handle`, `path_outside_publish_dir`, `hash_mismatch`.

## 9. 코어 C API (Go c-archive)

모든 함수는 NUL 종료 JSON 문자열(`char*`)을 돌려주고, 호출자가 `rd_free`로 해제한다. 실패는 `{"error":{"code":"…","message":"…"}}`다.

| 함수 | 입력 | 성공 출력 |
| --- | --- | --- |
| `rd_start(config_json)` | 아래 설정 | `{"handle":1}` |
| `rd_status(handle)` | | 상태 JSON |
| `rd_stop(handle)` | | `{"ok":true}` |
| `rd_host_publish(handle, build_json)` | `BuildDescriptor` + `ipaPath` | `{"ok":true,"id":"b_…"}` |
| `rd_host_unpublish(handle, build_id)` | | `{"ok":true}` |
| `rd_host_set_devices(handle, devices_json)` | `{"devices":[DeviceEntry]}` | `{"ok":true}` |
| `rd_host_pairing_open(handle, ttl_seconds)` | | `{"code":"K7M29QXD","expiresAt":"…"}` |
| `rd_host_pairing_decide(handle, request_id, allow)` | `allow`는 0 또는 1 | 승인 시 `{"ok":true,"device":DeviceEntry}`, 거절 시 `{"ok":true}` |
| `rd_proxy_start(handle, listen_addr)` | `127.0.0.1:0` | `{"addr":"127.0.0.1:54321"}` |
| `rd_next_event(handle, timeout_ms)` | | `{"event":{…}}` 또는 시간 초과 시 `{"event":null}` |
| `rd_free(ptr)` | | 반환 없음 |

설정(`rd_start`):

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

- `mode`는 `host` 또는 `proxy`. `controlURL`이 비면 Tailscale 기본 제어 서버를 쓴다.
- `listenTLS`가 `false`(평문 HTTP)이면 `controlURL`의 호스트가 루프백일 때만 허용한다. 아니면 `invalid_config`. 테스트에서만 쓴다.
- `publishDir`: 게시본 IPA는 이 폴더 안의 일반 파일이어야 한다(아니면 `path_outside_publish_dir`). 코어는 게시 시점에 크기·SHA-256을 계산해 `build_json`의 값과 비교한다.
- `allowedTargets`: `proxy` 모드에서 CONNECT를 허용할 `host:port` 목록. 실행 중 변경은 `rd_start`를 다시 호출한다.
- `goMemLimitMiB`: 0이 아니면 Go 런타임 메모리 한도로 적용한다(NE용).
- 선택 필드 `directListen`(`host` 모드): `true`면 같은 네트워크 직접 연결 리스너를 함께 연다. 없으면 열지 않는다. [protocol-addenda.md](protocol-addenda.md)의 O.1.

상태(`rd_status`):

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

선택 필드 `peerPaths`(페어링한 기기까지의 경로, 직접·중계)와 터널 모드의 `peerPath`는 [protocol-addenda.md](protocol-addenda.md)의 N.3에 있다. 값이 없으면 키도 없다.

선택 필드 `direct`(같은 네트워크 직접 연결 리스너의 `listening`, `port`, `id`)는 [protocol-addenda.md](protocol-addenda.md)의 O.1에 있다. 리스너를 켠 적이 없으면 키가 없다. 리스너를 켜고 끄는 `rd_host_set_direct`와 이벤트 `device-updated`도 O절에 있다.

## 10. 이벤트

`rd_next_event`가 돌려주는 `event`는 `type` 필드로 구분한다.

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
| `pair-request` | 위 예시 |
| `pair-decided` | `requestId`, `state`(`approved`/`denied`/`expired`) |
| `device-added` | `device`(`DeviceEntry`) |
| `denied` | `path`, `reason`(오류 코드), `nodeName`(알 수 있을 때) |
| `session` | `sessionId`, `buildId`, `nodeName`, `state`, `userAgent`, `bytesServed` |
| `log` | `level`, `message` |

## 11. 가짜 tailnet 테스트

`tailscale.com/tstest/integration/testcontrol`로 로컬 제어 서버를 띄우고 노드를 자동 승인한다. 테스트 설정은 `controlURL=http://127.0.0.1:<port>`, `listenTLS=false`, `port`는 임의다. 이때 매니페스트·설치 주소는 `http://`가 된다(iOS 설치기는 `https`만 받으므로 테스트 전용). 실제 tailnet에는 사용자 허가 없이 노드를 추가하지 않는다.

## 12. 보안 속성과 비목표

- 허용 목록 밖의 노드는 목록·세션·IPA에 접근할 수 없다. 설치기의 요청도 세션을 만든 노드에서 온 것이어야 한다.
- 호스트는 디버그 조건을 만족하지 않는 IPA를 게시하지 않고, 서빙 직전에도 크기·해시를 확인한다.
- 클라이언트 프록시는 열린 프록시가 아니다. 허용된 `host:port`의 CONNECT만 받는다.
- tailnet ACL 태그(`tag:rd-mac`, `tag:rd-phone`)로 `tcp:443`만 허용하면 네트워크 층에서도 한 번 더 막을 수 있다(선택, docs/setup.md).
- 비목표: 침해된 Mac·iPhone 방어, 다중 사용자 권한, Apple 서명 외의 IPA 변조 방지, App Store 배포.
