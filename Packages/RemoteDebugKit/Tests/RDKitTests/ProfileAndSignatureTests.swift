import Foundation
import Testing

@testable import RDBuildInspection

@Suite struct ProfileAndSignatureTests {
    private func plist(devices: [String]?, all: Bool = false, gta: Bool?, aps: String? = nil) -> Data {
        var ents: [String: Any] = ["application-identifier": "T.x"]
        if let gta { ents["get-task-allow"] = gta }
        if let aps { ents["aps-environment"] = aps }
        var root: [String: Any] = [
            "Name": "N", "ExpirationDate": Date(timeIntervalSince1970: 4_000_000_000),
            "TeamIdentifier": ["T"], "Entitlements": ents,
        ]
        if let devices { root["ProvisionedDevices"] = devices }
        if all { root["ProvisionsAllDevices"] = true }
        return try! PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    @Test func classification() throws {
        #expect(try ProvisioningProfile(plistData: plist(devices: nil, all: true, gta: false)).kind == .enterprise)
        #expect(try ProvisioningProfile(plistData: plist(devices: ["u"], gta: true)).kind == .development)
        #expect(try ProvisioningProfile(plistData: plist(devices: ["u"], gta: false)).kind == .adHoc)
        #expect(try ProvisioningProfile(plistData: plist(devices: ["u"], gta: nil)).kind == .adHoc)
        #expect(try ProvisioningProfile(plistData: plist(devices: nil, gta: nil)).kind == .appStore)
        #expect(try ProvisioningProfile(plistData: plist(devices: nil, gta: false)).kind == .appStore)
        #expect(try ProvisioningProfile(plistData: plist(devices: nil, gta: true)).kind == .unknown)
        // 기기 목록이 있어도 enterprise 플래그가 우선한다.
        #expect(try ProvisioningProfile(plistData: plist(devices: ["u"], all: true, gta: true)).kind == .enterprise)
    }

    @Test func fieldsAreExtracted() throws {
        let p = try ProvisioningProfile(plistData: plist(devices: ["a", "b"], gta: true, aps: "development"))
        #expect(p.name == "N" && p.teamIdentifier == "T" && p.provisionedDevices == ["a", "b"])
        #expect(p.getTaskAllow == true && p.apsEnvironment == "development" && p.betaReportsActive == nil)
        #expect(p.provisionsAllDevices == false)
    }

    @Test func decodesCMSFixtureWithoutVerifyingChain() throws {
        let url = Fixtures.app("Debug-iphoneos/AcceptedDev.app/embedded.mobileprovision")
        let p = try ProvisioningProfile(contentsOf: url)
        #expect(p.kind == .development && p.provisionedDevices?.count == 2 && p.getTaskAllow == true)
        #expect(p.expirationDate > Date())
        let enterprise = try ProvisioningProfile(contentsOf: Fixtures.app("Debug-iphoneos/Enterprise.app/embedded.mobileprovision"))
        #expect(enterprise.kind == .enterprise && enterprise.provisionsAllDevices)
    }

    @Test func garbageIsRejected() {
        #expect(throws: ProvisioningProfile.ParseError.self) { try ProvisioningProfile(cmsData: Data("not cms".utf8)) }
        #expect(throws: ProvisioningProfile.ParseError.self) { try ProvisioningProfile(plistData: Data("nope".utf8)) }
    }

    @Test func signatureStates() throws {
        let ok = try CodeSignatureInspector.inspect(bundleAt: Fixtures.app("Debug-iphoneos/AcceptedDev.app"))
        #expect(ok.status == .valid)
        #expect(ok.getTaskAllow == true)
        #expect(ok.identifier != nil)
        #expect(ok.entitlements["application-identifier"]?.stringValue?.hasPrefix("ABCDE12345.") == true)
        let nogta = try CodeSignatureInspector.inspect(bundleAt: Fixtures.app("Debug-iphoneos/AdhocNoGta.app"))
        #expect(nogta.status == .valid && nogta.getTaskAllow == nil)
        let unsigned = try CodeSignatureInspector.inspect(bundleAt: Fixtures.app("Debug-iphoneos/Unsigned.app"))
        #expect(unsigned.status == .unsigned && unsigned.entitlements.isEmpty && !unsigned.isSigned)
    }
}
