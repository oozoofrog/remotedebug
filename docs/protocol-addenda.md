# RemoteDebug 프로토콜 보충 규칙 (v1)

`protocol.md`가 정하지 않았거나 구현과 다르게 적힌 규칙을 모은다. 이 문서와 `protocol.md`가 다르면 이 문서가 구현과 같다. 절 번호는 `protocol.md`의 절이다.

## A. 설정과 C API (§9)

### A.1 선택 설정 필드

`rd_start` 설정에 다음 두 필드를 더 받는다. 둘 다 생략할 수 있다.

```json
{
  "hostDisplayName": "작업용 Mac",
  "appVersion": "0.1.0"
}
```

- `hostDisplayName`: `/v1/info`와 승인된 페어링 요청의 `hostName`. 비면 `hostname`을 쓴다.
- `appVersion`: `/v1/info`의 `appVersion`.

### A.2 값 범위

- `goMemLimitMiB`는 0 이상 4096 이하다. 범위를 벗어나면 `invalid_config`.
- `allowedTargets`의 각 항목은 tailnet 주소여야 한다(A.7). 아니면 `invalid_config`.
- `rd_host_pairing_open`의 `ttl_seconds`는 3600 이하다. 넘으면 `bad_request`. 0 이하이면 300초를 쓴다.

### A.3 상태 디렉터리 하나에 핸들 하나

같은 `stateDir`(절대 경로로 바꾸고 `..`와 심볼릭 링크를 푼 경로로 비교)를 쓰는 핸들이 살아 있으면 `rd_start`는 실패한다.

```json
{
  "error": {
    "code": "invalid_config",
    "message": "state_dir_in_use"
  }
}
```

`rd_stop`이 끝나면 그 디렉터리를 다시 쓸 수 있다. 그래서 실행 중에 `allowedTargets`를 바꾸려면 §9의 "rd_start를 다시 호출한다"를 **기존 핸들을 `rd_stop`한 뒤 `rd_start`한다**로 읽는다.

### A.4 `rd_host_set_devices`

입력은 `devices` 키에 배열이 있는 객체여야 한다. `devices`가 없거나 `null`이거나 배열이 아니면 `bad_request`를 돌려주고 허용 목록은 바뀌지 않는다. 목록을 비우려면 `{"devices":[]}`를 보낸다.

목록에서 빠진 노드의 열린 세션은 `failed`가 된다(C.3).

### A.5 상태(`rd_status`)

`backendState`는 언제나 `Stopped`, `Starting`, `NeedsLogin`, `NeedsMachineAuth`, `Running`, `Error` 중 하나다.

| Tailscale 상태·조건 | `backendState` |
| --- | --- |
| `NoState`, 알 수 없는 값 | `Starting` |
| 백엔드가 오류 메시지를 보냈고(인증 키 거부, 제어 서버 오류 등) 아직 `Running`이 아님 | `Error` |
| `InUseOtherUser` | `Error` |
| `Running`이지만 호스트 리스너가 3번 연속 열리지 않음(HTTPS·MagicDNS 꺼짐, 포트 사용 중 등) | `Error` |
| 그 밖의 값 | 그대로 |

`Error`일 때만 `errorMessage` 필드가 있다. Swift는 모르는 필드를 무시한다.

```json
{
  "backendState": "Error",
  "errorMessage": "host listener: HTTPS 인증서가 꺼져 있습니다(관리 콘솔에서 HTTPS를 켜야 합니다)",
  "authURL": "",
  "hostname": "rd-mac-ab12cd34",
  "fqdn": "rd-mac-ab12cd34.example-tailnet.ts.net",
  "tailscaleIPs": ["100.64.0.10"],
  "certDomains": [],
  "tlsReady": false,
  "listening": false,
  "publishedBuilds": 0,
  "pairedDevices": 1,
  "rssMiB": 31.5
}
```

- 리스너가 열리면 리스너 오류는 지워진다. 백엔드 오류는 `Running`이 되면 지워진다.
- `NeedsLogin`인데 `authURL`이 비어 있고(예: 노드 키 만료) `authKey`가 없으면, 코어가 로그인을 다시 시작해 `authURL`을 채운다. 30초에 한 번까지만 시도한다. 새 C API는 없다.
- `tlsReady`: 인증서를 받을 때까지 `Running`인 동안 30초, 60초, 120초…(최대 10분) 간격으로 다시 시도한다. `rd_stop`이면 멈춘다.
- `rd_stop`은 백엔드가 멈추거나 `Running`에서 벗어나도 기다리다 멈추지 않는다. 백엔드를 기다리는 호출은 모두 노드 수명에 묶인 시간 제한이 있다.

### A.6 로그

- `logPath` 파일은 5 MiB를 넘기 전에 `<logPath>.1`로 한 번 돌리고 새로 쓴다(이전 `.1`은 지운다).
- 임베디드 노드는 프로세스 전체에서 Tailscale 로그 업로드(log.tailscale.com)를 끈다.
- 인증 키, 토큰, 페이로드 바이트는 로그·이벤트에 남기지 않는다. `/i/{token}/…` 경로는 `/i/…/app.ipa`처럼 토큰을 가린다.

### A.7 프록시 대상은 tailnet 안만 (§6)

CONNECT 대상의 호스트는 다음 중 하나여야 한다. `allowedTargets`에 있어도 아니면 거부한다.

- `.ts.net`으로 끝나는 이름, 또는 노드 자신의 MagicDNS 접미사로 끝나는 이름
- `100.64.0.0/10` 또는 `fd7a:115c:a1e0::/48` 안의 IP

`rd_start`는 `.ts.net` 이름과 위 IP만 받는다(시작 시점에는 MagicDNS 접미사를 모른다). 실행 중 CONNECT는 연결된 원격 주소도 Tailscale IP인지 확인하고, 아니면 연결을 끊고 403으로 답한다.

프록시의 거부 응답은 JSON이 아닌 평문(`text/plain`)이다.

| 경우 | HTTP |
| --- | --- |
| CONNECT가 아닌 요청 | 405 |
| 허용되지 않은 대상, tailnet 밖 대상 | 403 |
| 대상에 연결하지 못함 | 502 |

## B. REST 인증과 라우팅 (§3, §4, §8)

### B.1 추가 오류 코드

§8 표에 다음을 더한다.

| HTTP | code | 의미 |
| --- | --- | --- |
| 404 | `not_found` | 알 수 없는 경로 |
| 405 | `method_not_allowed` | 경로는 있지만 메서드가 다름 |

두 응답도 `X-RD-Protocol: 1`과 §8 오류 형식을 쓴다.

### B.2 인증 세부

- `/i/{token}/…`는 세션 인증에 더해 허용 목록 인증도 거친다. 목록에 없는 노드는 403 `not_paired`.
- `GET /v1/pair/request/{requestId}`: 없는 요청이나 다른 노드가 만든 요청은 403 `not_paired`.
- `GET /v1/sessions/{sessionId}`: 없는 세션이나 다른 노드의 세션은 403 `token_invalid`.
- 끝난 세션(`completed`, `expired`, `failed`)의 기록은 `expiresAt`에서 1시간이 지나면 지운다. 그 뒤 같은 토큰·세션 id 요청은 410이 아니라 403 `token_invalid`와 `denied` 이벤트를 받는다.

### B.3 페어링 코드 시도 (§2)

- 틀린 코드의 5번째 시도는 403 `pair_code_invalid`로 답하고 코드를 폐기한다.
- 그 뒤 시도는 새 코드가 열리거나 코드의 TTL이 지날 때까지 429 `too_many_attempts`다.
- 만료 확인이 폐기 확인보다 먼저다. TTL이 지난 코드는 폐기되었어도 403 `pair_code_invalid`다.
- 코드는 TTL 시각 정각에 만료된다(그 직전까지 유효).

### B.4 HEAD

`GET` 경로는 `HEAD`도 받는다. `/i/*`의 `HEAD`는 인증과 상태 확인을 똑같이 하되 헤더만 돌려준다.

- 매니페스트 받기 횟수(5번)를 쓰지 않는다.
- 세션 상태를 바꾸지 않고, IPA 만료 연장(600초)을 시작하지 않고, `session` 이벤트를 보내지 않는다.
- `app.ipa`의 `HEAD`는 `Content-Length`와 `Accept-Ranges`를 준다.

## C. 설치 세션 (§4.4)

### C.1 상태 전이

```
created → manifest_served → downloading → completed | expired | failed
```

`created`와 `manifest_served`에서도 바로 `expired`나 `failed`가 될 수 있다. 끝난 상태는 다시 바뀌지 않고, 그 토큰의 `/i/*` 요청은 410 `session_expired`다. 같은 빌드를 다시 게시해도 마찬가지다.

### C.2 완료

- 보낸 바이트 범위를 합쳐 `[0, size)` 전체를 덮으면 `completed`다. 한 번의 200 응답이든, 여러 Range 응답의 합이든 같다. 같은 범위를 반복해 받거나 겹친 부분은 한 번만 센다.
- 응답이 쓰기 오류로 끊기면 마지막 조각은 보낸 것으로 치지 않는다.
- 범위가 둘 이상인 Range 요청(`bytes=0-9,20-29`)은 multipart 대신 파일 전체를 200으로 보낸다.
- `bytesServed`(상태 응답과 `session` 이벤트)는 지금까지 보낸 서로 다른 바이트 수다. `size`를 넘지 않는다.

### C.3 실패(`failed`)

다음 경우 세션은 `failed`가 되고 `session` 이벤트가 나간다. 진행 중인 IPA 전송은 바로 끊긴다.

| 원인 | 시점 |
| --- | --- |
| 빌드 게시 취소(`rd_host_unpublish`) | 그 빌드의 열린 세션 전부 |
| `rd_host_set_devices`에서 세션을 만든 노드가 빠짐 | 그 노드의 열린 세션 전부 |
| 서빙 때 사본이 바뀐 것을 발견(409 `build_changed`) | 그 세션 |
| IPA 읽기 오류 | 그 세션 |
| `rd_stop` | 열린 세션 전부 |

노드를 허용 목록에 다시 넣어도 `failed` 세션은 살아나지 않는다. 새 세션을 만들어야 한다.

### C.4 만료(`expired`)

- 만료는 시간으로만 일어나고, IPA 전송이 진행 중인 세션은 만료시키지 않는다(주기 정리와 상태 조회 모두).
- 만료 시각을 넘긴 전송이 끝나면 그때 판정한다. 파일 전체를 덮었으면 `completed`, 아니면 `expired`.
- 한 응답은 세션 생성 후 600초(`SessionMaxTTL`)를 넘겨 이어지지 않는다. 그 시각에 쓰기 기한이 걸려 전송이 끊긴다.

### C.5 게시본 사본 (§4.4, §7, §12)

- 코어는 `publishDir` 안에 `.rd-snapshots` 폴더를 만들어 소유한다. 시작할 때 비우므로 한 `publishDir`는 한 번에 호스트 하나만 쓴다.
- 게시하면 IPA를 `.rd-snapshots/<buildId>.ipa`로 복제(APFS clonefile, 안 되면 복사)하고 읽기 전용(0400)으로 둔다. 크기·SHA-256은 이 사본에서 계산해 `build_json`과 비교한다(다르면 `hash_mismatch`).
- 서빙은 이 사본에서만 한다. 게시 뒤 앱이 원본 파일을 바꾸거나 지워도 이미 게시한 빌드의 내용은 바뀌지 않는다. 새 내용을 내보내려면 다시 게시한다.
- `.rd-snapshots` 안의 파일은 게시할 수 없다(`path_outside_publish_dir`).
- 이미 게시된 빌드 id를 다시 게시하면 기존 사본을 그대로 쓰고 설명(`BuildDescriptor`)만 바꾼다.
- 세션 생성 때 사본의 크기·SHA-256을 다시 계산한다. 매니페스트·IPA 서빙 때는 사본의 파일 식별자(inode)·크기·수정 시각이 게시 때와 같은지 확인한다. 다르면 409 `build_changed`다. §12의 "서빙 직전에도 크기·해시를 확인한다"는 이 두 확인을 뜻한다.
- 게시 취소와 `rd_stop`은 사본을 지운다.

## D. 이벤트 (§10)

### D.1 `denied` 이벤트 속도 제한

같은 노드·같은 경로의 `denied` 이벤트는 5초에 하나만 보낸다. 그사이 생략한 수는 다음 이벤트의 `suppressed`에 담는다(생략이 없으면 필드가 없다). 요청 자체는 매번 거부된다.

```json
{
  "type": "denied",
  "path": "/v1/info",
  "reason": "not_paired",
  "nodeName": "rd-phone-ab12cd34",
  "suppressed": 12
}
```

### D.2 큐가 찼을 때

이벤트 큐(256개)가 차면 `denied`, `log`, `state` 중 가장 오래된 것부터 버린다. `pair-request`, `pair-decided`, `device-added`, `session`은 큐에 이것들만 남았을 때만 가장 오래된 것을 버린다. 버린 수는 다음 `rd_next_event`가 `log` 이벤트로 알린다.

```json
{
  "type": "log",
  "level": "warn",
  "message": "event queue full: dropped 3 events"
}
```

## E. 설치 웹 페이지

Mac 호스트는 RemoteDebug iPhone 앱 없이 Tailscale 공식 앱만 켠 기기가 Safari로 페어링하고 빌드를 설치할 수 있는 페이지를 같은 주소(`https://<fqdn>/`)에서 내준다. 페이지 파일은 코어에 들어 있다(`core/internal/host/web`, go:embed). iPhone 앱의 내장 VPN 경로는 그대로다.

### E.1 경로

| 메서드·경로 | 인증 | 응답 |
| --- | --- | --- |
| `GET /` | 없음 | 페이지(`text/html; charset=utf-8`) |
| `GET /assets/install.css` | 없음 | `text/css; charset=utf-8` |
| `GET /assets/install.js` | 없음 | `text/javascript; charset=utf-8` |
| `GET /assets/logic.js` | 없음 | `text/javascript; charset=utf-8` |

- 경로는 글자 그대로 같아야 한다. `/foo`, `//`, `/index.html`, `/assets/`, `..`·`.` 조각, 퍼센트 인코딩(`%2e`, `%2F`, `%61`), 역슬래시, 하위 경로는 모두 404 `not_found`(§8 형식)다. 디렉터리 목록은 없다.
- `HEAD`는 본문 없이 같은 헤더를 준다. 다른 메서드는 405 `method_not_allowed`와 `Allow: GET, HEAD`다.
- 쿼리 문자열은 무시한다.

모든 페이지 응답(405 포함)에 붙는 헤더:

```
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
Cache-Control: no-store
X-Frame-Options: DENY
X-RD-Protocol: 1
```

인라인 스크립트·스타일, 외부 리소스, 쿠키는 쓰지 않는다.

### E.2 허용 목록 밖의 기기

- 페이지 경로는 WhoIs를 부르지 않고, `denied` 이벤트를 보내지 않으며, `denied` 속도 제한(D.1)에 세지 않는다.
- 페이지 파일에는 빌드 정보가 없다. 허용 목록 밖의 기기는 페이지를 받을 수 있지만 `/v1/*`와 `/i/*`는 지금처럼 403 `not_paired`다. 할 수 있는 것은 페어링 요청(§4.3)뿐이다.
- 다른 경로의 응답과 인증은 바뀌지 않는다.

### E.3 페이지가 쓰는 API

페이지는 같은 출처의 `/v1/*`를 iPhone 앱(`HostAPI`)과 같은 방식으로 부른다. 응답에 `X-RD-Protocol: 1`이 없거나 값이 다르면 앱과 같이 연결 실패·규약 불일치로 본다.

1. 열 때 `GET /v1/builds`. 200이면 목록, 403 `not_paired`면 페어링 입력, 그 밖의 오류면 앱과 같은 안내와 ‘다시 시도’.
2. 페어링: 코드는 앱과 같은 규칙으로 정규화한다(대소문자·하이픈·공백·탭 무시, O→0, I/L→1, U와 영숫자가 아닌 글자 거부, 8자). 본문은 `{"code":<정규화한 8자>,"deviceName":<기본 iPhone(Safari), UTF-8 200바이트까지>,"platform":"Web","clientVersion":"web-1"}`다. 주소의 `#code=<코드>` 조각이 있으면 입력란에 미리 넣고 조각을 지운다(자동으로 보내지는 않는다).
3. 승인 대기: `GET /v1/pair/request/{requestId}`를 1초마다 묻는다. 마감은 120초와 `expiresAt` 중 이른 쪽이고, 마감이 지나면 한 번 더 묻는다. 요청 id와 마감은 `sessionStorage`에 두어 새로고침해도 이어 간다(저장소가 없으면 이어 가지 못할 뿐 동작한다).
4. 설치: `POST /v1/builds/{id}/sessions` 뒤 `GET /v1/sessions/{sessionId}`를 1초마다, 최대 600초 묻는다. 같은 빌드의 설치가 진행 중이면 새 세션을 만들지 않는다.
5. 페이지 아래에 `GET /v1/info`의 `hostName`과 `fqdn`을 보여 준다(허용 목록에 든 뒤에만 받는다).

### E.4 설치 주소 확인

세션 응답의 `installUrl`이 다음을 모두 만족할 때만 ‘설치 창 열기’ 링크(`<a href="itms-services://…">`)를 보여 준다. 링크는 사용자가 직접 누른다. 페이지가 비동기 호출 뒤에 스스로 이동하지 않는다.

- `itms-services://?`로 시작한다(스킴 소문자, authority·경로 없음). 조각(`#`)과 공백이 없다.
- 쿼리는 `action`과 `url` 두 항목뿐이고 각각 한 번, `action`은 `download-manifest`다.
- `url`을 디코딩한 값이 정확히 `<location.origin>/i/<43자 base64url 토큰>/manifest.plist`다. 출처가 글자 그대로 같아야 하므로 다른 호스트, `http`/`https` 차이, 명시한 포트, 사용자 정보는 받지 않는다.
- 같은 응답의 `manifestUrl`과 같다.

페이지가 받는 주소는 iPhone 앱의 `isTrustedInstallURL`도 받는다(`Packages/WebPage` 테스트가 확인한다).

### E.5 한계

- iPhone에서 Tailscale VPN이 켜져 있어야 페이지와 설치가 동작한다. tailnet의 HTTPS 인증서가 켜져 있어야 한다(iOS 설치기는 `https` 매니페스트만 받는다).
- 승인되는 것은 브라우저가 아니라 iPhone의 tailnet **노드**다. 승인한 뒤에는 그 iPhone에서 Mac에 닿는 모든 앱과 브라우저가 같은 허용을 쓴다.
- 페이지를 새로고침하면 진행 중이던 설치의 확인은 이어 가지 않는다. Mac의 세션은 제한 시간이 지나면 만료되고, 다시 설치하면 새 세션을 연다.

## F. 빌드 아이콘 (§4.1)

`BuildDescriptor`에 선택 필드 `icon`을 더한다. 값은 앱 아이콘 PNG의 base64(표준 알파벳, 패딩 포함) 문자열이다.

- Mac 앱은 `.app` 원본에서 가져온 빌드에만 넣는다. `Info.plist`의 `CFBundleIcons > CFBundlePrimaryIcon > CFBundleIconFiles`가 가리키는 PNG 가운데 가장 큰 것을 120×120 표준 PNG로 다시 쓴다. `.ipa` 원본이나 아이콘이 없는 빌드에는 키를 넣지 않는다.
- 아이콘을 담기 전에 가져온 빌드는 Mac 앱이 다시 시작해 게시를 되살릴 때 원본 `.app`이 남아 있으면 채운다.
- `rd_host_publish`는 `icon`이 64KiB(65536바이트)를 넘거나 PNG 서명(`89 50 4E 47 0D 0A 1A 0A`)으로 시작하지 않으면 `bad_request`로 거부한다. 받은 값은 `GET /v1/builds`에 그대로 싣는다. `id` 계산에는 쓰지 않는다.
- iPhone 앱은 `icon`이 없거나, base64가 아니거나, 64KiB를 넘거나, PNG가 아니면 아이콘만 버리고 빌드는 받는다. 아이콘이 없으면 이름 첫 글자 타일을 보여 준다.
- 설치 웹 페이지는 `icon`을 쓰지 않는다.

## G. iPhone 진단 로그

페어링한 기기는 진단 로그를 Mac에 보낼 수 있다. 코어는 로그를 저장하지 않고 Mac 앱에 이벤트로 넘긴다.

### G.1 `POST /v1/logs`

인증은 다른 `/v1/*`와 같다(허용 목록, §3). 본문:

```
{"entries":[{"at":"2026-11-12T00:00:01.250Z","level":"info","source":"install","message":"설치 요청: …"}]}
```

- `entries`는 1~200개, 본문은 128KiB 이하. 어기면 400 `bad_request`.
- `at`은 ISO-8601(소수 초 허용). 읽지 못하면 코어가 받은 시각으로 바꾼다.
- `level`은 `debug`, `info`, `warning`, `error` 가운데 하나. 그 밖의 값은 `info`로 바꾼다.
- `source`는 40바이트, `message`는 4096바이트에서 UTF-8 글자 경계로 자른다. 잘못된 UTF-8은 `?`로 바꾼다.
- 성공하면 202와 `{"accepted":<줄 수>}`.

### G.2 `device-log` 이벤트

```
{"type":"device-log","deviceId":"…","deviceName":"…","nodeName":"…","entries":[…]}
```

`deviceId`, `deviceName`, `nodeName`은 보낸 기기의 허용 목록 항목에서 채운다(본문 값이 아니다). 큐에서는 `denied`·`log`·`state`와 같이 낮은 우선순위라 큐가 차면 먼저 버린다(D.2).

### G.3 앱 동작

- iPhone 앱은 로그를 앱 데이터 폴더의 파일(`device-log.json`, 최근 2000줄)에 쌓고 보내면 지운다. 앱이 업데이트되거나 강제로 꺼져도 남아서 다음 실행에서 보낸다.
- 빌드 목록을 받은 뒤 자동으로 보내고, 설정 > 진단 로그 > **Mac에 지금 보내기**로도 보낸다. 실패하면 남겨 두고 다음에 다시 보낸다.
- Mac 앱은 기기마다 `DeviceLogs/<기기 id>.jsonl`(4MiB에서 앞 절반을 버림)에 덧붙이고 **iPhone 로그** 화면에 보여 준다. MCP 도구 `remotedebug_device_logs`는 이 파일을 직접 읽는다.

## H. Mac에서 iPhone으로 파일 보내기

Mac 앱이 고른 파일을 페어링한 기기가 받는다. 빌드와 달리 설치 세션 없이 허용 목록 인증(§3)만으로 받는다.

### H.1 C API

| 함수 | 입력 | 결과 |
| --- | --- | --- |
| `rd_host_publish_resource(handle, resource_json)` | `{"name","size","sha256","path"}`. `id`·`publishedAt`·`project`(H.6)는 생략 가능 | `{"ok":true,"id":"r_…"}` |
| `rd_host_unpublish_resource(handle, resource_id)` | | `{"ok":true}`. 없는 id는 `resource_not_found` |

- `path`는 `publishDir` 안의 일반 파일이어야 한다(`path_outside_publish_dir`). 코어는 빌드처럼 `.rd-snapshots`에 사본을 만들고 사본의 크기·SHA-256을 확인한다(`hash_mismatch`). 이후 원본이 바뀌어도 사본만 내준다.
- `name`은 1~255바이트의 UTF-8 파일 이름. `/`, `\`, `:`, 제어 문자, `.`, `..`는 400 `bad_request`. 크기는 4GiB, 개수는 500개까지.
- `id`는 `"r_"` + `sha256("rd-resource\n" + name + "\n" + sha256)`의 앞 8자리 16진수다. 같은 이름·같은 내용을 다시 게시하면 같은 id로 설명만 바뀐다(구역 옮기기도 이렇게 한다).
- `rd_stop`은 사본을 모두 지운다. Mac 앱은 공유를 시작할 때 저장한 목록을 다시 게시한다.

### H.2 `GET /v1/resources`

```
{"resources":[{"id":"r_1a2b3c4d","name":"config.json","size":7,"sha256":"…","publishedAt":"2026-11-12T01:00:00Z"}]}
```

최근에 게시한 것부터. 허용 목록 밖이면 403 `not_paired`.

### H.3 `GET /v1/resources/{id}`

파일 내용. `Content-Type: application/octet-stream`, `Content-Disposition: attachment; filename*=…`, `ETag: "<sha256>"`, `Cache-Control: no-store`. `Range`와 `HEAD`를 받는다. 없는 id는 404 `resource_not_found`. 내려받는 중에 게시를 취소해도 이미 연 전송은 끝까지 간다.

### H.4 앱 동작

- Mac 앱: 사이드바 **보낸 파일**에 파일을 끌어 놓거나 **파일 보내기…**로 고른다. 사본을 `Published/Files/<id>`, 목록을 `resources.json`에 둔다. 이름이 같은 파일을 다시 넣으면 이전 것을 바꾼다. 폴더는 받지 않는다(압축해서 보낸다).
- 에이전트: `rd push <파일> [프로젝트]`, `rd files [프로젝트]`, `rd unpush <파일 id>`와 MCP 도구 `remotedebug_push_file`(`file_path`, `project`), `remotedebug_files`(`project`). 구역은 H.6.
- iPhone 앱: 빌드 목록을 받은 뒤 파일 목록을 받는다. 이 경로가 404 `not_found`면(이전 Mac 앱) 빈 목록으로 본다. **받기**는 크기와 SHA-256을 확인한 뒤 앱의 Documents에 같은 이름으로 저장한다(같은 이름은 바꾼다). Documents는 파일 앱의 "나의 iPhone > RemoteDebug"에 보인다. 다른 앱의 샌드박스에 직접 넣지는 않는다.
- 받기는 시스템 백그라운드 세션(식별자는 앱 번들 id 뒤에 `.files`)으로 한다. 앱이 백그라운드로 가거나 멈춰도 iOS가 이어 받고, 끝나면 앱을 깨운다. 끊기거나 취소하면 이어받기 데이터를 남겨 다음 받기에서 `Range`로 이어 받는다. 앱이 종료된 뒤 iOS가 앱을 다시 띄워 넘겨주는 전송은 시작할 때 넘긴 파일 정보로 크기·SHA-256을 확인해 저장하고, 진행 중인 전송은 이어서 보여 준다. 다시 띄운 앱은 전에 띄운 라이브 액티비티를 이어받고, 이어받을 전송이 없으면 "끊겼습니다"로 끝낸다.
- 받는 동안 라이브 액티비티(잠금 화면, Dynamic Island)에 진행을 보인다. 앱이 멈춘 동안에는 iOS가 진행을 알려 주지 않아 마지막 값에 머물고, 끝나면 완료·실패로 바뀐다.
- 화면: **파일** 탭(받는 중, Mac에서 보낸 파일, 이 iPhone에만 있는 파일. 프로젝트 구역이 있으면 H.6처럼 구역별 칸)과 파일마다 상세 화면(진행률·속도·남은 시간, 종류별 미리보기: 이미지·동영상·소리·PDF·텍스트·JSON, 종류·크기·보낸 시각·저장 위치·SHA-256 비교, 열기·다른 앱으로 보내기·파일 앱에서 보기, 이름·SHA-256·경로 복사).

### H.5 링크

`link`가 있는 항목은 링크다. 파일 없이 주소만 보낸다.

- `rd_host_publish_resource`에 `{"name","link"}`를 넘긴다(`path`는 무시). `link`는 스킴이 있는 8KiB 이하의 주소다(`https://…`, `앱스킴://…`, `maps://?q=…`, `app-settings:`). 제어 문자는 400.
- 코어가 `size`를 0으로, `sha256`을 주소 글자의 SHA-256으로 채운다. `id` 규칙은 H.1과 같다.
- `GET /v1/resources`에 `"link":"…"`로 나온다. `GET /v1/resources/{id}`는 링크에 404 `resource_not_found`.
- Mac 앱: **보낸 파일**의 **링크 보내기…**, 웹 주소를 끌어 놓기, `rd link <주소> [이름] [프로젝트]`, MCP `remotedebug_push_link`(`url`, `title`, `project`). 이름이 없으면 주소에서 만든다(`호스트 – 경로 끝`). 같은 주소를 다시 보내면 이전 항목을 바꾼다.
- iPhone 앱: **파일** 탭의 "링크" 칸. 상세 화면에서 Safari나 그 스킴의 앱으로 열고(열 앱이 없으면 안내), 공유·주소 복사, 주소 구성(스킴·호스트·경로·프래그먼트·쿼리 항목)을 보인다. 받기는 없다.

### H.6 프로젝트 구역

파일과 링크는 프로젝트 구역 하나에 속하거나 공통 구역에 있다. 항목에 `project`가 있으면 그 프로젝트 구역이고, 없으면 공통이다.

```
{"resources":[
  {"id":"r_1a2b3c4d","name":"config.json","size":7,"sha256":"…","publishedAt":"2026-11-12T01:00:00Z","project":{"id":"0a1b2c3d4e5f","name":"SampleApp"}},
  {"id":"r_5e6f7a8b","name":"notes.txt","size":3,"sha256":"…","publishedAt":"2026-11-12T00:30:00Z"}
]}
```

- `project.id`: 1~64바이트의 영문자·숫자·`_`·`-`. Mac 앱은 프로젝트 폴더 경로 SHA-256의 앞 6바이트(16진수 12자리)를 쓴다. 경로와 폴더 이름은 보내지 않는다.
- `project.name`: 화면에 보일 프로젝트 이름. 1~255바이트의 UTF-8, 제어 문자 없음.
- `rd_host_publish_resource`의 입력에 `project`를 함께 넘긴다. 모양이나 길이가 맞지 않으면 400 `bad_request`다. 같은 id를 다른 `project`로(또는 `project` 없이) 다시 게시하면 구역만 바뀐다.
- 호환: 공통 구역 항목에는 `project` 키가 없어 응답이 이전과 같다. 이전 iPhone 앱은 `project`를 무시하고 한 목록으로 보인다. 이전 Mac 앱의 목록에는 키가 없으므로 모두 공통이다. iPhone 앱은 모양이 맞지 않는 `project`를 공통으로 본다. Mac 앱의 `resources.json`도 같은 모양이라 이전 버전이 쓴 파일은 모두 공통으로 읽는다.
- `id` 규칙(H.1)에는 구역이 들어가지 않는다. 이름이 같은 파일은 구역이 달라도 하나만 두고(나중에 보낸 것이 이전 것을 바꾼다), iPhone은 받은 파일을 지금처럼 이름으로 Documents에 저장한다.
- Mac 앱: **보낸 파일**은 항목이 있는 프로젝트 구역을 이름순으로 보이고 **공통**을 마지막에 둔다. 도구 막대의 **넣을 구역**(연결한 프로젝트와 공통, 기본은 공통)이 **파일 보내기…**, **링크 보내기…**, 끌어 놓기에 적용된다. 프로젝트 화면의 더 보기 메뉴 **파일 보내기…**는 그 프로젝트 구역에 넣는다. 항목의 오른쪽 클릭 **구역 옮기기**로 다른 구역에 옮긴다(id, 보낸 시각은 그대로). 프로젝트 연결을 끊어도 그 구역의 항목은 지우지 않고, 항목에 저장한 프로젝트 이름으로 계속 보인다.
- 에이전트: `project`는 연결한 프로젝트의 이름(대소문자 무시), `.xcodeproj`·`.xcworkspace` 경로, 또는 프로젝트 폴더 경로다. 비우거나 `공통`이면 공통 구역이다. 연결한 프로젝트와 맞지 않으면 보내지 않고 쓸 수 있는 프로젝트 이름을 오류로 돌려준다. 이름이 같은 프로젝트가 여럿이면 경로로 정한다. `rd files`와 `remotedebug_files`의 항목에는 `project`가 함께 나오고, `project`로 한 구역만 볼 수 있다(연결을 끊은 프로젝트는 저장된 이름으로 찾는다).
- iPhone 앱: 프로젝트 구역에 든 항목이 하나라도 있으면 **파일** 탭이 구역별 칸(프로젝트 이름순, **공통** 마지막)으로 나뉘고, 칸마다 링크 다음에 파일이 온다. 모두 공통이면 이전처럼 "링크", "Mac에서 보낸 파일" 칸으로 보이고 "공통" 제목은 없다. "받는 중"과 "이 iPhone에만 있는 파일" 칸은 그대로다. 상세 화면에 구역 이름이 나온다.

## I. iPhone 앱 자신의 업데이트 페이지

iOS는 앱을 바꾸는 동안 그 앱의 패킷 터널을 멈춘다. 그래서 RemoteDebug iPhone 앱은 자기 VPN으로 Mac의 설치 페이지(E)를 열어 자기 자신을 설치할 수 없다(2026-11-12 실기기에서 0.2.0 (6)·(7) 설치 실패). 이 업데이트만 Mac의 공식 Tailscale로 내준다.

### I.1 C API `rd_update_page_set(config_json)`

노드 핸들과 무관하게 프로세스에 하나다.

```
{"listen":"127.0.0.1:0","publicURL":"https://<Mac>.<tailnet>.ts.net/remotedebug-update-<32자>/","page":{"bundleId","title","version","buildNumber","minOS","size","sha256","publishedAt","ipaPath","icon"}}
```

- `listen`은 루프백 주소만 받는다. 빈 문자열이면 서버를 멈춘다. 결과는 `{"ok":true,"addr":"127.0.0.1:P"}`.
- `publicURL`은 `/`로 끝나는 https 주소이거나 빈 문자열(경로가 아직 없음)이다. `page`가 없으면 "게시된 빌드 없음" 페이지를 낸다.
- 경로의 마지막 부분만 본다: `/`(안내와 `itms-services` 링크), `manifest.plist`, `RemoteDebug.ipa`, `icon.png`. 프록시가 앞 경로를 떼든 안 떼든 같다. IPA는 요청마다 `ipaPath`를 열고 크기가 `size`와 다르면 410.

### I.2 `/v1/info`의 `updatePage`

서버가 돌고 `page`와 `publicURL`이 모두 있으면 `/v1/info`에 `"updatePage":"<publicURL>"`을 더한다. iPhone 앱은 https 주소만 받아 페어링 정보에 저장하고, 앱 VPN이 꺼져 있을 때도 이 주소를 연다.

### I.3 앱 동작

- Mac 앱: 시작할 때 서버를 연다. 경로(`/remotedebug-update-<32자>`)와 포트는 `update-page.json`에 저장해 다시 쓴다. 게시된 빌드 중 번들 id가 `<앞부분>.RemoteDebugPhone`(기본 앞부분은 `Config/Signing.xcconfig`의 `RD_BUNDLE_PREFIX`, 다른 팀으로 서명한 앞부분도 포함)인 가장 최근 빌드를 자동으로 올린다. **네트워크 > iPhone 앱 업데이트**의 **공식 Tailscale로 열기**가 `tailscale serve --bg --yes --set-path <경로> http://127.0.0.1:<포트>`를, **닫기**가 `tailscale serve --https=443 --set-path <경로> off`를 실행한다. 공식 Tailscale 상태는 60초마다 다시 읽는다. 공식 Tailscale 명령은 `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, `/opt/homebrew/bin/tailscale`, `/usr/local/bin/tailscale` 순서로 찾는다.
- iPhone 앱: RemoteDebug 앱에는 자기 업데이트 화면이 없다. 자기 빌드는 업데이트 앱이 설치한다(M.4). 업데이트 페이지는 업데이트 앱 없이 설치할 때 Safari에서 직접 연다. 앱은 `updatePage` 값을 페어링 정보에 저장만 한다.
- 에이전트 `status` 응답에 `updatePage`가 있다.

## J. 페어링 링크의 1회용 Tailscale 키

페어링 링크(§2)에 선택 쿼리 `key`를 더한다: `remotedebug://pair?host=<fqdn>&code=<코드>&key=<tskey-auth-…>`.

- Mac 앱은 사용자가 넣은 Tailscale OAuth 클라이언트(클라이언트 ID, 비밀값 `tskey-client-…`, 태그; 키체인 보관)로 `POST https://api.tailscale.com/api/v2/oauth/token`(`grant_type=client_credentials`, `client_id`, `client_secret`)에서 1시간짜리 API 토큰을 받아 메모리에 둔다. 페어링 코드를 열 때마다 그 토큰으로 `POST …/tailnet/-/keys`를 부른다. 본문은 `{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":[<태그>]}}},"expirySeconds":900,"description":"RemoteDebug iPhone pairing"}`이고 응답의 `key`를 링크에 넣는다. OAuth 클라이언트로 만드는 키에는 태그가 꼭 있어야 하므로 기본값은 `tag:rd-phone`이다.
- 클라이언트에 필요한 권한은 `auth_keys`(쓰기)와 그 태그다. 기기 읽기 권한이 있으면 저장할 때 `GET …/tailnet/-/devices`로 이 Mac의 MagicDNS 이름이 그 tailnet에 있는지 확인하고, 없으면 저장하지 않는다(다른 tailnet의 키로는 iPhone이 Mac에 닿지 못한다). 권한이 없으면(403) 확인을 건너뛴다.
- iPhone 노드는 그 태그를 단 노드가 된다. 정책 파일이 그 태그에서 이 Mac의 443 포트로 가는 연결을 허용해야 한다.
- 키를 만들지 못하면 `key` 없이 지금처럼 쓴다. 에이전트 명령(`rd pair`, `remotedebug_pairing_code`) 응답에는 키를 넣지 않는다(대화 기록에 남기 때문).
- iPhone 앱은 `key`가 `tskey-auth-`로 시작하고 영문·숫자·하이픈 200자 이하일 때만 받는다. 아니면 `invalidAuthKey`. `key`가 둘 이상이면 페어링 링크가 아니다. VPN이 연결돼 있지 않으면 그 키로 VPN을 켜고(키는 저장하지 않음) 페어링은 연결된 뒤 이어 간다. 이미 연결돼 있으면 키를 쓰지 않는다.
- 요청 본문 형식과 응답 필드는 실제 Tailscale API로 확인하지 않았다. 공식 문서에서 확인한 것은 엔드포인트, OAuth 토큰 엔드포인트와 응답의 `access_token`·`expires_in`, `auth_keys` 범위, OAuth로 만든 키에 태그가 필요하다는 점, Bearer 인증, `-` tailnet 이름이다.

## K. 에이전트 요청

현재 앱에서는 꺼져 있다(`AgentFeature.isEnabled`가 `false`). Mac 사이드바와 iPhone 탭에 나오지 않고 Mac 앱은 상태 문서를 넘기지 않는다.

Mac 화면이나 페어링한 iPhone에서 쓴 요청을 Mac의 코딩 에이전트(Claude Code, Codex)에 넘기고 진행과 답을 돌려준다. 코어는 요청을 이벤트로 넘기고 Mac 앱이 준 상태 문서를 그대로 내줄 뿐, 에이전트를 실행하지 않는다.

### K.1 C API `rd_host_set_agent_board(handle, board_json)`

`GET /v1/agent`가 낼 문서 전체를 바꾼다(최대 2MiB). 코어는 `enabled`만 읽는다. 노드를 다시 시작하면 비므로 Mac 앱이 시작할 때마다 다시 넘긴다.

```
{"enabled":true,"projects":[{"id":"3f9a1c2e7b10","name":"MyApp"}],"agents":["claude","codex"],"requests":[AgentJob]}
```

`AgentJob`: `id`, `text`, `project`, `projectName`, `agent`(`claude`|`codex`), `origin`(`Mac` 또는 기기 이름), `state`(`queued`|`running`|`done`|`failed`|`cancelled`), `createdAt`, `finishedAt`(끝났을 때), `activity`(실행 중 진행 내용의 끝 3000자), `output`(마지막 답이나 실패 이유, 8000자까지), `session`(이어 갈 수 있으면 에이전트 세션 id), `continues`(이어 간 앞 요청 id). `requests`는 새 것부터 최대 20개다. 프로젝트 `id`는 폴더 경로의 SHA-256 앞 12자라 경로가 iPhone에 가지 않는다.

### K.2 `GET /v1/agent`

허용 목록의 기기만. Mac 앱이 넘긴 문서를 그대로 낸다. 아직 없으면 `{"enabled":false,"projects":[],"agents":[],"requests":[]}`.

### K.3 `POST /v1/agent/requests`

```
{"text":"실패하는 테스트를 고쳐줘","project":"3f9a1c2e7b10","agent":"claude","continues":""}
```

- 허용 목록의 기기만. `enabled`가 false면 403 `agent_disabled`.
- `text`는 앞뒤 공백을 뗀 뒤 1바이트 이상 16KiB 이하의 UTF-8, 나머지는 128바이트 이하. 본문은 32KiB까지. 어기면 400.
- `continues`에 앞 요청 id를 넣으면 그 요청의 프로젝트·에이전트·세션으로 이어 간다(`project`, `agent`는 무시).
- 202 `{"id":"a_52d9a07e"}`. 코어는 `agent-request` 이벤트를 넘긴다: `{"type":"agent-request","requestId","deviceId","deviceName","nodeName","text","project","agent","continues"}`.
- 진행과 결과는 `GET /v1/agent`의 `requests`에서 같은 `id`로 본다. Mac 앱이 받지 못하는 요청(없는 프로젝트, 설치되지 않은 에이전트)도 `failed`와 이유로 목록에 나온다.

### K.4 `POST /v1/agent/requests/{id}/cancel`

허용 목록의 기기만, `enabled`일 때만. 202 `{"ok":true}`와 `agent-cancel` 이벤트(`requestId`, `deviceId`, `deviceName`). 어느 기기든 목록의 요청을 멈출 수 있다.

### K.5 앱 동작

- Mac 앱: 사이드바 **에이전트**. 연결한 프로젝트와 에이전트를 골라 요청을 보낸다. 요청마다 로그인 셸(`zsh -lic`)로 프로젝트 폴더에서 `claude -p --output-format stream-json --verbose --permission-mode <모드> [--resume <세션>] -- <요청>`이나 `codex exec [resume <세션>] --json --skip-git-repo-check <샌드박스> -- <요청>`을 띄우고, 한 줄에 하나씩 나오는 JSON에서 글·도구 사용·마지막 답·세션 id를 읽는다. 같은 프로젝트의 요청은 한 번에 하나씩 순서대로 실행한다. 목록과 설정은 `agent-requests.json`에 둔다. 앱을 끄면 실행 중인 에이전트를 끝내고, 다시 열면 그 요청을 실패로 표시한다.
- 권한은 Mac에서만 고른다(기본 **프로젝트 파일 수정**): **읽기만**은 `--permission-mode plan` / `--sandbox read-only`, **프로젝트 파일 수정**은 `acceptEdits` / `workspace-write`, **모든 권한**은 `bypassPermissions` / `--dangerously-bypass-approvals-and-sandbox`. iPhone은 권한을 바꿀 수 없다.
- **페어링한 iPhone의 요청 받기**는 기본으로 꺼져 있다. 꺼져 있어도 iPhone은 `GET /v1/agent`로 목록을 본다.
- iPhone 앱: **에이전트** 탭. 탭이 보이는 동안 `GET /v1/agent`를 6초마다(끝나지 않은 요청이 있으면 2초마다) 받는다. 이 경로가 404 `not_found`면(이전 Mac 앱) Mac 앱을 업데이트하라고 안내한다. 요청을 누르면 진행·답을 보고, 멈추거나 이어서 요청한다.
- 확인한 것: 코어 경로(Go 시험), Mac 실행기(가짜 실행기 시험), `claude` 2.1.322의 실제 `stream-json` 출력과 `codex` 0.167.2의 실제 `--json` 실패 출력. `codex`의 성공 출력(`agent_message`)과 실제 iPhone에서 보낸 요청은 확인하지 않았다.

## L. iPhone 크래시 기록

페어링한 기기는 크래시 기록을 Mac에 보낼 수 있다. 코어는 기록을 저장하지 않고 Mac 앱에 이벤트로 넘긴다.

### L.1 `POST /v1/crashes`

인증은 다른 `/v1/*`와 같다(허용 목록, §3). 본문은 기록 하나다.

```
{"kind":"ips","name":"Sample-2026-11-13-140501.ips","bundleId":"com.example.sample","appVersion":"1.2 (7)","crashedAt":"2026-11-13T05:05:01.000Z","text":"…"}
```

- `kind`: `ips`(iOS가 만든 크래시 파일, 사용자가 iPhone 앱으로 넘긴 것), `metrickit`(앱이 자기 크래시를 MetricKit에서 받은 JSON), `feedback`(사람이 앱에서 쓴 피드백, `text`가 내용). 다른 값은 `400 bad_request`.
- `image`: 선택. 화면 사진(JPEG나 PNG)의 base64. `kind`가 `feedback`일 때만 받고, 풀었을 때 1MB를 넘거나 base64가 아니면 `400 bad_request`.
- `text`: 원문. 비어 있거나 1536KB를 넘으면 `400 bad_request`. 본문 전체는 4MB까지 읽는다.
- `name`, `bundleId`, `appVersion`: 200바이트에서 자른다. `crashedAt`이 ISO-8601 시각이 아니면 받은 시각으로 바꾼다.
- 응답: `202`와 `{"accepted":1}`.

### L.2 `device-crash` 이벤트

```
{"type":"device-crash","deviceId":"d_…","deviceName":"…","nodeName":"rd-phone-…","report":{…}}
```

`report`는 L.1의 본문을 정리한 것이다.

### L.3 앱 동작

- iPhone 앱은 자신의 크래시를 MetricKit에서 받아 다음 실행 때 기록으로 만든다. 다른 앱의 기록은 iOS가 앱에 내주지 않으므로, 사용자가 설정 앱의 분석 데이터에서 `.ips` 파일을 공유로 넘기거나 파일에서 가져온다.
- iPhone 앱의 빌드 목록에서 설치된 앱마다 **크래시 기록**을 열면 그 앱(번들 ID가 같은 것)의 기록만 보이고, iPhone 설정 앱을 여는 버튼이 있다. 버튼은 분석 데이터 화면 주소(`App-prefs:Privacy&path=PROBLEM_REPORTING/DIAGNOSTIC_USAGE_DATA`)를 먼저 시도한다. iOS 27.2 시뮬레이터에서는 이 주소가 설정 앱의 첫 화면만 열었다.
- iPhone 앱의 설정 > 크래시·피드백에서 RemoteDebug 앱에 대한 피드백을 적어 보낸다. 사진 보관함에서 고른 화면 사진과 최근 진단 로그 100줄을 붙일 수 있다.
- 다른 앱은 저장소 루트의 Swift 패키지 `RemoteDebugFeedback`(iOS 17 이상)을 넣는다. 패키지는 자기 크래시(`metrickit`)를 모아 보내고, 피드백 화면 하나에서 글, 화면 사진(띄우기 직전 화면이나 고른 사진), 최근 로그(앱이 `log`로 남긴 줄과 이 앱의 시스템 로그 최근 15분, 300줄까지)를 받는다.
- 피드백은 먼저 Mac으로 직접 보낸다(`feedback`). 요청은 그 iPhone의 RemoteDebug VPN을 지나므로 페어링한 기기의 요청으로 인증된다. Mac에 닿지 않으면 메일로 보내거나 저장했다가(30개까지) 다음에 보낸다. Mac 주소가 없는 빌드는 메일만 쓴다.
- 메일 경로: iOS 메일 작성 화면을 띄우고, 메일 계정이 없으면 `mailto:` 링크를 연다. Debug 빌드에서 공개키가 설정돼 있으면 로그와 화면 사진을 JSON으로 묶어 암호화한 파일(`.afdiag`)을 붙인다. Release 빌드에는 이 코드가 들어가지 않는다.
- `.afdiag` 형식: 머리말 `AFDIAG1\0`(8바이트), 공개키 SHA-256의 앞 8바이트, HPKE 캡슐화 키 32바이트, 암호문. HPKE는 X25519, HKDF-SHA256, ChaCha20-Poly1305이고 info는 `AppFeedback diagnostics v1`, 평문은 LZFSE로 압축한 JSON(2MB까지)이다. 머리말 16바이트는 인증 데이터로 묶는다.
- 개인키는 Mac 키체인(서비스 `RemoteDebug feedback diagnostics`, 계정 `<프로젝트 이름> v1`)에만 둔다. Mac 앱의 **크래시·피드백** 화면에 파일을 끌어다 놓거나 **암호화된 진단 열기…**로 고르면 풀어서 목록에 넣는다. 명령줄에서는 `scripts/feedback_diagnostics.swift`가 같은 형식을 다룬다.
- Mac 앱의 프로젝트 화면은 패키지를 쓰지 않는 프로젝트에 넣는 방법, 키 만들기, Mac 주소·메일 주소·공개키가 든 코드를 보여 준다.
- 실기기에서 확인하지 않은 것: 다른 앱의 요청이 VPN을 지나 Mac에 닿는지, 메일 작성 화면과 첨부, 받은 첨부를 Mac에서 푸는 전체 경로.
- 기록은 iPhone에 50개까지 남기고, 페어링한 Mac과 VPN이 연결되면 보내지 않은 것을 보낸다.
- Mac 앱은 `CrashLogs/`에 원문 파일과 `index.json`을 두고(200개까지) **크래시** 화면과 MCP 도구 `remotedebug_crash_logs`로 보여 준다. 같은 내용의 기록은 한 번만 남긴다.

## M. iPhone 앱 두 개와 공용 VPN 신원

iPhone 앱은 둘이다. RemoteDebug(스킴 `RemoteDebugPhone`)와 업데이트 앱(스킴 `RemoteDebugVPN`, 홈 화면 이름 "RD 업데이트", 앱 안 제목 "RemoteDebug 업데이트"). 두 앱은 각자 터널 확장을 갖고, 두 확장은 같은 소스(`Apps/iOSTunnel`)로 빌드한다.

- RemoteDebug: 다른 앱의 빌드 설치, 파일, 크래시·피드백, Mac 페어링. 자기 번들 ID의 빌드는 목록에서 뺀다.
- 업데이트 앱: Mac의 빌드 목록에서 RemoteDebug 앱의 번들 ID인 빌드만 보여 주고 설치한다. VPN 켜기·끄기, 로그인, 기기 정보 가져오기도 한다. 페어링 화면은 없다.

업데이트 앱의 대상·스킴 이름, 번들 ID(`<앞부분>.RemoteDebugVPN`), URL 스킴(`remotedebug-vpn`)은 이 앱이 VPN만 맡던 때의 것을 그대로 쓴다. 호스트 API와 메시지 형식은 바뀌지 않았다. 업데이트 앱도 같은 tailnet 기기로 `/v1/info`, `/v1/builds`, 설치 세션을 부르므로 Mac은 두 앱을 같은 페어링한 기기로 본다.

### M.1 공용 저장소

- App Group `group.<번들 ID 앞부분>.RemoteDebug`(Info.plist의 App Group 키)를 두 앱과 두 확장이 함께 쓴다.
- Tailscale 상태(`tailscaled.state`, 노드 키)는 공용 컨테이너의 `Library/Application Support/RemoteDebug/tailscale`에 둔다. 그래서 어느 앱이 VPN을 켜도 같은 tailnet 기기이고 Mac 페어링이 유지된다.
- 예전 위치(RemoteDebug 터널 확장의 컨테이너)의 상태는 그 확장이 새 빌드로 처음 켜질 때 공용 위치로 옮긴다. 예전 상태가 Mac과 페어링한 기기라서, 공용 위치에 다른 상태가 이미 있어도(업데이트 앱을 먼저 켜 새 기기가 생긴 경우) 예전 상태로 바꾸고 밀려난 것은 `tailscale.replaced`에 한 벌 남긴다. 옮긴 뒤 공용 설정에 표시를 남긴다.
- RemoteDebug 앱은 열릴 때 업데이트 앱이 VPN을 켜 두었고 그 표시가 없으면, 자기 터널을 한 번 켜서 기기 정보를 옮긴 뒤 업데이트 앱을 열어 VPN을 돌려준다. 그 전까지 업데이트 앱은 다른 기기로 연결돼 있어 Mac이 `not_paired`로 거절한다.
- 페어링한 Mac(`hostId`, 이름, 주소, 페어링 시각, `updatePage`)은 공용 설정의 `RemoteDebug.pairedHost`에 둔다. RemoteDebug 앱의 예전 값(앱만의 설정)은 처음 한 번 옮기고 `RemoteDebug.pairedHostMigrated`를 적는다. 공용 설정에 값이 이미 있으면 덮지 않는다. 업데이트 앱은 이 값을 읽기만 하고(Mac이 알려 준 이름·`updatePage`가 바뀌면 다시 저장한다), 앞으로 올 때마다 다시 읽어 Mac이 바뀌었으면 목록을 새로 받는다. 값이 없으면 "페어링한 Mac이 없습니다"와 RemoteDebug 앱을 여는 버튼을 보여 준다.
- 기기 식별자(기기 이름의 뒷부분)와 제어 서버 주소는 공용 설정(UserDefaults suite)에 둔다. RemoteDebug 앱의 예전 값은 처음 한 번 옮긴다.
- 확장은 켜지고 꺼질 때 공용 설정에 `{owner, connected, updatedAt}`을 적는다. `owner`는 VPN을 켠 앱의 번들 ID다.

### M.2 VPN을 켠 쪽 알아내기

앱은 자기 VPN이 꺼져 있을 때 기기에 100.64.0.0/10 주소를 가진 `utun` 인터페이스가 있으면 다른 앱의 VPN이 켜져 있다고 보고 연결됨으로 다룬다. 공용 설정의 `owner`가 짝 앱이면 짝 앱의 VPN으로 표시한다. 공식 Tailscale 앱의 VPN도 같은 식으로 잡힌다.

### M.3 서로를 여는 주소

```
remotedebug-vpn://vpn?action=connect&return=1     RemoteDebug → 업데이트 앱
remotedebug://vpn?action=connect&return=1         업데이트 앱 → RemoteDebug
```

- `action`: `connect`(그 앱의 터널로 VPN을 켠다. 다른 앱의 VPN은 iOS가 끈다), `disconnect`, `open`.
- `return=1`: 일을 마친 뒤 요청한 앱으로 돌아간다. 로그인이 필요하면 돌아가지 않고 그 앱에 머문다.
- 다른 `action`이나 `vpn`이 아닌 호스트는 VPN 요청으로 다루지 않는다(페어링 링크 `remotedebug://pair`는 J).

### M.4 업데이트

iOS는 앱을 설치하는 동안 그 앱과 그 앱의 터널 확장을 끝낸다. 설치할 앱의 터널이 VPN을 켜고 있으면 전송이 도중에 끊기므로, 각 앱은 상대 앱이 설치하고 설치 전에 VPN을 자기 터널로 옮긴다.

- RemoteDebug 업데이트: 업데이트 앱에서 한다. VPN이 업데이트 앱의 터널이 아니면(RemoteDebug의 터널, 다른 VPN, 꺼짐) 먼저 자기 터널을 켜고, 연결될 때까지 최대 20초 기다린 뒤 설치 세션을 만든다. 단계("VPN을 이 앱으로 옮기는 중", "VPN이 연결되기를 기다리는 중")를 빌드 줄에 보여 준다. 연결되지 않거나 로그인이 필요하면 설치를 시작하지 않고 이유를 보여 준다.
- RemoteDebug 앱은 지금 빌드를 처음 실행한 시각보다 늦게 게시된 자기 빌드가 Mac에 있으면 "업데이트 앱" 칸에 "새 RemoteDebug 빌드가 있습니다. 업데이트 앱에서 설치하세요."와 **업데이트 앱 열기**(`action=open`)를 보여 준다. 설정 > "이 앱"에도 같은 버튼이 있다. 업데이트 앱이 열리지 않으면 빌드 목록에서 RD 업데이트를 설치하라고 안내한다.
- 업데이트 앱 업데이트: RemoteDebug의 빌드 목록에서 설치한다. 업데이트 앱의 터널이 VPN을 켜고 있으면 RemoteDebug가 같은 순서로 VPN을 넘겨받은 뒤 설치한다. 다른 앱의 빌드를 설치할 때는 VPN을 건드리지 않는다.
- 업데이트 앱이 없을 때 RemoteDebug를 업데이트하려면 공식 Tailscale을 켜고 I의 업데이트 페이지를 Safari로 연다.
- 두 앱 사이의 전환, 상태 이전, 페어링한 Mac 공유, VPN을 옮긴 뒤의 설치는 실기기에서 확인하지 않았다. 시뮬레이터 빌드와 단위 시험(저장소 이전, 빌드 고르기, VPN을 옮길지 정하는 규칙)만 통과했다.

## N. VPN 자동 켜기와 경로 표시

이 절은 tailnet(iPhone에서는 VPN)을 지나는 통신을 다룬다. 두 기기가 같은 네트워크에 있으면 Tailscale이 중계 서버를 거치지 않고 직접 주고받는다. 이 절은 앱이 VPN을 스스로 켜고 끄는 규칙과, 지금 경로가 직접인지 중계인지 알리는 필드를 정한다. VPN 없이 같은 네트워크에서 바로 주고받는 방식은 [O절](#o-같은-네트워크-직접-연결)에 있다.

실기기에서 확인하지 않았다. 단위 시험(켤지 정하는 규칙, 끄는 규칙, 모델의 설치·새로고침 흐름, 상태 필드의 인코딩)과 시뮬레이터 빌드만 통과했다. 시뮬레이터에서는 VPN 확장이 돌지 않는다.

### N.1 자동으로 켜기

앱이 Mac을 필요로 하는 동작을 시작할 때 VPN이 꺼져 있으면 이 앱의 VPN을 켠다. 해당 동작: 빌드 목록 새로고침(앱을 열 때와 앞으로 올 때 포함), 설치, 파일 받기, 진단 로그·크래시·피드백 보내기, 링크로 시작한 페어링.

다음을 모두 만족할 때만 켠다.

- 이 앱의 VPN도, 다른 앱의 VPN(M.2)도 켜져 있지 않다. 다른 앱의 VPN이 켜져 있으면 그것을 그대로 쓰고, 이 앱의 것으로 바꾸지 않는다.
- 이 앱의 VPN 구성이 iOS에 저장돼 있고 선택돼 있다.
- VPN 상태가 꺼짐이다. 연결 중, 로그인 필요, 오류 상태에서는 다시 켜지 않는다.

켠 뒤 연결될 때까지 최대 15초 기다리고, 그동안 VPN 칸과 설치 중인 빌드 줄에 "VPN 켜는 중…"을 보여 준다. 로그인이 필요하거나 연결되지 않으면 동작을 시작하지 않고 기존 안내를 보여 준다. 새로고침과 페어링은 나중에 VPN이 연결되면 이어 간다.

자동으로 하지 않는 것:

- VPN 구성 만들기. iOS의 "VPN 구성 추가" 동의가 필요하므로 사용자가 **VPN 켜기**를 눌러야 한다.
- 선택된 VPN 바꾸기. iOS 설정에서 다른 VPN(공식 Tailscale, 짝 앱)이 선택돼 있으면 사용자가 **VPN 켜기**를 눌러야 이 앱의 구성이 선택된다.
- 다른 앱의 VPN을 이 앱의 터널로 옮기기. **넘겨받기**, **이 앱으로 VPN 옮기기**, 짝 앱 설치 전의 넘겨받기(M.4)는 그대로 사용자의 동작으로만 일어난다.
- Tailscale 로그인.

### N.2 자동으로 끄기

앱이 자동으로 켠 VPN만 끈다. Mac이 필요한 일이 없는 채로 30초가 지나면 끈다. 다음이 남아 있으면 끄지 않는다: 진행 중인 설치와 iOS 설치기를 기다리는 설치 세션, 파일 전송, 새로고침, 로그·크래시 보내기, 진행 중이거나 VPN을 기다리는 페어링. 새 동작이 시작되면 30초를 다시 센다.

- 사용자가 켠 VPN, 짝 앱이나 다른 앱의 VPN은 끄지 않는다. 사용자가 VPN을 켜거나 끄면, 또는 이 앱으로 넘겨받으면 그때부터는 자동으로 켠 VPN으로 보지 않는다.
- 로그인을 기다리는 동안에는 끄지 않는다.
- 앱이 백그라운드에서 멈춰 있는 동안에는 시간을 세지 못한다. 그때는 앱으로 돌아온 뒤에 끈다.

### N.3 상태의 경로 필드

`rd_status`와 `state` 이벤트의 상태에 선택 필드가 둘 생겼다. 값이 없으면 키도 없다. 이 필드를 모르는 쪽은 무시하면 된다.

- `peerPath`(터널 모드): `rd_tunnel_set_path_peer`로 정한 피어까지의 경로.
- `peerPaths`(호스트 모드): 페어링한 기기별 경로. 키는 기기의 `nodeStableId`다.

경로 하나의 모양:

```json
{
  "direct": true,
  "addr": "192.168.0.10:41641",
  "relay": "tok"
}
```

| 필드 | 뜻 |
| --- | --- |
| `direct` | 중계 서버를 거치지 않고 피어와 직접 주고받으면 `true` |
| `addr` | 직접일 때 피어의 UDP 주소. 중계면 없다 |
| `relay` | 피어의 중계 지역 코드. 모르면 없다 |

- 피어에 지금 쓰는 UDP 주소가 있으면 직접이다. 없고 최근에 주고받은 것이 있으면 중계(`"direct": false`)다. 최근에 주고받은 것이 없는 피어는 경로를 모르므로 넣지 않는다.
- `backendState`가 `Running`일 때만 넣는다. 2초 상태 점검마다 다시 읽는다.
- 터널 모드에서 대상 피어가 정해져 있으면 코어는 점검마다 피어를 포함한 상태를 읽는다. 대상이 없으면 이전과 같이 피어 없는 상태만 읽는다.

```c
/* Tunnel mode: MagicDNS name of the peer whose path rd_status reports as
 * "peerPath". "" stops reporting. Returns {"ok":true}. */
char *rd_tunnel_set_path_peer(int64_t handle, const char *fqdn);
```

오류: 없는 핸들 `unknown_handle`, 터널 모드가 아님 `invalid_config`, 이름이 253자를 넘음 `bad_request`.

앱과 터널 확장 사이의 상태 요청에 선택 필드 `peer`가 생겼다.

```
{"cmd":"status","peer":"rd-mac-ab12cd34.example-tailnet.ts.net"}
```

앱은 페어링한 Mac의 주소를 넣는다. 확장은 이름이 바뀌었을 때 코어에 알린다. `peer`가 없는 요청은 이전과 같다.

### N.4 화면

- iPhone의 VPN 칸(두 앱 모두): 이 앱의 터널로 연결됐을 때 "연결됨 · 직접 연결(같은 네트워크)", "연결됨 · 직접 연결", "연결됨 · 중계 서버 경유" 가운데 하나를 보여 주고, 경로를 모르면 "연결됨"만 보여 준다. "같은 네트워크"는 피어 주소가 사설 대역(10/8, 172.16/12, 192.168/16, 169.254/16, fe80::/10, fc00::/7)일 때만 붙인다. 다른 앱의 VPN이 켜져 있으면 경로를 알 수 없으므로 "연결됨"만 보여 준다.
- RemoteDebug 앱의 설정 > VPN 진단: 직접일 때 피어 주소도 보여 준다. 진단 로그에는 주소를 남기지 않는다.
- Mac 앱의 **기기** 화면: 최근에 주고받은 기기의 줄에 "직접 연결(같은 네트워크)", "직접 연결", "중계 서버 경유"를 보여 준다.

### N.5 주문형 연결(선택)

RemoteDebug 앱의 설정에 "Mac에 연결할 때 VPN 자동으로 켜기(주문형)"가 있다. 기본은 꺼짐이고 값은 공용 설정의 `RemoteDebug.vpnOnDemand`에 둔다.

- 켜면 RemoteDebug 앱의 VPN 구성에 주문형 연결 규칙(연결 평가, 도메인은 페어링한 Mac의 주소, 필요하면 연결)을 저장하고 주문형 연결을 켠다. 끄거나 페어링한 Mac을 잊으면 규칙을 지운다. Mac이 바뀌면 규칙의 도메인을 바꾼다.
- VPN 구성이 없으면 켤 수 없다. 구성을 만들지 않는다.
- 업데이트 앱의 구성에는 규칙을 두지 않는다.
- 이 설정을 켜면 사용자가 VPN을 꺼도 iOS가 Mac 주소로 가는 연결을 볼 때 다시 켠다. N.2의 자동 끄기로 꺼진 VPN도 마찬가지다.
- iOS가 이 규칙으로 패킷 터널을 실제로 켜는지는 실기기에서 확인하지 않았다.

## O. 같은 네트워크 직접 연결

Mac과 iPhone이 같은 네트워크(같은 Wi-Fi)에 있으면 VPN 없이 직접 주고받는다. 빌드 목록, 파일 목록과 파일 받기, 진단 로그, 크래시·피드백 보내기가 여기에 해당한다. 직접 연결이 되지 않으면 N절대로 VPN을 자동으로 켜서 tailnet으로 보낸다. 앱 설치는 직접 연결이 되는 동안에도 VPN으로 한다(O.7).

실기기에서 확인하지 않았다(O.9). 코어의 리스너·인증·등록은 Go 시험으로, 경로 선택은 가짜 전송·시계·Bonjour를 쓴 Swift 시험으로, 리스너와 공개 키 고정은 이 Mac의 루프백 주소에서 실제 TLS 1.3 연결로 확인했다.

모든 새 필드와 경로는 선택이다. 이 절을 모르는 iPhone 앱은 등록하지 않고 이전처럼 tailnet만 쓴다. 이 절을 모르는 Mac 앱은 등록 요청에 `404`를 돌려주고, iPhone 앱은 10분 동안 다시 묻지 않는다.

### O.1 직접 연결 리스너

호스트 모드의 코어가 tailnet 리스너와 별도로 여는 HTTPS 리스너다. tailnet 상태(로그인, 연결)와 관계없이 열린다.

- 주소: 모든 인터페이스. 포트는 처음 열 때 빈 포트를 하나 골라 상태 폴더의 `direct.json`에 저장하고 계속 쓴다. 그 포트를 열 수 없게 되면 새 포트를 골라 저장한다.
- 받는 상대: 원격 주소가 사설(10/8, 172.16/12, 192.168/16, IPv6 fc00::/7)이나 링크 로컬(169.254/16, fe80::/10)일 때만 받는다. 그 밖의 주소(공인 주소, 100.64/10, Tailscale의 IPv6 대역 fd7a:115c:a1e0::/48, 루프백)는 TLS를 시작하기 전에 연결을 닫는다.
- TLS: 1.3만 받는다. 인증서는 이 리스너만 쓰는 자체 서명 P-256 키로, 처음 한 번 만들어 상태 폴더에 `direct-key.pem`, `direct-cert.pem`(권한 0600)으로 둔다. 키는 바꾸지 않는다(iPhone이 공개 키를 고정한다). tailnet 리스너의 인증서와 무관하다.
- 식별자: 16진수 16자의 무작위 값을 처음 한 번 만들어 `direct.json`에 둔다. Bonjour 인스턴스 이름으로만 쓴다.
- `/v1/info`의 `hostId`: tailnet 노드가 아직 올라오지 않았으면 마지막으로 알던 값(`direct.json`의 `hostId`)을 돌려준다.

설정(`rd_start`)의 선택 필드 `directListen`이 `true`면 시작할 때 연다. 없으면 열지 않는다. 실행 중에는 다음 함수로 켜고 끈다.

```c
/* Turns the same-network listener on (1) or off (0).
 * Returns {"ok":true,"direct":{"listening":bool,"port":N,"id":"…"}}. */
char *rd_host_set_direct(int64_t handle, int32_t on);
```

오류: 없는 핸들 `unknown_handle`, 호스트 모드가 아님 `invalid_config`, 종료된 노드 `not_running`, 키를 만들지 못했거나 포트를 열지 못함 `internal`.

상태(`rd_status`, `state` 이벤트)의 선택 필드 `direct`. 이번 실행에서 리스너를 한 번도 켜지 않았으면 키가 없다.

```json
{
  "listening": true,
  "port": 49152,
  "id": "0123456789abcdef"
}
```

### O.2 리스너가 받는 경로

| 경로 | 직접 연결 리스너 |
| --- | --- |
| `GET /v1/info`, `GET /v1/builds` | 받는다 |
| `GET /v1/resources`, `GET /v1/resources/{id}` | 받는다 |
| `POST /v1/logs`, `POST /v1/crashes` | 받는다 |
| `GET /v1/agent`, `POST /v1/agent/requests`, `POST /v1/agent/requests/{id}/cancel` | 받는다(tailnet 리스너와 같은 조건) |
| `/`, `/assets/*`(웹 페이지) | `404 not_found` |
| `/v1/pair/*`(페어링) | `404 not_found` |
| `POST /v1/direct/enroll`(등록) | `404 not_found` |
| `POST /v1/builds/{id}/sessions`, `GET /v1/sessions/{id}`, `/i/*`(설치) | `404 not_found` |

인증을 경로보다 먼저 본다. 토큰이 없거나 틀린 요청은 어떤 경로든 `403 not_paired`를 받으므로, 페어링하지 않은 쪽은 어떤 경로가 있는지 알 수 없다. 응답 모양과 `X-RD-Protocol: 1` 머리말은 tailnet 리스너와 같다.

### O.3 인증

요청마다 기기 토큰을 싣는다.

```
Authorization: RD-Device <deviceId>.<token>
```

- `deviceId`는 허용 목록 항목의 `id`, `token`은 등록(O.4)에서 받은 값(32바이트 난수의 base64url, 채움 문자 없음)이다.
- 코어는 토큰 32바이트의 SHA-256(16진수)을 그 기기 항목의 `directTokenHash`와 시간 차 없이 비교한다. 토큰 자체는 Mac 어디에도 저장하지 않는다.
- 맞으면 그 기기의 tailnet 신원(노드 StableID, 노드 이름, 로그인 이름)으로 요청을 처리한다. 그래서 처리기와 이벤트(`device-log`의 `deviceId` 등)는 tailnet으로 온 요청과 같다. 직접 연결에서는 WhoIs를 부르지 않는다.
- 틀리면 `403 not_paired`를 돌려주고 기존 `denied` 이벤트(경로와 이유만, 주소 없음)를 낸다.
- 한 원격 IP에서 1분 안에 10번 틀리면 그 1분이 끝날 때까지 그 IP의 요청은 토큰을 보지 않고 `429 too_many_attempts`로 답한다.
- Mac 앱에서 기기를 지우면 허용 목록에서 항목이 빠지므로 다음 요청부터 `403`이다.

### O.4 등록

tailnet 리스너에서만 받는다. 허용 목록에 있는 기기(WhoIs + 허용 목록)만 부를 수 있다.

```
POST /v1/direct/enroll        (본문 없음)
```

```json
{
  "directId": "0123456789abcdef",
  "port": 49152,
  "tlsSPKI": "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=",
  "deviceId": "d_9c2e41b7",
  "token": "Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE"
}
```

| 필드 | 뜻 |
| --- | --- |
| `directId` | Mac이 Bonjour로 광고하는 인스턴스 이름 |
| `port` | 직접 연결 리스너의 포트 |
| `tlsSPKI` | 리스너 인증서의 SubjectPublicKeyInfo(DER) SHA-256, base64 |
| `deviceId`, `token` | O.3의 인증 값 |

- 다시 부르면 토큰이 바뀌고 이전 토큰은 그 즉시 쓸 수 없다.
- 리스너가 꺼져 있으면 `404 direct_off`, 허용 목록에 없으면 `403 not_paired`.
- 코어는 해시를 기기 항목에 넣고 `device-updated` 이벤트를 낸다. 모양은 `device-added`와 같고(`device`에 항목 전체), 항목에 선택 필드 `directTokenHash`가 있다. 이벤트에 토큰은 없다.
- Mac 앱은 `device-updated`를 받으면 이미 허용한 기기의 해시만 바꿔 `devices.json`에 저장하고, 다음 시작 때 `rd_host_set_devices`로 해시까지 넣는다. 그래서 Mac 앱을 다시 시작해도 iPhone이 다시 등록하지 않아도 된다. 그사이 지운 기기의 `device-updated`는 무시한다.
- 같은 기기를 다시 페어링하면 새 항목에는 해시가 없다. iPhone은 `403`을 받고 다시 등록한다.

### O.5 찾기

- Mac 앱(Swift)이 Bonjour 서비스 `_remotedebug._tcp`를 직접 연결 포트로 광고한다. 인스턴스 이름은 O.1의 식별자, TXT는 `v=1` 하나다. Mac 이름, tailnet 주소, 호스트 id는 광고에 없다. 리스너가 열려 있고 스위치가 켜져 있을 때만 광고한다.
- iPhone은 등록할 때 받은 `directId`와 이름이 같은 광고만 찾는다. 찾으면 그 서비스에 TCP 연결을 한 번 열어 IPv4 주소와 포트를 알아낸 뒤 닫는다(아무것도 보내지 않는다).
- iOS의 로컬 네트워크 권한이 없으면 광고를 찾지 못한다. 그때는 안내 없이 VPN 경로를 쓴다. 마지막으로 알던 주소로 가는 확인 요청도 같은 권한을 탄다.
- 두 iPhone 앱과 Mac 앱의 Info.plist에 `NSLocalNetworkUsageDescription`과 `NSBonjourServices`(`_remotedebug._tcp`)가 있다. iPhone 앱에는 `NSAllowsLocalNetworking`도 있다: 사설 IP 주소로 가는 연결에 한해 ATS의 이름·인증 기관 요구를 푼다. 서버 확인은 O.6의 공개 키 고정이 한다.

### O.6 공개 키 고정

iPhone은 `https://<Mac의 사설 IP>:<포트>`에 연결하고, 서버가 낸 인증서(체인의 첫째)의 SubjectPublicKeyInfo SHA-256이 등록 때 받은 `tlsSPKI`와 같을 때만 연결을 받아들인다. 이름, 만료, 시스템 신뢰는 보지 않는다. 이 규칙은 직접 연결용 전송에만 있고 tailnet 전송은 시스템 신뢰를 그대로 쓴다.

- 다르면 TLS 연결 단계에서 끊는다. 요청 머리말(토큰)은 TLS 연결이 받아들여진 뒤에만 나가므로, 식별자를 흉내 낸 광고에는 토큰이 가지 않는다.
- 주소가 사설·링크 로컬 IP가 아니면 직접 연결용 요청을 만들지 않는다.
- 전송은 TLS 1.3 이상, 셀룰러 금지, 시스템 프록시 사용 안 함, 리다이렉트 따르지 않음이다.
- 공개 키가 같아도 `/v1/info`의 `hostId`가 페어링한 Mac과 다르면 쓰지 않는다.

### O.7 경로 선택

등록 값(`deviceId`, 토큰, 공개 키 고정 값, 포트, `directId`, 마지막 주소)은 iPhone의 Keychain(`AfterFirstUnlockThisDeviceOnly`)에 둔다.

두 iPhone 앱은 같은 tailnet 기기라 Mac의 기기 항목이 하나고 토큰도 하나다. 앱마다 따로 등록하면 서로의 토큰을 무효로 만들기 때문에, 등록 값은 App Group 이름을 Keychain 접근 그룹으로 써서 두 앱이 함께 쓴다. 그 그룹을 쓸 수 없는 빌드에서는 앱마다 따로 저장한다(그때는 앱을 바꿔 쓸 때마다 한 번씩 다시 등록한다). 직접 경로가 `403`을 돌려주면 다시 등록하기 전에 보관소를 다시 읽어, 짝 앱이 받은 새 토큰이 있으면 그것을 쓴다.

요청마다:

1. 등록돼 있고 Wi-Fi(또는 유선)에 붙어 있으면 직접 경로를 찾는다. 마지막 주소에 `GET /v1/info`(제한 1초)를 보내는 것과 Bonjour 찾기(제한 2초)를 함께 시작한다. 마지막 주소가 답하면 Bonjour 결과를 기다리지 않는다. 한 번 찾은 주소는 실패할 때까지 다시 확인하지 않고 쓴다.
2. 직접 경로의 요청이 연결 오류(연결 실패, 시간 초과)로 끝나면 한 번 다시 찾아 보낸다. 또 실패하면 그 요청을 tailnet 경로로 보내고 60초 동안 직접 경로를 찾지 않는다.
3. HTTP 오류 응답은 경로 문제가 아니다. 그대로 알리고 경로를 바꾸지 않는다. `403 not_paired`와 `429 too_many_attempts`만 예외다: 그 요청을 tailnet 경로로 보내고 다시 등록한다.
4. tailnet 경로는 N절대로 VPN이 꺼져 있으면 자동으로 켠다. tailnet 요청이 성공했는데 등록이 없거나 거절됐으면 그 자리에서 등록한다.
5. 방금 받은 토큰이 다시 거절되면 10분 동안 등록하지 않고 tailnet 경로만 쓴다.

다시 찾는 때: 네트워크가 바뀌었을 때(Wi-Fi에 붙거나 떨어짐), 앱이 다시 활성이 됐을 때, 그리고 찾지 못한 지 60초가 지난 뒤의 첫 요청. 요청이 없는 동안에는 찾지 않는다.

직접 경로로 가는 것: 빌드 목록 새로고침(`/v1/info`, `/v1/builds`, `/v1/resources`), 파일 받기, 로그 보내기, 크래시·피드백 보내기.

tailnet으로만 가는 것과 그 이유:

- 설치(`POST /v1/builds/{id}/sessions`, 진행 확인, `/i/*`): iOS 설치기(`itms-services`)는 시스템이 신뢰하는 인증서의 HTTPS 주소에서만 매니페스트와 IPA를 받는다. 그런 주소는 tailnet 이름(`*.ts.net`)뿐이다. 그래서 설치를 누르면 직접 연결 중이어도 VPN을 자동으로 켜고, 설치 주소는 지금처럼 tailnet 이름일 때만 연다.
- 페어링과 등록: 누구인지를 tailnet 신원(WhoIs)으로 확인해야 한다.
- 에이전트 요청: iPhone 앱이 VPN 연결을 조건으로 둔 채 그대로다(기능이 숨겨져 있다).

파일 받기는 경로에 따라 방식이 다르다. tailnet 경로는 이전처럼 시스템 백그라운드 세션을 쓴다. 직접 경로는 앱이 떠 있는 동안만 도는 세션으로 받고, 끊긴 전송은 같은 파일을 다시 받을 때 이어 받는다(Range). 백그라운드 세션이 앱이 멈춘 사이의 서버 확인을 고정 값으로 처리한다고 보장할 수 없기 때문이다. 그래서 직접 경로로 받는 큰 파일은 앱을 백그라운드로 보내면 멈출 수 있다.

자동으로 켠 VPN(N.2): 직접 경로로 받는 파일은 VPN이 필요한 일로 세지 않는다. 직접 경로가 되는 동안에는 설치가 끝난 뒤 30초가 지나면 VPN이 꺼진다.

### O.8 화면

- iPhone의 VPN 칸(두 앱 모두): VPN이 꺼져 있고 직접 경로를 쓰고 있으면 "직접 연결(같은 Wi-Fi, VPN 없이)"을 보여 준다. VPN이 켜져 있으면 N.4의 문구를 그대로 보여 준다.
- Mac 앱의 **네트워크** 화면: "같은 네트워크에서 직접 연결" 스위치(기본 켜짐)와 상태("켜짐 · 포트 N", "꺼짐" 등). 끄면 리스너와 Bonjour 광고를 멈춘다. 값은 Mac 앱의 설정(UserDefaults)에 저장한다.
- Mac 앱의 **기기** 화면: 등록한 기기의 줄에 "같은 네트워크 직접 연결 등록됨"을 보여 준다.
- iPhone의 진단 로그에는 경로가 바뀐 사실만 남기고 주소와 토큰은 남기지 않는다.

### O.9 보안 속성과 확인하지 못한 것

달라진 점: 이전에는 Mac의 API에 닿으려면 tailnet 안에 있어야 했다. 이제 같은 네트워크(LAN)에 있는 누구나 직접 연결 포트의 TLS까지는 닿을 수 있다. API를 쓰려면 페어링한 기기의 토큰이 필요하다. Tailscale ACL은 직접 경로에 적용되지 않는다. 받아들일 수 없으면 Mac 앱의 스위치를 끈다.

- 같은 네트워크의 모르는 기기: 모든 요청이 `403`이다. 직접 연결 포트에는 페어링, 등록, 설치, 웹 페이지가 없다.
- 식별자를 흉내 낸 Bonjour 광고: 공개 키가 달라 TLS에서 끊기고 토큰은 나가지 않는다.
- 토큰은 공개 키를 고정한 TLS 1.3 안에서만 나간다. Mac에는 해시만 있고, iPhone에서는 Keychain에만 있다.
- 토큰을 가진 쪽이 할 수 있는 일은 O.2의 경로뿐이다. 설치 세션을 만들거나 IPA를 받을 수 없다.
- 리스너의 개인 키 파일을 읽을 수 있는 Mac의 프로세스는 같은 네트워크에서 그 Mac인 척할 수 있다. 상태 폴더의 다른 비밀(tailnet 노드 키)과 같은 수준으로 지킨다.

실기기에서 확인하지 못한 것:

- iOS의 로컬 네트워크 권한 창이 뜨는 때와, 거절했을 때 VPN 경로로 넘어가는지.
- `NSAllowsLocalNetworking`과 공개 키 고정으로 사설 IP의 자체 서명 인증서에 실제로 연결되는지(ATS).
- VPN이 켜진 채 같은 Wi-Fi의 Mac에 직접 연결이 되는지, 다른 앱의 VPN이 모든 트래픽을 가져갈 때 VPN 경로로 넘어가는지.
- App Group 이름을 Keychain 접근 그룹으로 써서 두 앱이 등록 값을 함께 읽는지.
- macOS 방화벽이 켜져 있을 때 들어오는 연결 허용을 묻는지, Mac의 Bonjour 광고가 iPhone에 보이는지.
- 직접 경로의 큰 파일 받기와 이어 받기.
