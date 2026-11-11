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
