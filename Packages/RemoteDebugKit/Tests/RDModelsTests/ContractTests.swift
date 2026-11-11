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
        let json = try DocJSON.block("tunnel.md", withKeys: ["mode", "utunFd"])
        let c = try expectRoundTrip(CoreConfig.self, json)
        #expect(c.mode == .tunnel && c.utunFd == 7 && c.mtu == 1280 && c.goMemLimitMiB == 28 && !c.listenTLS)
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
        #expect(t.routes == ["100.64.0.0/10", "fd7a:115c:a1e0::/48"])
        #expect(t.dnsServers == ["100.100.100.100"] && t.dnsMatchDomains == ["example-tailnet.ts.net"])
        #expect(t.mtu == 1280 && t.peerCount == 2)
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

    // MARK: 이벤트

    @Test func networkSettingsEventExampleRoundTrips() throws {
        let json = try DocJSON.block("tunnel.md", withKeys: ["type", "addresses"])
        let e = try expectRoundTrip(CoreEvent.self, json)
        guard case .networkSettings(let n) = e else { Issue.record("network-settings가 아님: \(e)"); return }
        #expect(e.type == "network-settings")
        #expect(n.addresses.count == 2 && n.routes.first == "100.64.0.0/10" && n.mtu == 1280)
        #expect(n.dnsServers == ["100.100.100.100"] && n.dnsMatchDomains == ["example-tailnet.ts.net"])
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
