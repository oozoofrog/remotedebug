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
