import Foundation
import Testing

@testable import RDModels

/// docs/protocol.md의 모든 ```json 예제를 읽어 모델로 디코딩하고, 다시 인코딩한 JSON이 원본과 같은지 확인한다.
enum ProtocolDoc {
    static var url: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("docs/protocol.md")
    }

    static func jsonBlocks() throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var blocks: [String] = []
        var current: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current == nil {
                if line == "```json" { current = [] }
            } else if line == "```" {
                blocks.append(current!.joined(separator: "\n"))
                current = nil
            } else {
                current!.append(line)
            }
        }
        return blocks
    }
}

private func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ json: String) throws -> T {
    let data = Data(json.utf8)
    let value = try RDJSON.decoder().decode(T.self, from: data)
    let encoded = try RDJSON.encoder().encode(value)
    let original = try JSONSerialization.jsonObject(with: data) as! NSDictionary
    let again = try JSONSerialization.jsonObject(with: encoded) as! NSDictionary
    #expect(original == again, "\(T.self) 재인코딩이 원본과 다릅니다")
    let decodedAgain = try RDJSON.decoder().decode(T.self, from: encoded)
    #expect(decodedAgain == value)
    return value
}

@Suite struct ProtocolExamplesTests {
    @Test func everyJSONExampleDecodes() throws {
        let blocks = try ProtocolDoc.jsonBlocks()
        #expect(blocks.count >= 13)
        var seen: [String: Int] = [:]
        for json in blocks {
            let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            let keys = Set(obj.keys)
            let kind: String
            if keys.contains("type") {
                let event = try RDJSON.decoder().decode(CoreEvent.self, from: Data(json.utf8))
                guard case .pairRequest(let e) = event else { Issue.record("pair-request가 아님"); continue }
                #expect(e.requestId == "pr_7c1e55d0")
                _ = try roundTripEvent(json)
                kind = "event"
            } else if keys.contains("bundleId") && keys.contains("signing") {
                let d = try roundTrip(BuildDescriptor.self, json)
                #expect(d.id == "b_9f3a1c2e")
                #expect(d.configurationEvidence == .path)
                #expect(d.signing.provisionedDeviceCount == 27)
                #expect(d.ipa.size == 52_428_800)
                #expect(d.publishedAt == Date(timeIntervalSince1970: 1_794_387_600))
                kind = "BuildDescriptor"
            } else if keys.contains("hostId") && keys.contains("buildCount") {
                let i = try roundTrip(InfoResponse.self, json)
                #expect(i.protocolVersion == 1)
                kind = "InfoResponse"
            } else if keys == ["builds"] {
                _ = try roundTrip(BuildsResponse.self, json)
                kind = "BuildsResponse"
            } else if keys.contains("deviceName") && keys.contains("code") {
                _ = try roundTrip(PairRequestBody.self, json)
                kind = "PairRequestBody"
            } else if keys.contains("requestId") && keys.contains("state") {
                let s = try roundTrip(PairRequestState.self, json)
                #expect(s.state == .pending ? s.expiresAt != nil : s.host != nil)
                kind = "PairRequestState"
            } else if keys.contains("manifestUrl") {
                let s = try roundTrip(SessionResponse.self, json)
                #expect(s.installUrl.scheme == "itms-services")
                kind = "SessionResponse"
            } else if keys.contains("sessionId") && keys.contains("buildId") {
                let s = try roundTrip(SessionStatus.self, json)
                #expect(s.state == .downloading)
                kind = "SessionStatus"
            } else if keys == ["error"] {
                let e = try roundTrip(APIErrorBody.self, json)
                #expect(e.error.code == "not_paired")
                kind = "APIErrorBody"
            } else if keys.contains("nodeStableId") {
                _ = try roundTrip(DeviceEntry.self, json)
                kind = "DeviceEntry"
            } else if keys.contains("mode") && keys.contains("stateDir") {
                let c = try roundTrip(CoreConfig.self, json)
                #expect(c.mode == .host && c.port == 443 && c.listenTLS)
                kind = "CoreConfig"
            } else if keys.contains("backendState") {
                let s = try roundTrip(CoreStatus.self, json)
                #expect(s.backendState == .running && s.rssMiB == 31.5)
                kind = "CoreStatus"
            } else {
                Issue.record("분류되지 않은 JSON 예제: \(keys.sorted())")
                continue
            }
            seen[kind, default: 0] += 1
        }
        for required in ["BuildDescriptor", "InfoResponse", "BuildsResponse", "PairRequestBody", "PairRequestState",
                         "SessionResponse", "SessionStatus", "APIErrorBody", "DeviceEntry", "CoreConfig", "CoreStatus", "event"] {
            #expect((seen[required] ?? 0) >= 1, "\(required) 예제가 없습니다")
        }
        #expect((seen["PairRequestState"] ?? 0) == 2)  // 202 응답 + approved 응답
    }

    private func roundTripEvent(_ json: String) throws -> CoreEvent {
        let data = Data(json.utf8)
        let event = try RDJSON.decoder().decode(CoreEvent.self, from: data)
        let encoded = try RDJSON.encoder().encode(event)
        let original = try JSONSerialization.jsonObject(with: data) as! NSDictionary
        let again = try JSONSerialization.jsonObject(with: encoded) as! NSDictionary
        #expect(original == again)
        return event
    }

    @Test func allEventTypesRoundTrip() throws {
        let events: [String] = [
            #"{"type":"state","status":{"backendState":"NeedsLogin","authURL":"https://login.example/a","hostname":"rd-mac-1","fqdn":"","tailscaleIPs":[],"certDomains":[],"tlsReady":false,"listening":false,"publishedBuilds":0,"pairedDevices":0,"rssMiB":1.5}}"#,
            #"{"type":"pair-decided","requestId":"pr_1","state":"approved"}"#,
            #"{"type":"device-added","device":{"id":"d_1","name":"n","nodeStableId":"s","nodeName":"rd-phone-1","loginName":"u@example.com","pairedAt":"2026-11-11T09:05:00Z"}}"#,
            #"{"type":"denied","path":"/v1/builds","reason":"not_paired","nodeName":"rd-phone-2"}"#,
            #"{"type":"denied","path":"/v1/info","reason":"not_paired"}"#,
            #"{"type":"session","sessionId":"s_1","buildId":"b_1","nodeName":"rd-phone-1","state":"manifest_served","userAgent":"itunesstored/1","bytesServed":0}"#,
            #"{"type":"log","level":"info","message":"hello"}"#,
        ]
        for json in events {
            let e = try roundTripEvent(json)
            if case .unknown = e { Issue.record("알려진 type이 unknown으로 읽힘: \(json)") }
        }
    }

    @Test func unknownEventTypeDecodesAsUnknown() throws {
        let e = try RDJSON.decoder().decode(CoreEvent.self, from: Data(#"{"type":"future-thing","x":1}"#.utf8))
        #expect(e == .unknown(type: "future-thing"))
        #expect(e.type == "future-thing")
    }

    @Test func nextEventResponseHandlesNull() throws {
        let none = try RDJSON.decoder().decode(NextEventResponse.self, from: Data(#"{"event":null}"#.utf8))
        #expect(none.event == nil)
        let some = try RDJSON.decoder().decode(NextEventResponse.self, from: Data(#"{"event":{"type":"log","level":"info","message":"m"}}"#.utf8))
        #expect(some.event == .log(LogEvent(level: "info", message: "m")))
        let encoded = try RDJSON.encoder().encode(none)
        #expect(String(decoding: encoded, as: UTF8.self) == #"{"event":null}"#)
    }

    @Test func coreStatusToleratesNullArrays() throws {
        let s = try RDJSON.decoder().decode(CoreStatus.self, from: Data(#"{"backendState":"Starting","tailscaleIPs":null,"certDomains":null}"#.utf8))
        #expect(s.backendState == .starting && s.tailscaleIPs.isEmpty && s.certDomains.isEmpty)
        let b = try RDJSON.decoder().decode(BuildsResponse.self, from: Data(#"{"builds":null}"#.utf8))
        #expect(b.builds.isEmpty)
    }

    @Test func sessionStatesUseSnakeCase() throws {
        #expect(SessionState.manifestServed.rawValue == "manifest_served")
        for s in ["created", "manifest_served", "downloading", "completed", "expired", "failed"] {
            #expect(SessionState(rawValue: s) != nil)
        }
    }
}
