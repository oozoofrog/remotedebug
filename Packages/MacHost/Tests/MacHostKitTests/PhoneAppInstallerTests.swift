import Foundation
import Synchronization
import Testing
@testable import MacHostKit

@MainActor
@Suite struct PhoneAppInstallerTests {
    final class FakeTools: PhoneAppTooling {
        let calls = Mutex<[String]>([])
        let buildError = Mutex<PhoneAppInstallError?>(nil)

        func teams() -> [SigningTeam] { [SigningTeam(id: "ABCDE12345", name: "Team A"), SigningTeam(id: "ZZZZZ99999", name: "Team Z")] }
        func phones() async -> [ConnectedPhone] {
            [ConnectedPhone(id: "u-away", name: "서랍 속 iPhone", osVersion: "27.0", reachable: false),
             ConnectedPhone(id: "u-1", name: "내 iPhone", osVersion: "27.2", reachable: true)]
        }
        func build(source: URL, team: String, bundlePrefix: String, device: String, log: URL) async throws(PhoneAppInstallError) -> URL {
            calls.withLock { $0.append("build \(team) \(bundlePrefix) \(device)") }
            if let error = buildError.withLock({ $0 }) { throw error }
            return source.appendingPathComponent("Build/RemoteDebug.app")
        }
        func install(app: URL, device: String, log: URL) async throws(PhoneAppInstallError) {
            calls.withLock { $0.append("install \(app.lastPathComponent) \(device)") }
        }
        func launch(bundleID: String, device: String, log: URL) async {
            calls.withLock { $0.append("launch \(bundleID)") }
        }
    }

    private func makeSource(_ tmp: TempDir, team: String?, prefix: String? = nil) throws -> URL {
        let source = tmp.path("repo")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("RemoteDebug.xcodeproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Config"), withIntermediateDirectories: true)
        try Data("// 기본값\nRD_BUNDLE_PREFIX = com.oozoofrog.app\n#include? \"Signing.local.xcconfig\"\n".utf8)
            .write(to: source.appendingPathComponent("Config/Signing.xcconfig"))
        var local = ""
        if let team { local += "DEVELOPMENT_TEAM = \(team)\n" }
        if let prefix { local += "RD_BUNDLE_PREFIX = \(prefix)\n" }
        if !local.isEmpty { try Data(local.utf8).write(to: source.appendingPathComponent("Config/Signing.local.xcconfig")) }
        return source
    }

    @Test func repoTeamKeepsRepoPrefixOtherTeamsGetTheirOwn() async throws {
        let tmp = try TempDir("phone-app")
        let tools = FakeTools()
        let source = try makeSource(tmp, team: "ZZZZZ99999")
        let installer = PhoneAppInstaller(root: tmp.path("state"), sourceRoot: source, tools: tools)
        #expect(installer.hasSource)
        #expect(installer.team == "ZZZZZ99999" && installer.bundlePrefix == "com.oozoofrog.app")

        await installer.refresh()
        #expect(installer.phoneID == "u-1")
        installer.team = "ABCDE12345"
        #expect(installer.bundlePrefix == "dev.abcde12345")
        #expect(installer.phoneBundleID == "dev.abcde12345.RemoteDebugPhone")

        await installer.install()
        #expect(installer.phase == .done(phone: "내 iPhone", bundleID: "dev.abcde12345.RemoteDebugPhone"))
        #expect(tools.calls.withLock { $0 } == ["build ABCDE12345 dev.abcde12345 u-1", "install RemoteDebug.app u-1", "launch dev.abcde12345.RemoteDebugPhone"])

        // 고른 값은 다음 실행에 남는다.
        let reopened = PhoneAppInstaller(root: tmp.path("state"), sourceRoot: source, tools: tools)
        #expect(reopened.team == "ABCDE12345" && reopened.bundlePrefix == "dev.abcde12345" && reopened.phoneID == "u-1")
    }

    @Test func failureShowsCauseAndNothingIsInstalled() async throws {
        let tmp = try TempDir("phone-app-fail")
        let tools = FakeTools()
        tools.buildError.withLock { $0 = PhoneAppInstallError("서명 실패") }
        let installer = PhoneAppInstaller(root: tmp.path("state"), sourceRoot: try makeSource(tmp, team: nil), tools: tools)
        await installer.refresh()
        #expect(installer.team == "ABCDE12345")
        await installer.install()
        #expect(installer.phase == .failed("서명 실패"))
        #expect(!tools.calls.withLock { $0 }.contains { $0.hasPrefix("install") })
    }

    @Test func cannotInstallWithoutSourceOrReachablePhoneOrValidPrefix() async throws {
        let tmp = try TempDir("phone-app-guard")
        let installer = PhoneAppInstaller(root: tmp.path("state"), sourceRoot: tmp.path("nowhere"), tools: FakeTools())
        await installer.refresh()
        #expect(!installer.hasSource && !installer.canInstall)
        installer.chooseSource(try makeSource(tmp, team: nil))
        #expect(installer.canInstall)
        installer.editPrefix("bad prefix")
        #expect(!installer.canInstall)
        installer.editPrefix("dev.me")
        installer.phoneID = "u-away"
        #expect(!installer.canInstall)
        #expect(PhoneAppInstaller.isValidPrefix("com.example-1.app") && !PhoneAppInstaller.isValidPrefix("single") && !PhoneAppInstaller.isValidPrefix("a..b"))
    }

    @Test func parsesDevicectlAndBuildSettings() throws {
        let devices = #"""
        {"result":{"devices":[
          {"hardwareProperties":{"platform":"iOS","reality":"physical","deviceType":"iPhone","udid":"u-1"},
           "deviceProperties":{"name":"내 iPhone","osVersionNumber":"27.2"},"connectionProperties":{"tunnelState":"connected"}},
          {"hardwareProperties":{"platform":"iOS","reality":"physical","deviceType":"iPhone","udid":"u-2"},
           "deviceProperties":{"name":"다른 iPhone","osVersionNumber":"18.7"},"connectionProperties":{"tunnelState":"unavailable"}},
          {"hardwareProperties":{"platform":"iOS","reality":"physical","deviceType":"iPad","udid":"p-1"},"deviceProperties":{"name":"내 iPad"},"connectionProperties":{"tunnelState":"connected"}},
          {"hardwareProperties":{"platform":"iOS","reality":"simulated","deviceType":"iPhone","udid":"s-1"},"deviceProperties":{"name":"sim"},"connectionProperties":{"tunnelState":"connected"}}
        ]}}
        """#
        let phones = PhoneAppTools.parsePhones(Data(devices.utf8))
        #expect(phones.map(\.id) == ["u-1", "u-2"])
        #expect(phones.map(\.reachable) == [true, false])

        let settings = #"""
        Command line invocation: ...
        [{"target":"RemoteDebugTunnel","buildSettings":{"TARGET_BUILD_DIR":"/b/Debug-iphoneos","WRAPPER_NAME":"RemoteDebugTunnel.appex"}},
         {"target":"RemoteDebugPhone","buildSettings":{"TARGET_BUILD_DIR":"/b/Debug-iphoneos","WRAPPER_NAME":"RemoteDebug.app"}}]
        """#
        #expect(PhoneAppTools.productPath(settingsJSON: settings)?.path == "/b/Debug-iphoneos/RemoteDebug.app")
        #expect(PhoneAppTools.buildArguments(source: URL(fileURLWithPath: "/r"), team: "T", bundlePrefix: "dev.t", device: "u-1")
            .contains("-allowProvisioningDeviceRegistration"))
    }

    @Test func explainsCommonFailures() {
        #expect(PhoneAppInstallError.explain("error: No Accounts: Add a new account in Accounts settings.", step: "빌드").message.contains("Accounts"))
        #expect(PhoneAppInstallError.explain("error: Personal development teams, including \"x\", do not support the Network Extensions capability.", step: "빌드").message.contains("유료"))
        #expect(PhoneAppInstallError.explain("Failed Registering Bundle Identifier: The app identifier \"com.oozoofrog.app.RemoteDebugPhone\" cannot be registered to your development team because it is not available.", step: "빌드").message.contains("번들 ID"))
        #expect(PhoneAppInstallError.explain("ERROR: Developer Mode disabled", step: "설치").message.contains("개발자 모드"))
        #expect(PhoneAppInstallError.explain("line\nerror: something odd\n", step: "빌드").message == "빌드에 실패했습니다. error: something odd")
    }
}
