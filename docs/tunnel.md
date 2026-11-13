# 패킷 터널 (protocol.md §6과 architecture.md 가정 A1을 대체)

> 이 문서가 대체하는 곳: `protocol.md` §6 전체와 §9의 프록시 관련 부분(`mode`가 `host`/`proxy`뿐이라는 문장, iPhone 쪽 `rd_proxy_start` 사용), `architecture.md`의 가정 A1과 구성도. 그 문서들은 아직 고치지 않았으므로 충돌하면 이 문서를 따른다.

터널 모드의 규칙은 이 문서에만 쓴다. `protocol.md`와 `protocol-addenda.md`의 규칙(상태 값, 오류 형식, 큐, 로그)은 터널 모드에도 그대로 적용되고, 이 문서는 그 위에 더하는 것만 적는다.

## 변경 이유

초기 설계는 터널 확장이 로컬 HTTP CONNECT 프록시를 띄우고 `NEProxySettings`로 시스템 프록시를 지정하는 방식이었다. Apple의 TN3120은 이를 명시적으로 권장하지 않는다(판정서 `appstore-review.md`의 TN3120 인용 참조). 그래서 터널 확장은 **IP 패킷을 tailnet으로 중계하는 일반 VPN**으로 바꾼다.

- 장점: 설치기를 포함한 시스템 전체가 일반 VPN처럼 tailnet 경로로 호스트에 닿는다. "설치기가 프록시 설정을 따르는가"라는 미확인 가정(A1)이 사라진다. Tailscale 공식 iOS 앱과 같은 구조다.
- 비용: Go 쪽이 tsnet 대신 Tailscale 엔진(LocalBackend + WireGuard 엔진 + netstack)을 utun과 함께 조립한다.

호스트 모드와 프록시 모드는 그대로 둔다. 프록시 모드는 터널이 문제를 일으킬 때 실기기에서 원인을 가르는 진단용으로만 남긴다.

## 구성

```
 터널 확장 프로세스 (RemoteDebugTunnel)
  Swift: utun fd 탐색, NEPacketTunnelNetworkSettings 적용, 이벤트 루프, NWPathMonitor
  Go (mode "tunnel"): ipnlocal.LocalBackend + wgengine(Tun = utun fd의 복제본)
                      + netstack(100.100.100.100 MagicDNS 응답만)
        ↑ rd_start / rd_next_event / rd_status / rd_tunnel_set_default_interface / rd_stop
```

- 터널 확장은 둘이다(RemoteDebug 앱의 것과 업데이트 앱의 것). 같은 소스로 빌드하고, Tailscale 상태를 App Group의 공용 컨테이너에 두어 같은 tailnet 기기로 뜬다(`docs/protocol-addenda.md` M). iOS가 VPN을 하나만 켜므로 둘이 동시에 돌지 않는다.
- 프로세스당 터널 노드는 하나다. 터널 노드가 살아 있는 동안 두 번째 터널 `rd_start`는 `invalid_config`로 실패한다. 메시지는 `stateDir`에 따라 다르다. 같은 `stateDir`면 `stateDir` 검사가 먼저 걸려 `"state_dir_in_use"`, 다른 `stateDir`면 `"tunnel_in_use"`다. 둘 다 "앞 노드를 `rd_stop`한 뒤 다시 시작"으로 처리한다. `rd_stop`이 끝나면 다시 시작할 수 있다. 시작이 터널 자리를 잡은 뒤 실패해도(로그 파일, utun, 엔진 생성) 자리는 풀린다. 호스트·프록시 노드와는 함께 돌 수 있다.
- 상태는 `stateDir/tailscaled.state` 파일에 둔다. 확장이 다시 시작돼도 노드 키·tailnet IP·StableID가 유지되므로 호스트의 페어링(StableID 기준)이 깨지지 않는다. 앱의 프록시 모드와 같은 `stateDir`를 쓰지 않는다(A.3의 `state_dir_in_use`).

## 설정 (`rd_start`)

`mode`에 `"tunnel"`을 쓴다. `stateDir`, `hostname`, `authKey`, `controlURL`, `ephemeral`, `goMemLimitMiB`, `logPath`, `hostDisplayName`, `appVersion`은 §9·A.1과 같다. `port`, `listenTLS`, `publishDir`, `allowedTargets`는 터널 모드에서 검사하지도 쓰지도 않는다.

```json
{
  "mode": "tunnel",
  "stateDir": "/path/to/state",
  "hostname": "rd-phone-ab12cd34",
  "authKey": "",
  "controlURL": "",
  "ephemeral": false,
  "goMemLimitMiB": 28,
  "logPath": "",
  "utunFd": 7,
  "mtu": 1280
}
```

- `utunFd`: 터널 확장이 찾은 utun 제어 소켓의 fd. 필수다.
  - 코어는 이 fd를 `dup`해 복제본(close-on-exec, non-blocking)만 쓰고, `rd_stop`이나 실패한 `rd_start`에서 복제본만 닫는다. 원래 fd는 Network Extension 것이므로 Swift도 닫지 않는다.
  - non-blocking 플래그는 같은 열린 파일 설명을 공유하는 원래 fd에도 적용된다. Swift는 이 fd로 읽고 쓰지 않으므로 문제가 없다.
  - 코어는 시작 전에 fd가 utun 소켓인지 읽기만 하는 호출로 확인한다(peer가 커널 제어 소켓이고 인터페이스 이름이 `utun`으로 시작). 아니면 `invalid_config`다.
- `mtu`: 1280 이상 1420 이하. 0이나 생략은 1280. 범위 밖은 `invalid_config`. 코어는 utun의 MTU를 바꾸지 않는다. Swift가 `NEPacketTunnelNetworkSettings.mtu`로 적용한 값을 WireGuard가 utun에서 읽어 쓰고, 코어는 이 값을 `network-settings`의 `mtu`로 돌려줄 뿐이다.
- 잘못된 `mode`·`utunFd`·`mtu`와 `tunnel_in_use`는 메모리 한도·GC 설정, 로그 파일, 엔진 생성 같은 부작용 전에 거절된다.

## 상태 (`rd_status`)

필드와 `backendState` 규칙은 A.5와 같다. 터널 모드에서는 다음이 다르다.

- `tunnel` 객체가 늘 있다. 첫 설정 전에는 배열이 비어 있고 `mtu`는 설정값이다. 호스트·프록시 모드에는 이 객체가 없다.
- `tlsReady`, `listening`은 늘 `false`, `publishedBuilds`, `pairedDevices`는 `0`이다. `certDomains`는 tailnet이 준 값 그대로다.
- 백엔드 오류(인증 키 거부, 제어 서버 오류)는 호스트 모드와 같이 `Error` + `errorMessage`다. `NeedsLogin`인데 `authURL`이 비고 `authKey`가 없으면 30초에 한 번까지 로그인을 다시 시작한다(A.5와 같다).
- 엔진이 스스로 멈추면(utun 읽기 오류로 WireGuard가 장치를 닫음) `backendState`는 `Error`, `errorMessage`는 `"TUN 장치가 닫혔습니다."`이고 `state` 이벤트가 나간다. 이 상태는 `rd_stop` 전까지 풀리지 않는다.

```json
{
  "backendState": "Running",
  "authURL": "",
  "hostname": "rd-phone-ab12cd34",
  "fqdn": "rd-phone-ab12cd34.example-tailnet.ts.net",
  "tailscaleIPs": ["100.64.0.11", "fd7a:115c:a1e0::b"],
  "certDomains": [],
  "tlsReady": false,
  "listening": false,
  "publishedBuilds": 0,
  "pairedDevices": 0,
  "rssMiB": 27.5,
  "tunnel": {
    "addresses": ["100.64.0.11/32", "fd7a:115c:a1e0::b/128"],
    "routes": ["100.64.0.10/32", "fd7a:115c:a1e0::/48", "100.100.100.100/32", "fd7a:115c:a1e0::53/128"],
    "dnsServers": ["100.100.100.100", "fd7a:115c:a1e0::53"],
    "dnsMatchDomains": ["example-tailnet.ts.net", "64.100.in-addr.arpa"],
    "mtu": 1280,
    "peerCount": 1
  }
}
```

`tunnel`의 앞 다섯 필드는 마지막 `network-settings` 이벤트와 같다. `peerCount`는 netmap의 피어 수이며 2초 상태 점검마다 한 번 센다.

`rd_tunnel_set_path_peer`로 피어를 정하면 그 피어까지의 경로(직접·중계)가 선택 필드 `peerPath`로 붙는다([protocol-addenda.md](protocol-addenda.md) N.3). 그때 `peerCount`는 피어를 포함한 상태에서 센다.

## 이벤트 `network-settings`

엔진이 주소·경로·DNS를 계산하거나 바꿀 때 보낸다.

```json
{
  "type": "network-settings",
  "addresses": ["100.64.0.11/32", "fd7a:115c:a1e0::b/128"],
  "routes": ["100.64.0.10/32", "fd7a:115c:a1e0::/48", "100.100.100.100/32", "fd7a:115c:a1e0::53/128"],
  "dnsServers": ["100.100.100.100", "fd7a:115c:a1e0::53"],
  "dnsMatchDomains": ["example-tailnet.ts.net", "64.100.in-addr.arpa"],
  "mtu": 1280
}
```

- `addresses`: 노드의 tailnet 주소(CIDR, IPv4는 /32, IPv6는 /128).
- `routes`: 엔진이 계산한 경로를 그대로 쓴다. iOS에서 엔진은 IPv4를 피어마다 /32로(엔진이 합칠 수 있으면 합쳐서) 내고, 100.100.100.100/32를 포함한다. 코어가 `100.64.0.0/10`으로 넓히지 않는다. 통신사 CGNAT 주소(100.64.0.0/10 대역)를 터널로 끌어들이면 그 주소로 가는 일반 트래픽이 끊기기 때문이다. iOS에서는 제어 서버가 하나의 CGNAT 경로를 지시할 때(OneCGNAT 노브)만 `100.64.0.0/10`이 나온다. "다른 인터페이스가 그 대역을 쓰지 않으면 하나로 합친다"는 엔진의 자동 규칙은 macOS와 Android에만 적용된다(`ipnlocal.shouldUseOneCGNATRoute`). 그래서 macOS에서 도는 e2e 테스트는 `100.64.0.0/10` 하나를 볼 수 있고, 피어별 /32 경로는 실기기에서만 나온다.
- 주소가 없는 패밀리의 경로와 DNS 서버는 뺀다. IPv4 주소만 있으면 IPv6 경로·DNS 서버가 없고, 반대도 같다.
- 터널은 기기의 일반 DNS를 맡지 않는다. tailnet 이름만 100.100.100.100으로 보낸다.
- `dnsServers`: MagicDNS 서비스 주소(100.100.100.100, fd7a:115c:a1e0::53). IPv4가 먼저다. 비어 있으면(노드 키 만료, MagicDNS가 꺼져 있고 tailnet 이름도 없음) DNS 설정을 하지 않는다.
- `dnsMatchDomains`: `dnsServers`가 있으면 늘 비어 있지 않다(끝의 점 제거). 엔진이 범위 지정 설정을 내면 그 일치 도메인을 그대로 쓴다. 엔진이 100.100.100.100을 기기의 기본 리졸버로 삼으려 하면(사용자 지정 서버로 가는 split DNS, 역방향 영역 밖 주소의 ExtraRecord, `DisableSplitDNSWhenNoCustomResolvers` 노브, 제어 서버의 "override local DNS") 코어가 100.100.100.100이 직접 답하는 접미사만 남긴다: tailnet 접미사, `64.100.in-addr.arpa`~`127.100.in-addr.arpa`, `0.e.1.a.c.5.1.1.a.7.d.f.ip6.arpa`, 다른 경로에 덮이지 않는 ExtraRecord 이름. 이때 사용자 지정 서버로 가는 split DNS 접미사(`corp.example.com` 등)는 넣지 않으므로 그 이름은 터널로 풀리지 않는다. 검색 도메인은 보내지 않으므로 짧은 이름(`rd-mac-ab12cd34`)은 풀리지 않고 FQDN만 풀린다.
- 100.100.100.100에 직접 보낸 tailnet 밖 이름은 SERVFAIL이다(코어가 기기 리졸버로 넘기지 않는다). 제어 서버가 기본 리졸버를 지정했으면 그쪽으로 넘긴다.
- 실제로 바뀐 경우에만 보낸다. 같은 설정이면 보내지 않는다(설정 적용 → utun 링크 변경 → 엔진 재설정 → 다시 적용으로 도는 고리를 막는다). 주소가 없을 때(시작 직후, `NeedsLogin`, `Stopped`)와 `rd_stop`에서는 보내지 않는다.
- 큐에는 최신 것 하나만 남는다. 아직 꺼내지 않은 `network-settings`가 있으면 새 이벤트가 그것을 대신한다. 큐가 넘쳐 잃어도 `rd_status`의 `tunnel`이 마지막 설정을 담고 있다.

## C API `rd_tunnel_set_default_interface`

```c
/* Tunnel mode: name of the interface that now carries the default route
 * (NWPathMonitor), e.g. "en0" or "pdp_ip0". "" is ignored. Returns {"ok":true}. */
char *rd_tunnel_set_default_interface(int64_t handle, const char *if_name);
```

Swift: `RDNode.setDefaultInterface(_ name: String) throws`.

- Network Extension은 터널을 만들 때 한 번만 위임 인터페이스를 정하므로, Wi-Fi ↔ 셀룰러 전환 뒤에도 코어의 제어·DERP·WireGuard 소켓이 옛 인터페이스에 묶일 수 있다. 코어는 이름을 `netmon.UpdateLastKnownDefaultRouteInterface`로 넘기고, 이름이 바뀌었으면 곧바로 네트워크 상태를 다시 계산하게 한다(`netmon.Monitor.InjectEvent`). 기본 인터페이스가 바뀐 것으로 계산되면 엔진이 WireGuard 소켓을 새 인터페이스에 다시 묶고 DERP·제어 연결을 다시 맺는다. 경로 소켓 이벤트를 기다리지 않는다.
- 빈 문자열은 무시된다. 코어는 마지막 이름을 기억하되, 그 인터페이스가 내려가거나 주소가 없으면 라우팅 표로 기본 경로를 찾는다. 프로세스 전체 설정이다.
- 오류: 없는 핸들 `unknown_handle`, 터널 모드가 아님 `invalid_config`, 이름이 15자를 넘거나 영문·숫자·`_`·`.`·`-` 밖의 문자를 담음 `bad_request`.

## 터널 확장(Swift)의 책임

1. `startTunnel`
   - 프로세스의 fd를 훑어 utun 제어 소켓(`com.apple.net.utun_control`)을 찾는다. 첫 `setTunnelNetworkSettings` 전에 utun과 fd가 있는지는 실기기에서 확인한다. 없으면 자리표시 설정(터널 원격 주소와 `mtu`만, 경로 없음)을 먼저 적용한 뒤 찾는다.
   - `rd_start(mode: "tunnel", utunFd, mtu, …)`를 부르고 `rd_next_event` 루프를 전용 스레드(`RDNode.events()`)에서 돌린다. `rd_start`와 `rd_stop`은 같은 직렬 큐에서 부른다.
   - `NWPathMonitor`를 시작해 만족된 경로의 첫 인터페이스 이름이 바뀔 때마다 `setDefaultInterface`를 부른다(시작 직후 한 번 포함).
2. `network-settings`를 받으면 `NEPacketTunnelNetworkSettings`로 바꿔 적용한다.
   - `tunnelRemoteAddress`는 필수다. `"127.0.0.1"`을 쓴다. NE는 이 주소를 VPN 서버로 보고 터널 밖 경로를 따로 둘 수 있으므로, 터널로 보내야 하는 100.100.100.100 같은 주소를 쓰면 MagicDNS 질의가 터널을 벗어날 수 있다.
   - `addresses`의 IPv4 CIDR → `NEIPv4Settings(addresses:subnetMasks:)`(접두 길이를 점 표기 마스크로), IPv6 CIDR → `NEIPv6Settings(addresses:networkPrefixLengths:)`. 패밀리에 주소가 없으면 그 설정을 만들지 않는다.
   - `routes` → 패밀리별 `includedRoutes`(`NEIPv4Route(destinationAddress:subnetMask:)`, `NEIPv6Route(destinationAddress:networkPrefixLength:)`).
   - `dnsServers`가 비어 있으면 `dnsSettings = nil`. 아니면 `NEDNSSettings(servers: dnsServers)`, `matchDomains = dnsMatchDomains`(늘 비어 있지 않은 목록), `matchDomainsNoSearch = true`. `matchDomains = [""]`(모든 질의)는 쓰지 않는다. 만약 `dnsMatchDomains`가 비어 오면 DNS를 설정하지 않는다(`dnsSettings = nil`).
   - `mtu` → `mtu`. 프록시 설정은 쓰지 않는다.
   - `setTunnelNetworkSettings`는 한 번에 하나만 진행한다. 진행 중에 온 설정은 최신 것 하나만 보관했다가 완료 콜백에서 적용한다.
3. `packetFlow.readPackets`·`writePackets`를 부르지 않는다. 패킷은 코어가 utun fd로 직접 읽고 쓴다.
4. `state` 이벤트
   - `NeedsLogin`과 `authURL`은 앱이 `sendProviderMessage`로 물을 때 돌려준다.
   - `backendState == "Error"`이고 `errorMessage`가 `"TUN 장치가 닫혔습니다."`이면 `cancelTunnelWithError`로 터널을 끝낸다. iOS는 이렇게 끝난 터널을 주문형(On Demand) 규칙이 있을 때만 스스로 다시 연결한다. 그래서 컨테이너 앱이 `NEVPNStatusDidChange`로 VPN 상태를 지켜보다가 이 오류로 `disconnected`가 되면 `startVPNTunnel`로 다시 연결한다. 앱은 추가로 `isOnDemandEnabled`와 `NEOnDemandRuleConnect`를 설정할 수 있다(첫 잠금 해제 전 시작은 실기기 확인 항목 7).
5. `stopTunnel`: `rd_stop`을 메인 스레드가 아닌 직렬 큐에서 부른다(엔진 종료는 최대 몇 초 걸릴 수 있다). 끝나면 `completionHandler`를 부른다.

## 테스트 계약 (Go, `-race`)

가짜 tailnet(testcontrol + 로컬 DERP)과 메모리 TUN(`internal/faketun`, `node.Options.Tun`으로 주입)만 쓴다. `scripts/go.sh test -race -count=1 -run TestTunnel -v ./...`

| 테스트 | 확인하는 것 |
| --- | --- |
| `TestTunnelDataPath/network-settings` | `Running` 뒤 `network-settings`의 `addresses`에 노드 IP/32, `routes`에 피어 tailnet IP를 덮는 경로, `dnsServers[0] == 100.100.100.100`, `dnsMatchDomains`에 tailnet 접미사(끝 점 없음), `mtu 1280`. `status.tunnel`이 이벤트와 같고 `peerCount ≥ 1` |
| `TestTunnelDataPath/udp` | 피어 UDP 에코로 보낸 패킷의 응답이 TUN으로 나온다(1초마다 재시도) |
| `TestTunnelDataPath/tcp` | 피어 TCP 포트로 보낸 SYN에 SYN-ACK가 나온다(1초마다 재시도) |
| `TestTunnelDataPath/magicdns` | `100.100.100.100:53`으로 보낸 피어 FQDN A 질의에 피어 IP가 답으로 나온다 |
| `TestTunnelDataPath/stop` | `rd_stop` 뒤 TUN이 닫히고 핸들이 무효. 모든 정리 뒤 고루틴 수가 시작 때로 돌아온다(`tstest.ResourceCheck`) |
| `TestTunnelEngineDeath` | TUN 읽기 오류 → `Error` + `"TUN 장치가 닫혔습니다."` `state` 이벤트, TUN 닫힘. 그 뒤 1.5초 동안 `error` 로그 없음·이벤트 5개 이하·큐 넘침 없음(감시 루프가 돌지 않음), `rd_status`는 계속 `Error`, 깨끗한 `rd_stop` |
| `TestTunnelRestartKeepsNode` | `stateDir/tailscaled.state`가 생기고, 같은 `stateDir`로 다시 시작하면 같은 IP·`NeedsLogin` 없음, 새 `stateDir`는 다른 IP, 옮긴 `stateDir`는 원래 IP |
| `TestTunnelInUse` | 다른 `stateDir`의 두 번째 터널 `tunnel_in_use`, 같은 `stateDir`는 `state_dir_in_use`, `rd_stop` 뒤 다시 시작 가능 |
| `TestTunnelSlotReleasedOnFailedStart` | 터널 자리를 잡은 뒤 실패한 `rd_start`(`logPath`가 폴더) 뒤에도 다음 시작이 된다 |
| `TestTunnelInvalidConfig` | `utunFd` 없음·음수·utun 아님 → `invalid_config`와 각 메시지. `mtu` 1, 1000, 1279, 1421, 1500, 9000, -1280은 나머지가 유효한 설정(메모리 TUN)에서 mtu 메시지로만 거절. 메모리 한도·GC 설정 그대로. 터널 모드는 `listenTLS`·`port`를 검사하지 않음 |
| `TestTunnelMTUBounds` | `mtu` 1280·1420·생략이 시작되고 `status.tunnel.mtu`가 1280·1420·1280 |
| `TestTunnelSetDefaultInterface` | 없는 핸들, 터널 아닌 모드, 잘못된 이름, 정상·빈 이름, 넘긴 이름이 netmon의 OS 기본 경로가 됨 |
| `TestTunnelSetDefaultInterfaceReevaluates` | 이름이 바뀌면 netmon이 바로 다시 계산해 `DefaultInterfaceChanged`와 새 `DefaultRouteInterface`를 알림(lo0으로 바꿨다가 되돌림), 빈 이름 무시 |
| `TestTunnelIOSDNS` | `dns.NewManager(goos "ios")` + 싱크: MagicDNS만, 사용자 지정 split 경로 추가, ExtraRecord 추가, tailnet 밖 ExtraRecord, `DisableSplitDNSWhenNoCustomResolvers`, override local DNS 모두 `dnsServers[0] == 100.100.100.100`, 비어 있지 않은 `dnsMatchDomains`에 tailnet 접미사·역방향 영역, 빈 일치 도메인 없음, `corp.example.com` 없음, tailnet 밖 이름의 상위 리졸버 없음 |
| `TestTunnelScopeDNS` | 기본 리졸버 설정 → tailnet 접미사 범위로, 접미사가 없으면 DNS 없음, 범위 지정 설정은 그대로 |
| `TestTunnelSettingsBuild` | 설정 변환 표: IPv4만, IPv6만, 둘 다, DNS 비어 있음, 엔진이 합친 경로 통과 |
| `TestTunnelSettingsEqual` | DNS 서버·일치 도메인만 다른 설정은 같지 않다 |
| `TestTunnelSinkFlush` | 주소 없으면 무발행, 같은 설정 무발행, DNS만 바뀌어도 발행(일치 도메인, 서버), DNS 설정 실패 시 지연 발행, 그 뒤 DNS 설정이 되면 다시 발행, 닫힌 뒤 무발행 |
| `TestTunnelSettingsEventReplaced` | 큐의 대기 중 `network-settings`를 새 것이 대신한다 |
| `TestTunnelLoginRecovers` | 로그인 시작 중 패닉이 오류로 바뀐다 |
| `TestTunnelOpenUTUNKeepsCallerFD` | utun이 아닌 소켓 거절, 실패해도 호출자의 fd는 열려 있다 |

Swift(`RDCoreBridgeTests.tunnelMTUOutOfRangeIsRejected`): `mtu` 1279·1421·1500·9000이 만들 수 있는 `stateDir`에서 `invalid_config`와 mtu 메시지로 거절된다.

### 시험 도구 `rdtestenv forward`

```
rdtestenv forward --control URL --state-dir DIR --hostname NAME [--authkey KEY] --listen 127.0.0.1:PORT --to HOST:PORT
```

가짜 tailnet에 클라이언트 노드로 들어가, `--listen`(루프백만)에서 받은 TCP 연결마다 tailnet으로 `HOST:PORT`(MagicDNS 이름이나 tailnet IP)에 이어 준다. 준비되면 `{"listen":"127.0.0.1:PORT"}` 한 줄을 출력하고(PORT 0은 빈 포트) 종료 신호까지 돈다. 호스트는 연결을 이 노드의 것으로 본다. `TestE2EForward`(`core/e2e`)는 실제 바이너리를 빌드해 실행하고, 페어링한 forwarder로 `GET /v1/info`가 200, 페어링하지 않은 forwarder로 403 `not_paired`임을 확인한다.

## 메모리와 크기

- 터널 확장 한도 보고치는 50MiB다(Apple 포럼 보고, 변동 가능). `goMemLimitMiB`(권장 28)를 적용한다. GOGC를 끄지 않는다.
- 빌드 태그는 `scripts/build-core.sh`의 목록을 그대로 쓴다. 터널 모드에 netstack과 dns가 필요하고, acme·serve·ipnbus·clientmetrics는 같은 아카이브의 tsnet이 쓰므로 뺄 수 없다. 더 줄이려면 tsnet 없는 별도 아카이브가 필요하다.
- 슬라이스 크기(`libRDCore.a`, 터널 모드 전 → 지금): ios-arm64 23,422,984 → 23,523,368바이트, macos-arm64 23,644,008 → 23,744,272바이트.
- 실제 상주 메모리는 실기기에서만 잰다(`rssMiB` 기록). macOS 테스트는 iOS의 WireGuard 큐 설정을 쓰지 않는다.

## 실기기에서만 확인할 것

1. iOS NE 샌드박스에서 utun fd 탐색과 `CreateTUNFromFile`(UTUN_OPT_IFNAME, `net.InterfaceByName`, AF_ROUTE 소켓)이 되는가. 경로 감시 소켓 오류는 장치 전체를 닫는다(→ `TUN 장치가 닫혔습니다.`).
2. 첫 `setTunnelNetworkSettings` 전에 utun과 fd가 있는가(없으면 자리표시 설정).
3. 피어별 /32 경로가 셀룰러에서 통신사 CGNAT 주소와 충돌하지 않는가.
4. 일치 도메인 66개 이상 + `matchDomainsNoSearch = true`에서 `<host>.<tailnet>.ts.net`과 PTR이 100.100.100.100으로 풀리는가.
5. 확장 자신의 제어·DERP·WireGuard 소켓이 터널을 우회하는가, `setDefaultInterface`로 인터페이스 전환을 따라가는가.
6. 확장 전체(Go + Swift + NE 프레임워크)의 phys_footprint가 유휴·트래픽 상태에서 50MiB 안인가.
7. 첫 잠금 해제 전 주문형 VPN 시작에 맞는 `stateDir`의 데이터 보호 등급·App Group 위치.
8. iOS에서 엔진이 100.100.100.100을 기본 리졸버로 삼으려는 tailnet(사용자 지정 서버로 가는 split DNS, 역방향 영역 밖 주소의 ExtraRecord, `DisableSplitDNSWhenNoCustomResolvers` 노브)에서도 범위 지정 DNS가 나가는 것은 Go 테스트(`TestTunnelIOSDNS`, goos `ios`)로 확인했다. 실기기에서는 그런 tailnet에서 호스트 FQDN이 풀리고 다른 이름(인터넷 이름, `corp.example.com`)은 기기 리졸버로 풀리는지만 본다.
9. 사용 중인 개발자 계정에서 Network Extension 권한을 쓸 수 있는가.

## 남은 위험

- Tailscale 엔진 내부 API는 안정 계약이 아니다. `tailscale.com v1.104.6`에 고정하고, 올릴 때 위 테스트를 다시 돌린다.
- 제어 서버의 디버그 메시지는 프로세스를 끝낼 수 있다(tsnet과 같은 수용 위험).
- 범위 지정 DNS는 엔진 위에 얹은 두 장치에 기댄다. 하나는 LocalBackend와 엔진 사이에서 DNS 설정을 엿보는 래퍼(`dnsTap`)이고, 다른 하나는 기기 리졸버 대신 넘기는 "상위 리졸버 없음" 표시(사용자 정의 스킴 `rd-no-upstream:`)다. 엔진을 올릴 때 `TestTunnelIOSDNS`가 둘을 함께 확인한다.
