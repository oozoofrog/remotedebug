import Foundation
import MacHostKit

/// E2E 환경: `RD_FIXTURES`(없으면 저장소의 픽스처), `RD_E2E_TMPDIR`·`RD_TEST_TMPDIR`(빌드 디스크의 폴더. 없으면 시스템 임시 폴더).
enum E2EEnv {
    static var fixtures: URL {
        if let p = ProcessInfo.processInfo.environment["RD_FIXTURES"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u.deleteLastPathComponent() }  // Tests/MacHostE2ETests/E2ESupport.swift → Packages
        return u.appendingPathComponent("RemoteDebugKit/Fixtures/apps", isDirectory: true)
    }

    static var tmpBase: URL {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RD_E2E_TMPDIR"] ?? env["RD_TEST_TMPDIR"] else { return FileManager.default.temporaryDirectory }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

final class E2ETempDir: @unchecked Sendable {
    let url: URL

    init() throws {
        url = E2EEnv.tmpBase.appendingPathComponent("e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// 감시 폴더를 쓰지 않는 E2E용 북마크 저장소(UserDefaults를 건드리지 않는다).
final class NoBookmarks: FolderBookmarking {
    func save(_ url: URL) throws {}
    func resolve() -> URL? { nil }
    func clear() {}
}

func randomID8() -> String { String(format: "%08x", UInt32.random(in: .min ... .max)) }
