import Foundation

/// 테스트 보조: 픽스처 위치, 임시 폴더, 외부 도구 실행(테스트에서는 시스템 도구 사용이 허용된다).
enum Fixtures {
    static var root: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }  // Tests/RDKitTests/Support.swift → 패키지 루트
        return u.appendingPathComponent("Fixtures/apps", isDirectory: true)
    }

    static func app(_ relative: String) -> URL {
        root.appendingPathComponent(relative, isDirectory: true)
    }

    /// 픽스처에 쓰인 가짜 UDID(스크립트 참조).
    static let provisionedUDID = "00008110-000A1B2C3D4E5F60"
    static let otherUDID = "00008110-0000000000000000"
}

final class TempDir {
    let url: URL

    init(_ label: String = "t") throws {
        let env = ProcessInfo.processInfo.environment
        var base: URL
        if let p = env["EYEBUILD_DIR"] ?? env["RD_TEST_TMPDIR"] {
            base = URL(fileURLWithPath: p, isDirectory: true)
        } else if FileManager.default.fileExists(atPath: "/Volumes/eyedisk/build/remotedebug") {
            // `eyebuild -p remotedebug dir kit-tmp`와 같은 위치(내장 디스크를 쓰지 않는다).
            base = URL(fileURLWithPath: "/Volumes/eyedisk/build/remotedebug/kit-tmp", isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("rdtest-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL { url.appendingPathComponent(name) }
}

struct ToolResult {
    var status: Int32
    var output: String
}

@discardableResult
func runTool(_ launchPath: String, _ args: [String]) throws -> ToolResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ToolResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
}
