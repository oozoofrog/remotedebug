import Foundation
import Synchronization
import Testing

@testable import MacHostKit

// USB 케이블 설치(docs/protocol-addenda.md Q)의 Mac 쪽: 인터페이스 → iPhone, IPA 풀기 → 설치.

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

    @Test func failuresComeBackAsText() async {
        let broken = CableInstaller(finder: FakeFinder(serials: [:]), tools: FakeTools(unpackFails: true), workRoot: workRoot)
        #expect(await broken.install(ipa: URL(fileURLWithPath: "/x.ipa"), device: "d") == "빌드 파일(IPA)을 풀지 못했습니다. 다시 게시한 뒤 설치하세요.")
        let locked = CableInstaller(finder: FakeFinder(serials: [:]), tools: FakeTools(failure: "iPhone이 잠겨 있습니다."), workRoot: workRoot)
        #expect(await locked.install(ipa: URL(fileURLWithPath: "/x.ipa"), device: "d") == "iPhone이 잠겨 있습니다.")
        try? FileManager.default.removeItem(at: workRoot)
    }
}
