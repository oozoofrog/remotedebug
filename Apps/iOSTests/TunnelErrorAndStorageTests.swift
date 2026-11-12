import Foundation
import NetworkExtension
import RDModels
import Testing
@testable import RemoteDebug

@Suite("확장 오류 → 앱 안내")
struct TunnelProviderErrorTests {
    @Test("경계를 넘기는 오류는 고정 도메인·코드의 NSError이고 한국어 설명을 담는다", arguments: TunnelProviderError.allCases)
    func nsErrorShape(code: TunnelProviderError) {
        let error = code.nsError()
        #expect(error.domain == "com.oozoofrog.app.RemoteDebugPhone.Tunnel")
        #expect(error.code == code.rawValue)
        #expect(error.userInfo[NSLocalizedDescriptionKey] as? String == code.message)
        #expect(error.localizedDescription == code.message)
    }

    @Test("코드 값은 바뀌지 않는다")
    func stableCodes() {
        #expect(TunnelProviderError.allCases.map(\.rawValue) == [1, 2, 3, 4, 5, 6])
    }

    @Test("NSError는 직렬화(프로세스 경계)를 거쳐도 설명이 남는다")
    func survivesArchiving() throws {
        let original = TunnelProviderError.engineStopped.nsError()
        let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
        let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data))
        #expect(TunnelProviderError.userMessage(for: decoded) == TunnelEngineMessages.tunDeviceClosed + " 앱에서 VPN을 다시 켜세요.")
    }

    @Test("코어 시작 실패는 코어 메시지를 덧붙이고 인증 키를 가린다")
    func coreStartDetail() {
        let error = TunnelProviderError.coreStart.nsError(detail: "invalid key tskey-auth-k123-SECRET")
        #expect(error.localizedDescription == "tailnet 연결을 시작하지 못했습니다: invalid key [인증 키 가림]")
        #expect(TunnelProviderError.coreStart.nsError(detail: "  ").localizedDescription == TunnelProviderError.coreStart.message)
    }

    @Test("NE가 감싼 오류에서도 확장 오류를 찾는다")
    func wrappedError() {
        let wrapped = NSError(domain: NEVPNConnectionErrorDomain, code: 6, userInfo: [NSUnderlyingErrorKey: TunnelProviderError.utunNotFound.nsError()])
        #expect(TunnelProviderError.userMessage(for: wrapped) == TunnelProviderError.utunNotFound.message)
    }

    @Test("NE가 시작 중 종료 오류를 감싸 돌려줘도 꺼짐으로 본다")
    func wrappedStoppedDuringStartIsOff() {
        let wrapped = NSError(domain: NEVPNConnectionErrorDomain, code: 6, userInfo: [NSUnderlyingErrorKey: TunnelProviderError.stoppedDuringStart.nsError()])
        #expect(TunnelProviderError.kind(of: wrapped) == .stoppedDuringStart)
        #expect(TunnelStateMapping.disconnectMessage(for: wrapped) == nil)
        // 다른 확장 오류를 감싼 경우는 그 오류의 안내를 쓴다.
        let other = NSError(domain: NEVPNConnectionErrorDomain, code: 6, userInfo: [NSUnderlyingErrorKey: TunnelProviderError.engineStopped.nsError()])
        #expect(TunnelProviderError.kind(of: other) == .engineStopped)
        #expect(TunnelStateMapping.disconnectMessage(for: other) == TunnelProviderError.engineStopped.message)
        // 이 확장의 오류가 아니면 종류가 없다.
        #expect(TunnelProviderError.kind(of: NSError(domain: NEVPNConnectionErrorDomain, code: 3)) == nil)
    }

    @Test("설명이 비어 있으면 코드의 기본 안내")
    func emptyDescriptionFallsBack() {
        let bare = NSError(domain: TunnelProviderError.domain, code: TunnelProviderError.placeholderFailed.rawValue)
        #expect(TunnelProviderError.userMessage(for: bare) == TunnelProviderError.placeholderFailed.message)
        let unknown = NSError(domain: TunnelProviderError.domain, code: 99)
        #expect(TunnelProviderError.userMessage(for: unknown) == nil)
    }

    @Test("끊김 안내: 오류 없음·시작 중 끔은 꺼짐, 확장 오류는 그 설명, 그 밖은 기본 안내")
    func disconnectMessage() {
        #expect(TunnelStateMapping.disconnectMessage(for: nil) == nil)
        #expect(TunnelStateMapping.disconnectMessage(for: TunnelProviderError.stoppedDuringStart.nsError()) == nil)
        #expect(TunnelStateMapping.disconnectMessage(for: TunnelProviderError.engineStopped.nsError()) == TunnelProviderError.engineStopped.message)
        let other = NSError(domain: NEVPNConnectionErrorDomain, code: 3)
        #expect(TunnelStateMapping.disconnectMessage(for: other) == TunnelStateMapping.droppedMessage)
        // Swift 오류의 영어 기본 설명을 그대로 보이지 않는다.
        #expect(TunnelStateMapping.disconnectMessage(for: URLError(.timedOut)) == TunnelStateMapping.droppedMessage)
    }
}

@Suite("VPN 구성 저장 판단")
@MainActor
struct TunnelConfigurationDecisionTests {
    private let desired = TunnelProviderConfig(hostname: "rd-phone-0a1b2c3d")

    private func saved(isEnabled: Bool = true, bundle: String? = TunnelController.providerBundleIdentifier, server: String? = TunnelController.serverAddress, config: TunnelProviderConfig? = nil) -> TunnelController.SavedConfiguration {
        .init(isEnabled: isEnabled, providerBundleIdentifier: bundle, serverAddress: server, config: config ?? desired)
    }

    @Test("구성이 없으면 저장한다")
    func missing() {
        #expect(TunnelController.needsSave(existing: nil, desired: desired))
    }

    @Test("같으면 저장하지 않는다")
    func same() {
        #expect(!TunnelController.needsSave(existing: saved(), desired: desired))
    }

    @Test("꺼져 있거나 값이 다르면 저장한다(사용자가 VPN을 켤 때만 부른다)")
    func differs() {
        #expect(TunnelController.needsSave(existing: saved(isEnabled: false), desired: desired))
        #expect(TunnelController.needsSave(existing: saved(bundle: "other"), desired: desired))
        #expect(TunnelController.needsSave(existing: saved(server: nil), desired: desired))
        #expect(TunnelController.needsSave(existing: saved(config: TunnelProviderConfig(hostname: "rd-phone-ffffffff")), desired: desired))
        var unreadable = saved()
        unreadable.config = nil
        #expect(TunnelController.needsSave(existing: unreadable, desired: desired))
    }

    @Test("다시 켜기 전에 먼저 꺼야 하는 VPN 상태")
    func activeStatuses() {
        #expect(TunnelStateMapping.isActive(.connecting))
        #expect(TunnelStateMapping.isActive(.connected))
        #expect(TunnelStateMapping.isActive(.reasserting))
        #expect(TunnelStateMapping.isActive(.disconnecting))
        #expect(!TunnelStateMapping.isActive(.disconnected))
        #expect(!TunnelStateMapping.isActive(.invalid))
    }
}

@Suite("터널 상태 폴더")
struct TunnelStorageTests {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TunnelStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func isExcluded(_ url: URL) throws -> Bool {
        // 캐시된 값을 읽지 않도록 새 URL로 읽는다.
        let fresh = URL(fileURLWithPath: url.path)
        return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    @Test("상태 폴더와 상위 폴더를 만들고 백업에서 뺀다(여러 번 불러도 같다)")
    func stateDirectory() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let dir = try TunnelStorage.prepareStateDirectory(in: base)
        #expect(dir.path.hasSuffix("RemoteDebug/tailscale"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try isExcluded(dir))
        #expect(try isExcluded(dir.deletingLastPathComponent()))

        // 코어가 파일을 만든 뒤 다시 준비해도 같은 폴더이고 백업 제외가 유지된다.
        try Data("state".utf8).write(to: dir.appendingPathComponent("tailscaled.state"))
        let again = try TunnelStorage.prepareStateDirectory(in: base)
        #expect(again.standardizedFileURL == dir.standardizedFileURL)
        #expect(try isExcluded(again))
        #expect(FileManager.default.fileExists(atPath: again.appendingPathComponent("tailscaled.state").path))

        // 로그인을 지우면 상태 파일이 사라지고, 다시 준비하면 빈 폴더가 생긴다.
        try TunnelStorage.resetStateDirectory(in: base)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tailscaled.state").path))
        let fresh = try TunnelStorage.prepareStateDirectory(in: base)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fresh.path).isEmpty)
        #expect(try isExcluded(fresh))
        try TunnelStorage.resetStateDirectory(in: base.appendingPathComponent("nowhere"))
    }

    @Test("상태 폴더의 백업 제외가 풀려 있으면 다시 켠다")
    func reappliesExclusion() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var dir = try TunnelStorage.prepareStateDirectory(in: base)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try dir.setResourceValues(values)
        #expect(try !isExcluded(dir))
        _ = try TunnelStorage.prepareStateDirectory(in: base)
        #expect(try isExcluded(dir))
    }

    @Test("로그 폴더와 기존 로그 파일을 백업에서 뺀다")
    func logFile() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try TunnelStorage.prepareLogFile(in: base)
        #expect(file.lastPathComponent == "core.log")
        #expect(try isExcluded(file.deletingLastPathComponent()))

        try Data("log".utf8).write(to: file)
        _ = try TunnelStorage.prepareLogFile(in: base)
        #expect(try isExcluded(file))
    }
}
