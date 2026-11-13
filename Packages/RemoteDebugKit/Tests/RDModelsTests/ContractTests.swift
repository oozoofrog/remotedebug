import Foundation
import Testing

@testable import RDModels

/// docs/tunnel.md·docs/protocol-addenda.md의 JSON 예제와 Go 코어가 실제로 보내는 모양을 모델로 읽는다.
enum DocJSON {
    static func blocks(_ file: String) throws -> [String] {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        let text = try String(contentsOf: u.appendingPathComponent("docs/\(file)"), encoding: .utf8)
        var out: [String] = []
        var current: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current == nil {
                if line == "```json" { current = [] }
            } else if line == "```" {
                out.append(current!.joined(separator: "\n"))
                current = nil
            } else {
                current!.append(line)
            }
        }
        return out
    }

    static func block(_ file: String, withKeys keys: Set<String>) throws -> String {
        for b in try blocks(file) {
            let obj = try JSONSerialization.jsonObject(with: Data(b.utf8)) as! [String: Any]
            if keys.isSubset(of: Set(obj.keys)) { return b }
        }
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(file)에 \(keys) 예제가 없습니다"])
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try RDJSON.decoder().decode(T.self, from: Data(json.utf8))
}

private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: RDJSON.encoder().encode(value)) as! [String: Any]
}

/// 원본 JSON과 다시 인코딩한 JSON이 같은지(키 집합과 값 모두).
private func expectRoundTrip<T: Codable>(_ type: T.Type, _ json: String) throws -> T {
    let value = try decode(T.self, json)
    let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSDictionary
    let again = try object(value) as NSDictionary
    #expect(original == again, "\(T.self) 재인코딩이 원본과 다릅니다")
    return value
}

@Suite struct ContractTests {
    // MARK: json-1 NextEventResponse

    @Test func nextEventResponseRejectsErrorReplies() throws {
        // Go api.NextEvent: 없는 핸들이면 즉시 오류 응답.
        let errorReply = #"{"error":{"code":"unknown_handle","message":"핸들이 없습니다."}}"#
        #expect(throws: DecodingError.self) { try decode(NextEventResponse.self, errorReply) }
        #expect(throws: DecodingError.self) { try decode(NextEventResponse.self, "{}") }
        let fallback = try decode(APIErrorBody.self, errorReply)
        #expect(fallback.error.code == "unknown_handle")
        // 시간 초과는 여전히 nil.
        #expect(try decode(NextEventResponse.self, #"{"event":null}"#).event == nil)
    }

    // MARK: json-5 BuildsResponse

    @Test func buildsResponseRequiresBuildsKey() throws {
        #expect(throws: DecodingError.self) {
            try decode(BuildsResponse.self, #"{"error":{"code":"not_paired","message":"페어링되지 않은 기기입니다."}}"#)
        }
        #expect(try decode(BuildsResponse.self, #"{"builds":[]}"#).builds.isEmpty)
        #expect(try decode(BuildsResponse.self, #"{"builds":null}"#).builds.isEmpty)
    }

    // MARK: json-6 PublishRequest

    private func sampleDescriptor() throws -> BuildDescriptor {
        let json = try DocJSON.block("protocol.md", withKeys: ["bundleId", "signing", "ipa"])
        return try decode(BuildDescriptor.self, json)
    }

    @Test func publishRequestFlattensDescriptorAndAddsIPAPath() throws {
        let d = try sampleDescriptor()
        let req = PublishRequest(build: d, ipaPath: "/Users/x/Library/Containers/y/Data/published/app.ipa")
        let obj = try object(req)
        let descriptorKeys = Set(try object(d).keys)
        #expect(Set(obj.keys) == descriptorKeys.union(["ipaPath"]))
        #expect(obj["ipaPath"] as? String == req.ipaPath)
        #expect(obj["bundleId"] as? String == d.bundleId)
        #expect((obj["signing"] as? [String: Any])?["getTaskAllow"] as? Bool == true)
        #expect(obj["publishedAt"] as? String == "2026-11-11T09:00:00Z")
        // Go host.PublishRequest와 같은 모양(임베드된 BuildDescriptor + ipaPath)을 다시 읽을 수 있다.
        let back = try RDJSON.decoder().decode(PublishRequest.self, from: RDJSON.encoder().encode(req))
        #expect(back == req)
        // 클라이언트용 BuildDescriptor 인코딩에는 ipaPath가 없다.
        #expect(try object(d)["ipaPath"] == nil)
    }

    // MARK: json-3, json-4 CoreConfig

    @Test func tunnelConfigExampleRoundTrips() throws {
        // 문서 예시는 터널 모드가 쓰지 않는 호스트 전용 키를 생략한다. Swift 모델은 항상 내보내므로 기본값을 채워 읽는다.
        let doc = try DocJSON.block("tunnel.md", withKeys: ["mode", "utunFd"])
        var merged = try JSONSerialization.jsonObject(with: Data(doc.utf8)) as! [String: Any]
        for (key, value) in ["listenTLS": true, "port": 443, "publishDir": "", "allowedTargets": [String]()] as [String: Any] where merged[key] == nil {
            merged[key] = value
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: merged), as: UTF8.self)
        let c = try expectRoundTrip(CoreConfig.self, json)
        #expect(c.mode == .tunnel && c.utunFd == 7 && c.mtu == 1280 && c.goMemLimitMiB == 28)
    }

    @Test func optionalConfigFieldsAreOmittedUnlessSet() throws {
        let plain = try object(CoreConfig(mode: .host, stateDir: "/s", hostname: "rd-mac-1"))
        for key in ["utunFd", "mtu", "hostDisplayName", "appVersion"] { #expect(plain[key] == nil, "\(key)") }
        #expect(Set(plain.keys).count == 12)

        let empty = try object(CoreConfig(mode: .host, stateDir: "/s", hostname: "rd-mac-1", hostDisplayName: "", appVersion: ""))
        #expect(empty["hostDisplayName"] == nil && empty["appVersion"] == nil)

        // docs/protocol-addenda.md A.1의 예제 값.
        let addenda = try DocJSON.block("protocol-addenda.md", withKeys: ["hostDisplayName", "appVersion"])
        let extra = try JSONSerialization.jsonObject(with: Data(addenda.utf8)) as! [String: String]
        let full = CoreConfig(mode: .host, stateDir: "/s", hostname: "rd-mac-1",
                              hostDisplayName: extra["hostDisplayName"], appVersion: extra["appVersion"])
        let obj = try object(full)
        #expect(obj["hostDisplayName"] as? String == "작업용 Mac" && obj["appVersion"] as? String == "0.1.0")
        let back = try RDJSON.decoder().decode(CoreConfig.self, from: RDJSON.encoder().encode(full))
        #expect(back == full)
    }

    // MARK: CoreStatus

    @Test func tunnelStatusExampleRoundTrips() throws {
        let json = try DocJSON.block("tunnel.md", withKeys: ["backendState", "tunnel"])
        let s = try expectRoundTrip(CoreStatus.self, json)
        let t = try #require(s.tunnel)
        #expect(t.addresses == ["100.64.0.11/32", "fd7a:115c:a1e0::b/128"])
        #expect(t.routes == ["100.64.0.10/32", "fd7a:115c:a1e0::/48", "100.100.100.100/32", "fd7a:115c:a1e0::53/128"])
        #expect(t.dnsServers == ["100.100.100.100", "fd7a:115c:a1e0::53"])
        #expect(t.dnsMatchDomains == ["example-tailnet.ts.net", "64.100.in-addr.arpa"])
        #expect(t.mtu == 1280 && t.peerCount == 1)
        #expect(s.errorMessage == nil)
    }

    @Test func errorStatusExampleRoundTrips() throws {
        let json = try DocJSON.block("protocol-addenda.md", withKeys: ["backendState", "errorMessage"])
        let s = try expectRoundTrip(CoreStatus.self, json)
        #expect(s.backendState == .error && s.errorMessage?.hasPrefix("host listener:") == true && s.tunnel == nil)
    }

    @Test func goStyleStatusWithNullsAndUnknownStateDecodes() throws {
        // Go는 nil 슬라이스를 null로 보낸다. backendState의 모르는 값도 그대로 받는다.
        let json = #"{"backendState":"InUseOtherUser","authURL":"","hostname":"h","fqdn":"","tailscaleIPs":null,"certDomains":null,"tlsReady":false,"listening":false,"publishedBuilds":0,"pairedDevices":0,"rssMiB":0,"tunnel":{"addresses":null,"routes":null,"dnsServers":null,"dnsMatchDomains":null,"mtu":1280,"peerCount":0}}"#
        let s = try decode(CoreStatus.self, json)
        #expect(s.backendState.rawValue == "InUseOtherUser")
        #expect(s.tunnel == TunnelStatus(mtu: 1280))
    }

    // MARK: 경로 (docs/protocol-addenda.md N)

    @Test func statusWithoutPeerPathStillDecodes() throws {
        // 경로를 모르는 이전 코어의 상태.
        let json = #"{"backendState":"Running","authURL":"","hostname":"h","fqdn":"h.example-tailnet.ts.net","tailscaleIPs":["100.64.0.11"],"certDomains":[],"tlsReady":false,"listening":false,"publishedBuilds":0,"pairedDevices":0,"rssMiB":1}"#
        let s = try decode(CoreStatus.self, json)
        #expect(s.peerPath == nil && s.peerPaths == nil)
        // 경로가 없으면 키도 내보내지 않는다.
        let obj = try object(s)
        #expect(obj["peerPath"] == nil && obj["peerPaths"] == nil)
    }

    @Test func statusPeerPathDecodes() throws {
        let base = #""backendState":"Running","hostname":"h","rssMiB":1"#
        let direct = try decode(CoreStatus.self, #"{\#(base),"peerPath":{"direct":true,"addr":"192.168.0.10:41641","relay":"tok"}}"#)
        #expect(direct.peerPath == PeerPath(direct: true, addr: "192.168.0.10:41641", relay: "tok"))
        let relayed = try decode(CoreStatus.self, #"{\#(base),"peerPath":{"direct":false,"relay":"tok"}}"#)
        #expect(relayed.peerPath == PeerPath(direct: false, relay: "tok"))
        let host = try decode(CoreStatus.self, #"{\#(base),"peerPaths":{"nPhone1CNTRL":{"direct":false,"relay":"tok"}}}"#)
        #expect(host.peerPaths == ["nPhone1CNTRL": PeerPath(direct: false, relay: "tok")])
        _ = try expectRoundTrip(CoreStatus.self, #"{"backendState":"Running","authURL":"","hostname":"h","fqdn":"","tailscaleIPs":[],"certDomains":[],"tlsReady":false,"listening":false,"publishedBuilds":0,"pairedDevices":1,"rssMiB":1,"peerPath":{"direct":true,"addr":"192.168.0.10:41641","relay":"tok"},"peerPaths":{"nPhone1CNTRL":{"direct":false,"relay":"tok"}}}"#)
        // 모양이 다른 경로는 버리고 나머지 상태는 읽는다.
        let odd = try decode(CoreStatus.self, #"{\#(base),"peerPath":"direct","peerPaths":[1]}"#)
        #expect(odd.backendState == .running && odd.peerPath == nil && odd.peerPaths == nil)
    }

    @Test func addendaPeerPathExampleDecodes() throws {
        let json = try DocJSON.block("protocol-addenda.md", withKeys: ["direct", "addr"])
        let path = try expectRoundTrip(PeerPath.self, json)
        #expect(path.direct && path.isLocalNetwork && path.label == "직접 연결(같은 네트워크)")
    }

    @Test func peerPathLabels() {
        #expect(PeerPath(direct: false, relay: "tok").label == "중계 서버 경유")
        #expect(PeerPath(direct: true, addr: "203.0.113.7:41641").label == "직접 연결")
        #expect(PeerPath(direct: true).label == "직접 연결")
        for local in ["10.0.0.5:41641", "172.16.4.2:1", "172.31.255.1:1", "192.168.1.20:41641", "169.254.10.1:1", "[fe80::1c2b:3aff:fe4d:5e6f]:41641", "[fd12:3456:789a::1]:41641"] {
            #expect(PeerPath.isPrivateEndpoint(local), "\(local)")
        }
        for remote in ["203.0.113.7:41641", "172.32.0.1:1", "100.64.0.10:41641", "[2001:db8::1]:41641", "", "example"] {
            #expect(!PeerPath.isPrivateEndpoint(remote), "\(remote)")
        }
    }

    // MARK: 이벤트

    @Test func networkSettingsEventExampleRoundTrips() throws {
        let json = try DocJSON.block("tunnel.md", withKeys: ["type", "addresses"])
        let e = try expectRoundTrip(CoreEvent.self, json)
        guard case .networkSettings(let n) = e else { Issue.record("network-settings가 아님: \(e)"); return }
        #expect(e.type == "network-settings")
        #expect(n.addresses.count == 2 && n.routes.first == "100.64.0.10/32" && n.mtu == 1280)
        #expect(n.dnsServers == ["100.100.100.100", "fd7a:115c:a1e0::53"])
        #expect(n.dnsMatchDomains == ["example-tailnet.ts.net", "64.100.in-addr.arpa"])
        let wrapped = try decode(NextEventResponse.self, #"{"event":\#(json)}"#)
        #expect(wrapped.event == e)
    }

    @Test func deniedSuppressedExampleRoundTrips() throws {
        let json = try DocJSON.block("protocol-addenda.md", withKeys: ["type", "suppressed"])
        let e = try expectRoundTrip(CoreEvent.self, json)
        #expect(e == .denied(DeniedEvent(path: "/v1/info", reason: "not_paired", nodeName: "rd-phone-ab12cd34", suppressed: 12)))
        // 생략이 없으면 필드도 없다.
        let plain = try object(CoreEvent.denied(DeniedEvent(path: "/v1/info", reason: "not_paired")))
        #expect(plain["suppressed"] == nil && plain["nodeName"] == nil)
    }

    @Test func addendaExamplesDecode() throws {
        for json in try DocJSON.blocks("protocol-addenda.md") {
            let keys = Set((try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]).keys)
            if keys.contains("type") {
                let e = try expectRoundTrip(CoreEvent.self, json)
                if case .unknown = e { Issue.record("알려진 type이 unknown으로 읽힘: \(json)") }
            } else if keys == ["error"] {
                _ = try expectRoundTrip(APIErrorBody.self, json)
            } else if keys.contains("backendState") {
                _ = try expectRoundTrip(CoreStatus.self, json)
            }
        }
    }
}
