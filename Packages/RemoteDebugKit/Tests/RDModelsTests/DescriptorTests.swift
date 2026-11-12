import Foundation
import Testing

@testable import RDModels

@Suite struct DescriptorTests {
    private func sample() -> BuildDescriptor {
        BuildDescriptor(
            id: "b_00000000", bundleId: "com.example.app.Sample", displayName: "Sample", version: "1.4.0", buildNumber: "128",
            minOS: "26.0", debug: true, configuration: "Debug", configurationEvidence: .debugDylib,
            signing: .init(teamId: "ABCDE12345", profileName: "P", profileExpires: Date(timeIntervalSince1970: 1_800_000_000),
                           provisionedDeviceCount: 3, getTaskAllow: true),
            ipa: .init(size: 0, sha256: ""), publishedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    @Test func iconRoundTripsAsBase64AndDropsBadValues() throws {
        var d = sample()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        d.icon = png
        let json = try RDJSON.encoder().encode(d)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["icon"] as? String == png.base64EncodedString())
        #expect(try RDJSON.decoder().decode(BuildDescriptor.self, from: json).icon == png)

        // 아이콘이 없으면 키도 없다.
        let plain = try #require(JSONSerialization.jsonObject(with: RDJSON.encoder().encode(sample())) as? [String: Any])
        #expect(plain["icon"] == nil)

        // PNG가 아니거나 base64가 아니거나 너무 크면 아이콘만 버린다.
        for bad in ["\"AAAA\"", "\"not base64!\"", "\"" + Data(repeating: 0x89, count: BuildDescriptor.maxIconBytes + 1).base64EncodedString() + "\"", "12"] {
            var dict = object
            dict["icon"] = try JSONSerialization.jsonObject(with: Data(bad.utf8), options: .fragmentsAllowed)
            let decoded = try RDJSON.decoder().decode(BuildDescriptor.self, from: JSONSerialization.data(withJSONObject: dict))
            #expect(decoded.icon == nil)
            #expect(decoded.id == d.id)
        }
    }

    @Test func deviceLogEventDecodesCoreJSON() throws {
        let json = #"""
        {"type":"device-log","deviceId":"d_1","deviceName":"내 iPhone","nodeName":"rd-phone-1",
         "entries":[{"at":"2026-11-12T00:00:01.25Z","level":"warning","source":"install","message":"설치 시작"},
                    {"at":"2026-11-12T00:00:02Z","level":"loud","source":"","message":"x"}]}
        """#
        guard case .deviceLog(let event) = try RDJSON.decoder().decode(CoreEvent.self, from: Data(json.utf8)) else {
            Issue.record("not a device-log event")
            return
        }
        #expect(event.deviceName == "내 iPhone" && event.entries.count == 2)
        #expect(event.entries[0].level == .warning)
        #expect(event.entries[0].at == Date(timeIntervalSince1970: 1_794_441_601.25))
        #expect(event.entries[1].level == .info)

        let body = try RDJSON.encoder().encode(DeviceLogBatch(entries: [event.entries[0]]))
        #expect(String(decoding: body, as: UTF8.self).contains(#""at":"2026-11-12T00:00:01.250Z""#))
    }

    @Test func groupsBuildsOfSameApp() {
        func build(_ id: String, _ bundle: String, _ offset: TimeInterval) -> BuildDescriptor {
            var b = sample()
            b.id = id
            b.bundleId = bundle
            b.publishedAt = Date(timeIntervalSince1970: 1_790_000_000 + offset)
            return b
        }
        let groups = AppBuildGrouping.groups([build("a1", "app.a", 10), build("b1", "app.b", 20), build("a3", "app.a", 30), build("a2", "app.a", 15)])
        #expect(groups.map(\.bundleId) == ["app.a", "app.b"])
        #expect(groups[0].latest.id == "a3")
        #expect(groups[0].older.map(\.id) == ["a2", "a1"])
        #expect(groups[1].older.isEmpty)
        #expect(AppBuildGrouping.groups([]).isEmpty)
    }

    @Test func makeIDMatchesSpec() {
        // sha256("com.example.app.Sample\n" + 64×"0") 의 앞 8자리
        let zeros = String(repeating: "0", count: 64)
        #expect(BuildDescriptor.makeID(bundleId: "com.example.app.Sample", ipaSHA256: zeros) == "b_" + expectedPrefix(zeros))
        #expect(BuildDescriptor.makeID(bundleId: "com.example.app.Sample", ipaSHA256: "abc") == "b_" + expectedPrefix("abc"))
        #expect(BuildDescriptor.makeID(bundleId: "a", ipaSHA256: "x") != BuildDescriptor.makeID(bundleId: "a", ipaSHA256: "y"))
        #expect(BuildDescriptor.makeID(bundleId: "a", ipaSHA256: "x").count == 10)
    }

    /// `shasum -a 256`로 따로 구한 값(테스트 작성 시 고정).
    private func expectedPrefix(_ sha: String) -> String {
        sha == "abc" ? "7e8432ad" : "ef7f451f"
    }

    @Test func withIPARecomputesID() {
        let d = sample().withIPA(size: 1234, sha256: "abc")
        #expect(d.ipa.size == 1234 && d.ipa.sha256 == "abc")
        #expect(d.id == BuildDescriptor.makeID(bundleId: d.bundleId, ipaSHA256: "abc"))
    }

    @Test func roundTripAndKeys() throws {
        let d = sample().withIPA(size: 5, sha256: "ff")
        let data = try RDJSON.encoder().encode(d)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(obj.keys) == ["id", "bundleId", "displayName", "version", "buildNumber", "minOS", "debug",
                                  "configuration", "configurationEvidence", "signing", "ipa", "publishedAt"])
        #expect(obj["configurationEvidence"] as? String == "debug-dylib")
        #expect(try RDJSON.decoder().decode(BuildDescriptor.self, from: data) == d)
        #expect(obj["publishedAt"] as? String == RDTimestamp.string(d.publishedAt))
    }

    @Test func timestampFormats() throws {
        let base = Date(timeIntervalSince1970: 1_794_387_600)
        #expect(RDTimestamp.string(base) == "2026-11-11T09:00:00Z")
        #expect(RDTimestamp.parse("2026-11-11T09:00:00Z") == base)
        #expect(RDTimestamp.parse("2026-11-11T18:00:00+09:00") == base)
        let frac = try #require(RDTimestamp.parse("2026-11-11T09:00:00.5Z"))
        #expect(abs(frac.timeIntervalSince(base) - 0.5) < 0.001)
        let nano = try #require(RDTimestamp.parse("2026-11-11T09:00:00.123456789Z"))
        #expect(abs(nano.timeIntervalSince(base) - 0.123456789) < 0.001)
        #expect(RDTimestamp.parse("nope") == nil)
    }

    @Test func configRoundTrip() throws {
        let c = CoreConfig(mode: .proxy, stateDir: "/s", hostname: "rd-phone-1", allowedTargets: ["h:443"], goMemLimitMiB: 40)
        let data = try RDJSON.encoder().encode(c)
        #expect(try RDJSON.decoder().decode(CoreConfig.self, from: data) == c)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["mode"] as? String == "proxy")
        #expect(Set(obj.keys) == ["mode", "stateDir", "hostname", "authKey", "controlURL", "ephemeral", "listenTLS",
                                  "port", "publishDir", "allowedTargets", "goMemLimitMiB", "logPath"])
    }
}
