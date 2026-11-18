import Foundation
import Synchronization
import Testing

@testable import MacHostKit

// USB 케이블 설치(docs/protocol-addenda.md R)의 Mac 쪽: 인터페이스 → iPhone, IPA 풀기 → 설치.

private struct FakeFinder: CableDeviceFinding {
    var serials: [String: String]
    func usbSerial(ofInterface name: String) -> String? { serials[name] }
}

private final class FakeTools: CableInstallTooling {
    struct State {
        var unpacked: [(ipa: URL, directory: URL)] = []
        var installed: [(app: URL, device: String)] = []
        var workExistedAtInstall = false
    }
    let state = Mutex(State())
    let unpackFails: Bool
    let failure: String?

    init(unpackFails: Bool = false, failure: String? = nil) {
        self.unpackFails = unpackFails
        self.failure = failure
    }

    func unpack(ipa: URL, into directory: URL) async -> URL? {
        state.withLock { $0.unpacked.append((ipa, directory)) }
        return unpackFails ? nil : directory.appendingPathComponent("Payload/Sample.app")
    }

    func install(app: URL, device: String) async -> String? {
        let exists = FileManager.default.fileExists(atPath: app.deletingLastPathComponent().deletingLastPathComponent().path)
        state.withLock {
            $0.installed.append((app, device))
            $0.workExistedAtInstall = exists
        }
        return failure
    }
}

@Suite("USB 케이블 설치 도구")
struct CableInstallerTests {
    private let workRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rd-cable-tests-\(UUID().uuidString)")

    @Test func usbSerialBecomesTheDeviceIdentifier() {
        #expect(CableInstaller.udid(fromUSBSerial: "00008120000000000000001E") == "00008120-000000000000001E")
        let old = String(repeating: "0a", count: 20)
        #expect(CableInstaller.udid(fromUSBSerial: old) == old)
        for bad in ["", "00008120-000000000000001E", "0000812000000000000000ZZ", "1234", "00008120000000000000001E; rm"] {
            #expect(CableInstaller.udid(fromUSBSerial: bad) == nil, "\(bad)")
        }
    }

    @Test func onlyInterfacesOfAnAttachedPhoneResolve() {
        let installer = CableInstaller(finder: FakeFinder(serials: ["anri0": "00008120000000000000001E", "en5": "not-a-phone"]), tools: FakeTools())
        #expect(installer.device(onInterface: "anri0") == "00008120-000000000000001E")
        // Wi-Fi, 일련번호가 iPhone 것이 아닌 USB 어댑터, 이름이 이상한 인터페이스.
        #expect(installer.device(onInterface: "en1") == nil)
        #expect(installer.device(onInterface: "en5") == nil)
        #expect(installer.device(onInterface: "anri0; ls") == nil)
        #expect(installer.device(onInterface: "") == nil)
    }

    @Test func realRegistryKnowsNoPhoneBehindLoopbackOrNonsense() {
        // 실제 IORegistry를 읽는다. 루프백과 없는 인터페이스는 어떤 Mac에서도 iPhone의 것이 아니다.
        let registry = USBDeviceRegistry()
        #expect(registry.usbSerial(ofInterface: "lo0") == nil)
        #expect(registry.usbSerial(ofInterface: "nosuch99") == nil)
        #expect(registry.usbSerial(ofInterface: "../x") == nil)
    }

    @Test func installUnpacksThenInstallsAndCleansUp() async {
        let tools = FakeTools()
        let installer = CableInstaller(finder: FakeFinder(serials: [:]), tools: tools, workRoot: workRoot)
        let ipa = URL(fileURLWithPath: "/published/app.ipa")
        #expect(await installer.install(ipa: ipa, device: "00008120-000000000000001E") == nil)

        let state = tools.state.withLock { $0 }
        #expect(state.unpacked.map(\.ipa) == [ipa])
        #expect(state.installed.map(\.device) == ["00008120-000000000000001E"])
        #expect(state.installed.first?.app.lastPathComponent == "Sample.app")
        #expect(state.workExistedAtInstall)
        // 푼 폴더는 남기지 않는다.
        #expect(!FileManager.default.fileExists(atPath: state.unpacked[0].directory.path))
        try? FileManager.default.removeItem(at: workRoot)
    }

    @Test func leftoverWorkFoldersAreRemovedAtStart() throws {
        let fm = FileManager.default
        let root = workRoot
        defer { try? fm.removeItem(at: root) }
        for name in ["rd-cable-AAAA/Payload/Sample.app", "rd-cable-BBBB", "other-folder"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: root.appendingPathComponent("keep.txt"))
        CableInstaller.removeLeftovers(in: root)
        #expect(Set(try fm.contentsOfDirectory(atPath: root.path)) == ["other-folder", "keep.txt"])
        CableInstaller.removeLeftovers(in: root.appendingPathComponent("nosuch"))
    }

    @Test func toolsRunWithATimeoutAndReportItAsAFailure() async {
        let seen = Mutex<[(tool: String, timeout: TimeInterval)]>([])
        let slow = CableInstallTools { executable, arguments, timeout in
            seen.withLock { $0.append((arguments.first == "devicectl" ? "devicectl" : URL(fileURLWithPath: executable).lastPathComponent, timeout)) }
            return (PhoneAppTools.timedOutCode, "")
        }
        // 멈춘 ditto: 풀지 못한 것으로 끝난다.
        #expect(await slow.unpack(ipa: URL(fileURLWithPath: "/x.ipa"), into: workRoot) == nil)
        // 멈춘 devicectl: 기한을 알리는 글로 끝난다.
        let message = await slow.install(app: URL(fileURLWithPath: "/w/Payload/Sample.app"), device: "00008120-000000000000001E")
        #expect(message?.contains("\(Int(CableInstallTools.installTimeout / 60))분 안에 끝나지 않아") == true)
        let calls = seen.withLock { $0 }
        #expect(calls.map(\.tool) == ["ditto", "devicectl"])
        #expect(calls.map(\.timeout) == [CableInstallTools.unpackTimeout, CableInstallTools.installTimeout])
        #expect(CableInstallTools.unpackTimeout + CableInstallTools.installTimeout < 1800, "로직이 세션을 끝내는 기한보다 짧다")
    }

    /// 도구가 낸 줄을 그대로 싣는 실패 이유는 iPhone으로 간다. 이 Mac의 경로와 기기 식별자를 가린다.
    @Test func unknownToolErrorsAreRedactedBeforeTheyLeaveTheMac() async {
        let output = """
        09:00:01 Acquired tunnel connection to device.
        error: Failed to install /private/var/folders/ab/T/rd-cable-0000/Payload/Sample.app on device 00008120-000000000000001E (my-mac.local) [ABCDEF01-2345-6789-ABCD-EF0123456789]
        """
        let tools = CableInstallTools { _, _, _ in (1, output) }
        let message = await tools.install(app: URL(fileURLWithPath: "/w/Payload/Sample.app"), device: "00008120-000000000000001E") ?? ""
        #expect(message.contains("iPhone에 설치에 실패했습니다") && message.contains("Failed to install"))
        for secret in ["/private/var", "rd-cable-", "Sample.app", "00008120-000000000000001E", "my-mac.local", "ABCDEF01-2345"] {
            #expect(!message.contains(secret), "\(secret)")
        }
        // 아는 원인은 정해 둔 안내 그대로다.
        let locked = CableInstallTools { _, _, _ in (1, "error: The device is locked.") }
        #expect(await locked.install(app: URL(fileURLWithPath: "/w/a.app"), device: "d") == "iPhone이 잠겨 있습니다. 잠금을 풀고 다시 설치하세요.")
        // 이 Mac 안에서만 보이는 글(iPhone 앱 설치 화면)은 그대로 둔다.
        #expect(PhoneAppInstallError.explain(output, step: "iPhone에 설치").message.contains("/private/var/folders"))
        #expect(await CableInstallTools { _, _, _ in (0, "") }.install(app: URL(fileURLWithPath: "/w/a.app"), device: "d") == nil)
    }

    @Test func failuresComeBackAsText() async {
        let broken = CableInstaller(finder: FakeFinder(serials: [:]), tools: FakeTools(unpackFails: true), workRoot: workRoot)
        #expect(await broken.install(ipa: URL(fileURLWithPath: "/x.ipa"), device: "d") == "빌드 파일(IPA)을 풀지 못했습니다. 다시 게시한 뒤 설치하세요.")
        let locked = CableInstaller(finder: FakeFinder(serials: [:]), tools: FakeTools(failure: "iPhone이 잠겨 있습니다."), workRoot: workRoot)
        #expect(await locked.install(ipa: URL(fileURLWithPath: "/x.ipa"), device: "d") == "iPhone이 잠겨 있습니다.")
        try? FileManager.default.removeItem(at: workRoot)
    }
}
