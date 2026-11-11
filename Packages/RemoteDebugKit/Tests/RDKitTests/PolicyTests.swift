import Foundation
import RDModels
import Testing

@testable import RDBuildInspection

struct PolicyCase: Sendable, CustomTestStringConvertible {
    var name: String
    /// Fixtures/apps 기준 상대 경로. `copyTo`가 있으면 그 폴더 이름 아래로 복사해서 검사한다.
    var fixture: String
    var copyToFolder: String?
    var options: InspectionOptions
    var expectedCodes: [RejectionCode]
    var expectedDetails: [RejectionCode: String] = [:]
    var expectedEvidence: BuildDescriptor.ConfigurationEvidence?
    var expectedConfiguration: String?

    var testDescription: String { name }
}

private let dev = "Debug-iphoneos/AcceptedDev.app"

private let cases: [PolicyCase] = [
    PolicyCase(name: "accepted-dev(path)", fixture: dev, options: .init(), expectedCodes: [],
               expectedEvidence: .path, expectedConfiguration: "Debug"),
    PolicyCase(name: "accepted-via-debug-dylib", fixture: "loose/DebugDylib.app", options: .init(), expectedCodes: [],
               expectedEvidence: .debugDylib, expectedConfiguration: "Debug"),
    PolicyCase(name: "accepted-user-confirmed", fixture: dev, copyToFolder: "loose", options: .init(confirmedDebug: true),
               expectedCodes: [], expectedEvidence: .userConfirmed, expectedConfiguration: "Debug"),
    PolicyCase(name: "unverified-without-confirmation", fixture: dev, copyToFolder: "loose", options: .init(),
               expectedCodes: [.configurationUnverified]),
    PolicyCase(name: "release-folder", fixture: dev, copyToFolder: "Release-iphoneos", options: .init(),
               expectedCodes: [.configurationNotDebug]),
    PolicyCase(name: "release-folder-ignores-user-confirmation", fixture: dev, copyToFolder: "Release-iphoneos",
               options: .init(confirmedDebug: true), expectedCodes: [.configurationNotDebug]),
    PolicyCase(name: "release-folder-allowed-config", fixture: dev, copyToFolder: "Release-iphoneos",
               options: .init(allowedConfigurations: ["Release"]), expectedCodes: [],
               expectedEvidence: .path, expectedConfiguration: "Release"),
    PolicyCase(name: "unsigned", fixture: "Debug-iphoneos/Unsigned.app", options: .init(), expectedCodes: [.unsigned]),
    PolicyCase(name: "adhoc-without-get-task-allow", fixture: "Debug-iphoneos/AdhocNoGta.app", options: .init(),
               expectedCodes: [.getTaskAllowMissing]),
    PolicyCase(name: "get-task-allow-but-no-profile", fixture: "Debug-iphoneos/NoProfile.app", options: .init(),
               expectedCodes: [.noProvisioningProfile]),
    PolicyCase(name: "enterprise-profile", fixture: "Debug-iphoneos/Enterprise.app", options: .init(),
               expectedCodes: [.getTaskAllowMissing, .notDevelopmentProfile],
               expectedDetails: [.notDevelopmentProfile: "enterprise"]),
    PolicyCase(name: "ad-hoc-distribution-profile", fixture: "Debug-iphoneos/AdHocDist.app", options: .init(),
               expectedCodes: [.getTaskAllowMissing, .notDevelopmentProfile],
               expectedDetails: [.notDevelopmentProfile: "ad_hoc"]),
    // 규칙 5의 나머지 분류: 서명에는 get-task-allow가 있어 규칙 5만 걸린다.
    PolicyCase(name: "app-store-profile", fixture: "Debug-iphoneos/AppStoreProfile.app", options: .init(),
               expectedCodes: [.notDevelopmentProfile], expectedDetails: [.notDevelopmentProfile: "app_store"]),
    PolicyCase(name: "aps-environment-production", fixture: "Debug-iphoneos/ApsProduction.app", options: .init(),
               expectedCodes: [.notDevelopmentProfile], expectedDetails: [.notDevelopmentProfile: "aps_environment_production"]),
    PolicyCase(name: "no-provisioned-devices-with-get-task-allow", fixture: "Debug-iphoneos/NoDevicesGta.app", options: .init(),
               expectedCodes: [.notDevelopmentProfile], expectedDetails: [.notDevelopmentProfile: "no_provisioned_devices"]),
    PolicyCase(name: "expired-profile", fixture: "Debug-iphoneos/Expired.app", options: .init(), expectedCodes: [.profileExpired]),
    PolicyCase(name: "macOS-platform-app", fixture: "Debug-iphoneos/MacApp.app", options: .init(), expectedCodes: [.notIOSApp]),
    PolicyCase(name: "device-not-provisioned", fixture: dev, options: .init(targetUDID: Fixtures.otherUDID),
               expectedCodes: [.deviceNotProvisioned]),
    PolicyCase(name: "device-provisioned(case-insensitive)", fixture: dev,
               options: .init(targetUDID: Fixtures.provisionedUDID.lowercased()), expectedCodes: [],
               expectedEvidence: .path, expectedConfiguration: "Debug"),
    PolicyCase(name: "expired-by-injected-clock", fixture: dev,
               options: .init(now: Date(timeIntervalSince1970: 4_200_000_000)), expectedCodes: [.profileExpired]),
    PolicyCase(name: "multiple-reasons-collected", fixture: "Debug-iphoneos/Expired.app", copyToFolder: "Release-iphoneos",
               options: .init(targetUDID: Fixtures.otherUDID),
               expectedCodes: [.profileExpired, .configurationNotDebug, .deviceNotProvisioned]),
]

// 서명 검사는 킷 안에서 전용 직렬 큐로 모이므로(SecurityGate) 스위트를 직렬로 돌릴 필요가 없다.
// 교착 회귀는 ConcurrencyTests가 잡는다.
@Suite struct PolicyTests {
    @Test(arguments: cases)
    func matrix(_ c: PolicyCase) throws {
        let tmp = try TempDir("policy")
        var appURL = Fixtures.app(c.fixture)
        if let folder = c.copyToFolder {
            let parent = tmp.path(folder)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let dest = parent.appendingPathComponent(appURL.lastPathComponent)
            try FileManager.default.copyItem(at: appURL, to: dest)
            appURL = dest
        }
        let result = try BuildInspector.inspect(appAt: appURL, options: c.options)
        #expect(result.reasons.map(\.code) == c.expectedCodes, "\(c.name): \(result.reasons)")
        #expect(result.accepted == c.expectedCodes.isEmpty)
        #expect((result.descriptor != nil) == result.accepted)
        #expect(result.bundleId != nil)
        for (code, detail) in c.expectedDetails {
            #expect(result.reasons.first { $0.code == code }?.detail == detail)
        }
        if let d = result.descriptor {
            #expect(d.debug && d.signing.getTaskAllow)
            #expect(d.configurationEvidence == c.expectedEvidence)
            #expect(d.configuration == c.expectedConfiguration)
            #expect(d.minOS == "26.0" && d.version == "1.0" && d.buildNumber == "1")
            #expect(d.signing.teamId == "ABCDE12345")
            #expect(d.signing.provisionedDeviceCount == 2)
            #expect(d.ipa.size == 0 && d.ipa.sha256.isEmpty)
            #expect(d.id == BuildDescriptor.makeID(bundleId: d.bundleId, ipaSHA256: ""))
        }
        // 어떤 결과 JSON에도 기기 UDID는 없다.
        let json = String(decoding: try RDJSON.encoder().encode(result), as: UTF8.self)
        #expect(!json.contains("00008110-"))
    }

    @Test func reasonCodesAreSnakeCase() {
        let expected: Set<String> = ["not_ios_app", "unsigned", "invalid_signature", "get_task_allow_missing",
                                     "no_provisioning_profile", "not_development_profile", "profile_expired",
                                     "configuration_not_debug", "configuration_unverified", "device_not_provisioned",
                                     "unreadable"]
        #expect(Set(RejectionCode.allCases.map(\.rawValue)) == expected)
    }

    @Test func tamperedBundleIsInvalidNotUnsigned() throws {
        let tmp = try TempDir("tamper")
        let parent = tmp.path("Debug-iphoneos")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let app = parent.appendingPathComponent("AcceptedDev.app")
        try FileManager.default.copyItem(at: Fixtures.app(dev), to: app)
        // 봉인된 리소스(Info.plist)의 내용만 바꾼다. 형식은 유효하므로 읽을 수는 있다.
        let original = try Data(contentsOf: Fixtures.app(dev).appendingPathComponent("Info.plist"))
        var text = String(decoding: original, as: UTF8.self)
        text = text.replacingOccurrences(of: "1.0</string>", with: "9.9</string>")
        try Data(text.utf8).write(to: app.appendingPathComponent("Info.plist"))
        let result = try BuildInspector.inspect(appAt: app, options: .init())
        #expect(result.reasons.map(\.code) == [.invalidSignature])
    }

    /// 규칙 7은 심볼릭 링크가 놓인 폴더가 아니라 실제 번들이 있는 폴더로 판정한다.
    @Test func symlinkedAppIsJudgedByItsRealFolder() throws {
        let tmp = try TempDir("symlink-config")
        let release = tmp.path("Release-iphoneos")
        let desktop = tmp.path("Desktop")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let real = release.appendingPathComponent("AcceptedDev.app")
        try FileManager.default.copyItem(at: Fixtures.app(dev), to: real)
        let link = desktop.appendingPathComponent("AcceptedDev.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let viaLink = try BuildInspector.inspect(appAt: link, options: .init(confirmedDebug: true))
        #expect(viaLink.reasons.map(\.code) == [.configurationNotDebug])

        // 반대로 Release 폴더에 놓인 링크가 Debug 빌드를 가리키면 Debug로 판정한다.
        let debugLink = release.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: debugLink, withDestinationURL: Fixtures.app(dev))
        let ok = try BuildInspector.inspect(appAt: debugLink, options: .init())
        #expect(ok.accepted && ok.descriptor?.configuration == "Debug" && ok.descriptor?.configurationEvidence == .path)
    }

    /// 코어 게시가 거부하는 빈 bundleId는 검사에서도 거부한다(`unreadable`).
    @Test(arguments: [nil, "", "  "] as [String?])
    func missingOrEmptyBundleIdIsRejected(_ value: String?) throws {
        let tmp = try TempDir("bundle-id")
        let parent = tmp.path("Debug-iphoneos")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let app = parent.appendingPathComponent("AcceptedDev.app")
        try FileManager.default.copyItem(at: Fixtures.app(dev), to: app)
        let infoURL = app.appendingPathComponent("Info.plist")
        var info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["CFBundleIdentifier"] = value
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        // 바뀐 Info.plist로 get-task-allow를 넣어 다시 ad hoc 서명한다(서명 사유가 끼지 않도록).
        let ent = tmp.path("ent.plist")
        try PropertyListSerialization.data(fromPropertyList: ["get-task-allow": true], format: .xml, options: 0).write(to: ent)
        let sign = try runTool("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", ent.path, app.path])
        #expect(sign.status == 0, "\(sign.output)")

        let result = try BuildInspector.inspect(appAt: app, options: .init())
        #expect(result.reasons.map(\.code) == [.unreadable], "\(result.reasons)")
        #expect(!result.accepted && result.descriptor == nil)
        #expect(result.reasons.first?.detail.contains("CFBundleIdentifier") == true)
    }

    @Test func unreadableThrows() {
        #expect(throws: InspectionError.self) {
            try BuildInspector.inspect(appAt: URL(fileURLWithPath: "/nonexistent/x.app"), options: .init())
        }
    }

    @Test func humanReasonDetailsContainNoSensitiveValues() throws {
        for c in cases {
            let result = try BuildInspector.inspect(appAt: Fixtures.app(c.fixture), options: c.options)
            for r in result.reasons {
                #expect(!r.detail.contains("00008110"))
                #expect(!r.detail.contains("ABCDE12345"))
                #expect(!r.detail.contains("Fixture "))
            }
        }
    }
}
