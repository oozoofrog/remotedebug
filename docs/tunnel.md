# 패킷 터널 (protocol.md §6과 architecture.md 가정 A1을 대체)

> 이 문서가 대체하는 곳: `protocol.md` §6 전체, `protocol.md` §9의 `proxy` 모드, `architecture.md`의 가정 A1과 구성도. 충돌하면 이 문서를 따른다.

터널 모드의 규칙은 이 문서에만 쓴다. `protocol.md`와 `protocol-addenda.md`의 규칙(상태 값, 오류 형식, 큐, 로그)은 터널에도 그대로 적용되고, 이 문서는 그 위에 더하는 것만 적는다.

## 변경 이유

초기 설계는 터널 확장이 로컬 HTTP CONNECT 프록시를 띄우고 `NEProxySettings`로 시스템 프록시를 지정하는 방식이었다. Apple의 TN3120은 이를 명시적으로 권장하지 않는다(판정서 `appstore-review.md`의 TN3120 인용 참조). 그래서 터널 확장은 **IP 패킷을 tailnet으로 중계하는 일반 VPN**이다.

설치기를 포함한 시스템 전체가 일반 VPN처럼 tailnet 경로로 호스트에 닿는다. "설치기가 프록시 설정을 따르는가"라는 미확인 가정(A1)이 사라진다. Tailscale 공식 iOS 앱과 같은 구조다.

## 구성

```
 터널 확장 프로세스 (RemoteDebugTunnel)
  Swift 확장: utun fd 탐색, NEPacketTunnelNetworkSettings 적용, 이벤트 루프, NWPathMonitor
  Swiftail 노드 (TailnetNode, 장치 = utun fd): 제어 서버 등록, DERP, WireGuard, 패킷 입출력,
                      MagicDNS 응답(100.100.100.100), 주소·경로·DNS 설정 산출
```

- 노드는 [Swiftail](https://github.com/oozoofrog/Swiftail)(순수 Swift tailnet 노드)이다. 확장의 `SwiftailTunnelEngine`(`Apps/iOSTunnel/SwiftailTunnelEngine.swift`)이 `TailnetNode`를 감싸 앱이 읽는 모양(`CoreStatus`, `CoreEvent`)으로 바꿔 낸다. 주소·경로·DNS 설정을 산출하는 규칙은 Swiftail 저장소의 터널 계약(`contracts/SwiftailTunnel.md`, `docs` 폴더 안)이 정하고, 아래 "이벤트 `network-settings`"는 그 결과를 확장이 읽는 규칙이다.
- 터널 확장은 둘이다(RemoteDebug 앱의 것과 업데이트 앱의 것). 같은 소스로 빌드하고, tailnet 로그인 상태를 App Group의 공용 컨테이너에 두어 같은 tailnet 기기로 뜬다(`docs/protocol-addenda.md` M). iOS가 VPN을 하나만 켜므로 둘이 동시에 돌지 않는다.
- 노드 상태는 공용 컨테이너의 `Application Support/RemoteDebug/swiftail` 폴더에 둔다(노드 개인 키가 든 신원 파일 `identity.json`과 tailnet lock 상태). 확장이 다시 시작돼도 같은 노드로 뜨므로 호스트의 페어링(StableID 기준)이 깨지지 않는다. 이 폴더는 첫 잠금 해제 뒤에 읽을 수 있는 보호 등급(`completeUntilFirstUserAuthentication`)을 쓰고 백업에서 빠진다. 같은 폴더를 다른 노드가 동시에 쓸 수 없다(`stateDirectoryInUse`).
- 이전 버전이 남긴 상태 폴더(`tailscale`, `tailscale.replaced`)는 읽지 않는다. 새 노드가 처음 `Running`이 되면 지운다. 그래서 업데이트한 뒤에는 tailnet에 다시 로그인하고 Mac과 다시 페어링해야 한다([setup.md](setup.md#이전-버전에서-업데이트한-뒤)).

## 시작 입력

확장은 앱이 VPN 구성의 `providerConfiguration`에 넣은 값(`TunnelProviderConfig`)과 시작 옵션으로 노드를 만든다.

| 값 | 출처 | 규칙 |
| --- | --- | --- |
| `hostname` | 구성 | `rd-phone-<id8>`. 앱이 처음 실행할 때 만든 기기 식별자의 앞 8자(소문자 16진수) |
| `controlURL` | 구성 | 비면 Tailscale 기본 제어 서버 |
| `authKey` | 시작 옵션(`startVPNTunnel(options:)`) | 이 시작에만 쓰고 보관하지 않는다. VPN 구성에는 넣지 않는다 |
| `resetLogin` | 시작 옵션 | 서버에서 로그아웃하고 상태 폴더를 지운 뒤 새로 로그인한다(**다른 계정으로 로그인**). 서버 로그아웃이 실패하거나 10초가 지나도 로컬 상태는 지운다 |
| utun fd | 확장이 찾음 | 필수. 노드는 이 fd를 복제해 쓰고 원래 fd는 닫지도 읽지도 않는다 |
| `mtu` | 확장 상수 1280 | 노드는 utun의 MTU를 바꾸지 않는다. 같은 값을 `NEPacketTunnelNetworkSettings.mtu`로 적용한다 |

프로세스당 터널 노드는 하나다.

## 상태

확장이 앱의 상태 질의(`sendProviderMessage`)에 돌려주는 `CoreStatus`는 필드와 `backendState` 규칙이 A.5와 같다. 터널에서는 다음이 다르다.

- `tunnel` 객체가 늘 있다. 호스트 모드에는 이 객체가 없다.
- `tlsReady`, `listening`은 `false`, `publishedBuilds`, `pairedDevices`는 `0`이다. `certDomains`는 tailnet이 준 값 그대로다.
- `NeedsLogin`이면 `authURL`을 채운다. `NeedsMachineAuth`는 tailnet 관리자가 기기를 승인해야 하는 상태다.
- 노드가 끝난 실패(인증 키 거부, 등록 거절, 노드 키 만료, 저장소 오류, 제어 연결 종료, 설정 오류, 소켓 오류, 상태 폴더 사용 중)는 `Error` + `errorMessage`다. 서버가 준 진단 문자열은 `errorMessage`에 넣지 않고, 로그에는 종류 이름만 남긴다.
- 노드가 utun을 더 읽을 수 없으면(읽기 오류) `backendState`는 `Error`, `errorMessage`는 `"TUN 장치가 닫혔습니다."`이고 `state` 이벤트가 나간다.
- `rssMiB`는 터널 상태에서 채우지 않는다(0). 확장의 메모리는 앱의 상태 질의 답에 실리는 `physFootprintMiB`로 본다("메모리" 절).

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
  "rssMiB": 0,
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

`tunnel`의 앞 다섯 필드는 마지막 `network-settings` 이벤트와 같다(아직 설정이 없으면 비어 있고 `mtu`는 0이다). `peerCount`는 netmap의 피어 수다.

앱이 확장에 페어링한 Mac의 이름을 알리면(`TunnelAppRequest`의 `peer`) 그 피어까지의 경로(직접·중계)가 선택 필드 `peerPath`로 붙는다([protocol-addenda.md](protocol-addenda.md) N.3).

## 이벤트 `network-settings`

노드가 주소·경로·DNS를 산출하거나 바꿀 때 보낸다.

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
- `routes`: 노드가 netmap에서 산출한 경로를 그대로 쓴다. 피어 경로가 먼저(IPv4가 앞), 서비스 경로(100.100.100.100/32, fd7a:115c:a1e0::53/128)가 뒤다. 확장이 `100.64.0.0/10`으로 넓히지 않는다. 통신사 CGNAT 주소(100.64.0.0/10 대역)를 터널로 끌어들이면 그 주소로 가는 일반 트래픽이 끊기기 때문이다. 제어 서버가 하나의 CGNAT 경로를 지시하거나 피어가 아주 많을 때만 노드가 `100.64.0.0/10` 하나를 낸다(Swiftail 계약 동작 S).
- 주소가 없는 패밀리의 경로와 DNS 서버는 뺀다. IPv4 주소만 있으면 IPv6 경로·DNS 서버가 없고, 반대도 같다.
- 터널은 기기의 일반 DNS를 맡지 않는다. tailnet 이름만 100.100.100.100으로 보낸다.
- `dnsServers`: MagicDNS 서비스 주소(100.100.100.100, fd7a:115c:a1e0::53). IPv4가 먼저다. 비어 있으면(노드 키 만료, MagicDNS가 꺼져 있고 tailnet 이름도 없음) DNS 설정을 하지 않는다.
- `dnsMatchDomains`: `dnsServers`가 있으면 늘 비어 있지 않다(끝의 점 없음, 소문자). tailnet 접미사와 역방향 영역(`64.100.in-addr.arpa`~`127.100.in-addr.arpa`, `0.e.1.a.c.5.1.1.a.7.d.f.ip6.arpa`), 다른 영역에 덮이지 않는 ExtraRecord 이름이 들어간다. 사용자 지정 서버로 가는 split DNS 접미사(`corp.example.com` 등)는 넣지 않으므로 그 이름은 터널로 풀리지 않는다. 검색 도메인은 보내지 않으므로 짧은 이름(`rd-mac-ab12cd34`)은 풀리지 않고 FQDN만 풀린다.
- 실제로 바뀐 경우에만 보낸다. 같은 설정이면 보내지 않는다(설정 적용 → utun 링크 변경 → 다시 적용으로 도는 고리를 막는다). 주소가 없을 때(시작 직후, `NeedsLogin`, `NeedsMachineAuth`)와 노드가 끝난 뒤에는 보내지 않는다.
- 아직 읽지 않은 설정은 가장 새 것 하나만 남는다. 놓쳐도 상태의 `tunnel`이 마지막 설정을 담고 있다.

## 기본 인터페이스

Network Extension은 터널을 만들 때 한 번만 위임 인터페이스를 정하므로, Wi-Fi ↔ 셀룰러 전환 뒤에도 노드의 제어·DERP·UDP 소켓이 옛 인터페이스에 묶일 수 있다. 확장은 `NWPathMonitor`가 만족된 경로를 알릴 때마다(시작 직후 한 번 포함) 그 경로의 첫 인터페이스를 `TailnetNode.setDefaultInterface(_:)`로 넘긴다. 노드는 소켓을 그 인터페이스에 묶고, 바뀌었으면 다시 묶는다. 같은 인터페이스를 다시 알려도 노드가 거른다. 만족된 경로가 없으면 넘기지 않는다.

## 터널 확장(Swift)의 책임

1. `startTunnel`
   - 프로세스의 fd를 훑어 utun 제어 소켓(`com.apple.net.utun_control`)을 찾는다. 첫 `setTunnelNetworkSettings` 전에 utun과 fd가 있는지는 실기기에서 확인한다. 없으면 자리표시 설정(터널 원격 주소와 `mtu`만, 경로 없음)을 먼저 적용한 뒤 찾는다.
   - 노드(`SwiftailTunnelEngine`)를 만들고 이벤트 루프를 시작한다. 노드의 시작과 종료는 같은 직렬 큐에서만 부른다.
   - `NWPathMonitor`를 시작한다("기본 인터페이스").
2. `network-settings`를 받으면 `NEPacketTunnelNetworkSettings`로 바꿔 적용한다.
   - `tunnelRemoteAddress`는 필수다. `"127.0.0.1"`을 쓴다. NE는 이 주소를 VPN 서버로 보고 터널 밖 경로를 따로 둘 수 있으므로, 터널로 보내야 하는 100.100.100.100 같은 주소를 쓰면 MagicDNS 질의가 터널을 벗어날 수 있다.
   - `addresses`의 IPv4 CIDR → `NEIPv4Settings(addresses:subnetMasks:)`(접두 길이를 점 표기 마스크로), IPv6 CIDR → `NEIPv6Settings(addresses:networkPrefixLengths:)`. 패밀리에 주소가 없으면 그 설정을 만들지 않는다.
   - `routes` → 패밀리별 `includedRoutes`(`NEIPv4Route(destinationAddress:subnetMask:)`, `NEIPv6Route(destinationAddress:networkPrefixLength:)`).
   - `dnsServers`가 비어 있으면 `dnsSettings = nil`. 아니면 `NEDNSSettings(servers: dnsServers)`, `matchDomains = dnsMatchDomains`(늘 비어 있지 않은 목록), `matchDomainsNoSearch = true`. `matchDomains = [""]`(모든 질의)는 쓰지 않는다. 만약 `dnsMatchDomains`가 비어 오면 DNS를 설정하지 않는다(`dnsSettings = nil`).
   - `mtu` → `mtu`. 프록시 설정은 쓰지 않는다.
   - `setTunnelNetworkSettings`는 한 번에 하나만 진행한다. 진행 중에 온 설정은 최신 것 하나만 보관했다가 완료 콜백에서 적용한다.
3. `packetFlow.readPackets`·`writePackets`를 부르지 않는다. 패킷은 노드가 utun fd로 직접 읽고 쓴다.
4. `state` 이벤트
   - `NeedsLogin`과 `authURL`은 앱이 `sendProviderMessage`로 물을 때 돌려준다.
   - `backendState == "Error"`이고 `errorMessage`가 `"TUN 장치가 닫혔습니다."`이면 `cancelTunnelWithError`로 터널을 끝낸다. iOS는 이렇게 끝난 터널을 주문형(On Demand) 규칙이 있을 때만 스스로 다시 연결한다. 그래서 컨테이너 앱이 `NEVPNStatusDidChange`로 VPN 상태를 지켜보다가 이 오류로 `disconnected`가 되면 `startVPNTunnel`로 다시 연결한다. 앱은 추가로 `isOnDemandEnabled`와 `NEOnDemandRuleConnect`를 설정할 수 있다(첫 잠금 해제 전 시작은 실기기 확인 항목 7).
5. `stopTunnel`: 노드 종료는 몇 초 걸릴 수 있으므로 메인 스레드가 아닌 직렬 큐에서 부른다. 시작 중에 온 종료 요청은 방금 만든 노드를 멈추고 시작을 실패시킨다. 끝나면 `completionHandler`를 부른다.

## 시험

`Apps/iOSTests`가 확장의 순수 로직(설정 변환 `SettingsTranslator`, 시작·종료 순서 `TunnelLifecycle`, 오류와 저장소 `TunnelStorage`, 메시지, 메모리 기록 `TunnelMemoryLog`)을 단위로 시험한다. 노드 쪽(설정 산출, MagicDNS 응답, 상태 기계, 재시작)의 시험은 Swiftail 저장소에 있다. utun과 NE를 거치는 동작은 아래 "실기기에서만 확인할 것"으로만 확인한다.

## 메모리

- 터널 확장 한도 보고치는 50MiB다(Apple 포럼 보고, 변동 가능, Apple 문서로 확인한 값이 아니다).
- 확장은 30초마다 `phys_footprint`를 재고 5분마다 한 줄을 확장 기록에 쌓는다. 앱이 앞에 있으면 상태 질의 답의 `physFootprintMiB`로 읽고, 설정 > "VPN 진단"에 나온다.
- 이 문서에는 Swiftail 노드로 잰 상주 메모리 값을 적지 않았다. 값은 실기기에서만 잰다([device-test.md](device-test.md) D3).

## 실기기에서만 확인할 것

1. iOS NE 샌드박스에서 utun fd 탐색과 노드의 utun 읽기·쓰기가 되는가. utun을 더 읽을 수 없으면 노드가 끝난다(→ `TUN 장치가 닫혔습니다.`).
2. 첫 `setTunnelNetworkSettings` 전에 utun과 fd가 있는가(없으면 자리표시 설정).
3. 피어별 /32 경로가 셀룰러에서 통신사 CGNAT 주소와 충돌하지 않는가.
4. 일치 도메인 66개 이상 + `matchDomainsNoSearch = true`에서 `<host>.<tailnet>.ts.net`과 PTR이 100.100.100.100으로 풀리는가.
5. 확장 자신의 제어·DERP·WireGuard 소켓이 터널을 우회하는가, `setDefaultInterface`로 인터페이스 전환을 따라가는가.
6. 확장 전체(Swiftail + Swift + NE 프레임워크)의 phys_footprint가 유휴·트래픽 상태에서 50MiB 안인가.
7. 첫 잠금 해제 전 주문형 VPN 시작에 맞는 `stateDir`의 데이터 보호 등급·App Group 위치.
8. 기본 리졸버를 쓰려는 tailnet(사용자 지정 서버로 가는 split DNS, 역방향 영역 밖 주소의 ExtraRecord)에서도 호스트 FQDN이 풀리고 다른 이름(인터넷 이름, `corp.example.com`)은 기기 리졸버로 풀리는가.
9. 사용 중인 개발자 계정에서 Network Extension 권한을 쓸 수 있는가.

## 남은 위험

- Swiftail은 Tailscale 제어 서버 프로토콜을 직접 구현한 것이다. 호환성은 Swiftail의 시험과 위 실기기 항목으로 확인하고, Swiftail을 올릴 때 다시 확인한다.
- Swiftail 의존성은 저장소의 고정된 리비전을 쓴다. 로컬 체크아웃으로 바꾸는 방법은 [README](../README.md#working-on-this-repository)에 있다.
