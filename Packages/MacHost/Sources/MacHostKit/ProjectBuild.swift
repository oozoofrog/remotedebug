import Foundation

/// 연결한 Xcode 프로젝트. `container`는 `.xcodeproj`나 `.xcworkspace`의 경로다.
public struct ConnectedProject: Codable, Sendable, Hashable, Identifiable {
    public var container: String
    /// 마지막으로 빌드한 스킴.
    public var scheme: String?
    public var addedAt: Date

    public var id: String { container }
    public var containerURL: URL { URL(fileURLWithPath: container) }
    public var name: String { containerURL.deletingPathExtension().lastPathComponent }
    /// 프로젝트 파일이 든 폴더.
    public var folder: URL { containerURL.deletingLastPathComponent() }

    public init(container: String, scheme: String? = nil, addedAt: Date) {
        self.container = container
        self.scheme = scheme
        self.addedAt = addedAt
    }
}

/// 끌어 놓은 항목에서 빌드할 `.xcworkspace`·`.xcodeproj`를 찾는다.
public enum ProjectLocator {
    static let containerExtensions: Set<String> = ["xcworkspace", "xcodeproj"]

    public static func isContainer(_ url: URL) -> Bool {
        containerExtensions.contains(url.pathExtension.lowercased())
    }

    /// `.xcworkspace`·`.xcodeproj`는 그대로, 폴더면 그 안(없으면 한 단계 아래)에서 찾는다. 워크스페이스가 프로젝트보다 먼저다.
    public static func container(for url: URL) -> URL? {
        let url = url.standardizedFileURL
        if isContainer(url) { return url }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        if let found = pick(in: url) { return found }
        for child in children(of: url) where !skipped.contains(child.lastPathComponent) && child.pathExtension.isEmpty {
            if let found = pick(in: child) { return found }
        }
        return nil
    }

    private static let skipped: Set<String> = ["node_modules", "Pods", "Carthage", "build", "Build", "DerivedData"]

    private static func pick(in dir: URL) -> URL? {
        let items = children(of: dir)
        return items.first { $0.pathExtension.lowercased() == "xcworkspace" }
            ?? items.first { $0.pathExtension.lowercased() == "xcodeproj" }
    }

    private static func children(of dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
    }
}

public struct ProjectBuildFailure: Error, LocalizedError, Sendable, Hashable {
    public var message: String
    /// 빌드 로그에서 뽑은 오류 줄(없으면 마지막 줄들).
    public var logTail: String

    public init(message: String, logTail: String = "") {
        self.message = message
        self.logTail = logTail
    }

    public var errorDescription: String? { message }
}

/// 프로젝트의 스킴을 읽고 Debug 기기용으로 빌드한다.
public protocol ProjectBuilding: Sendable {
    func schemes(container: URL) async throws -> [String]
    /// 출력은 `log`에 쓴다. 실패하면 `ProjectBuildFailure`를 던진다.
    func build(container: URL, scheme: String, log: URL) async throws
}

/// `xcodebuild`를 실행한다. 빌드 폴더는 Xcode와 같은 DerivedData를 쓴다(따로 지정하지 않는다).
public struct XcodeBuildTool: ProjectBuilding {
    public var executable: URL

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/xcodebuild")) {
        self.executable = executable
    }

    static func containerArguments(_ container: URL) -> [String] {
        [container.pathExtension.lowercased() == "xcworkspace" ? "-workspace" : "-project", container.path]
    }

    public static func buildArguments(container: URL, scheme: String) -> [String] {
        containerArguments(container) + [
            "-scheme", scheme, "-configuration", "Debug", "-destination", "generic/platform=iOS", "build",
        ]
    }

    public func schemes(container: URL) async throws -> [String] {
        let pipe = Pipe()
        let status = try await Self.run(executable, ["-list", "-json"] + Self.containerArguments(container),
                                        cwd: container.deletingLastPathComponent(), stdout: pipe, stderr: FileHandle.nullDevice)
        guard status.code == 0 else {
            throw ProjectBuildFailure(message: "스킴 목록을 읽지 못했습니다(xcodebuild 종료 코드 \(status.code)).")
        }
        return try Self.parseSchemes(status.output)
    }

    /// `xcodebuild -list -json` 출력에서 스킴 이름을 꺼낸다.
    public static func parseSchemes(_ data: Data) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectBuildFailure(message: "스킴 목록을 해석하지 못했습니다.")
        }
        let body = (object["workspace"] ?? object["project"]) as? [String: Any]
        return body?["schemes"] as? [String] ?? []
    }

    public func build(container: URL, scheme: String, log: URL) async throws {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let status = try await Self.run(executable, Self.buildArguments(container: container, scheme: scheme),
                                        cwd: container.deletingLastPathComponent(), stdout: handle, stderr: handle)
        guard status.code == 0 else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw ProjectBuildFailure(message: "빌드에 실패했습니다(xcodebuild 종료 코드 \(status.code)).", logTail: Self.failureTail(text))
        }
    }

    /// `error:`가 든 줄(중복 제거, 최대 20줄). 없으면 마지막 20줄.
    public static func failureTail(_ log: String) -> String {
        let lines = log.split(whereSeparator: \.isNewline).map(String.init)
        var seen = Set<String>()
        let errors = lines.filter { $0.contains("error:") && seen.insert($0).inserted }
        return (errors.isEmpty ? lines.suffix(20) : errors.prefix(20)).joined(separator: "\n")
    }

    /// `stdout`이 `Pipe`면 끝까지 읽어 `output`으로 돌려준다. 작업이 취소되면 프로세스를 끝낸다.
    static func run(_ executable: URL, _ arguments: [String], cwd: URL, stdout: Any, stderr: Any) async throws -> (code: Int32, output: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let box = ProcessBox(process, pipe: stdout as? Pipe)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do {
                        try box.process.run()
                        let data = box.pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                        box.process.waitUntilExit()
                        continuation.resume(returning: (box.process.terminationStatus, data))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        let pipe: Pipe?
        init(_ process: Process, pipe: Pipe?) {
            self.process = process
            self.pipe = pipe
        }
    }
}

/// Xcode DerivedData의 프로젝트별 폴더 하나.
public struct DerivedDataEntry: Sendable, Hashable {
    public var dir: URL
    /// 그 폴더를 만든 `.xcodeproj`·`.xcworkspace` 경로(`info.plist`의 `WorkspacePath`).
    public var workspacePath: String
    /// 마지막 빌드 활동 시각(빌드 기록과 `Debug-iphoneos` 폴더의 수정 시각 중 늦은 것).
    public var activity: Date?
    /// `Build/Products/Debug-iphoneos`가 있다(기기용 Debug 빌드를 한 적이 있거나 하는 중이다).
    public var hasDeviceDebug: Bool

    public var debugProducts: URL { Self.debugProducts(in: dir) }

    static func debugProducts(in dir: URL) -> URL {
        dir.appendingPathComponent("Build/Products/Debug-iphoneos", isDirectory: true)
    }
}

/// Xcode의 DerivedData를 훑어 어느 프로젝트가 빌드되고 있는지 본다.
public struct DerivedDataScanner: Sendable {
    public var root: URL

    public init(root: URL = DerivedDataScanner.defaultRoot()) {
        self.root = root
    }

    /// Xcode 설정의 사용자 지정 위치(절대 경로일 때만), 없으면 `~/Library/Developer/Xcode/DerivedData`.
    public static func defaultRoot(xcodeDefaults: UserDefaults? = UserDefaults(suiteName: "com.apple.dt.Xcode")) -> URL {
        if let custom = xcodeDefaults?.string(forKey: "IDECustomDerivedDataLocation"), custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    }

    public func entries() -> [DerivedDataEntry] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = fm.contents(atPath: dir.appendingPathComponent("info.plist").path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspace = plist["WorkspacePath"] as? String
            else { return nil }
            let products = DerivedDataEntry.debugProducts(in: dir)
            let buildData = dir.appendingPathComponent("Build/Intermediates.noindex/XCBuildData", isDirectory: true)
            let dates = [products, buildData, buildData.appendingPathComponent("build.db")].compactMap(Self.modified)
            return DerivedDataEntry(dir: dir, workspacePath: URL(fileURLWithPath: workspace).standardizedFileURL.path,
                                    activity: dates.max(), hasDeviceDebug: fm.fileExists(atPath: products.path))
        }
    }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
