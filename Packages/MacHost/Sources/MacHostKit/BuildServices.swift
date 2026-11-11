import Foundation
import RDBuildInspection
import RDModels
import RDPackaging

/// 파일 크기와 SHA-256(소문자 16진수).
public struct FileDigest: Codable, Sendable, Hashable {
    public var size: Int64
    public var sha256: String

    public init(size: Int64, sha256: String) {
        self.size = size
        self.sha256 = sha256
    }
}

/// 디버그 한정 정책 검사(protocol §7).
public protocol BuildInspecting: Sendable {
    func inspect(appAt url: URL, options: InspectionOptions) async throws -> InspectionResult
    /// `workDirectory` 아래에 풀어 검사하고 지운다.
    func inspect(ipaAt url: URL, options: InspectionOptions, workDirectory: URL) async throws -> InspectionResult
}

/// `.app` → `.ipa` 묶기와 파일 해시.
public protocol BuildPackaging: Sendable {
    func package(appAt appURL: URL, to ipaURL: URL) async throws -> FileDigest
    func digest(of fileURL: URL) async throws -> FileDigest
}

/// 킷의 `BuildInspector` async API를 쓰는 실제 검사기.
public struct KitBuildInspector: BuildInspecting {
    public init() {}

    public func inspect(appAt url: URL, options: InspectionOptions) async throws -> InspectionResult {
        try await BuildInspector.inspect(appAt: url, options: options)
    }

    public func inspect(ipaAt url: URL, options: InspectionOptions, workDirectory: URL) async throws -> InspectionResult {
        try await BuildInspector.inspect(ipaAt: url, options: options, workDirectory: workDirectory, progress: nil)
    }
}

/// 킷의 `IPABuilder` async API를 쓰는 실제 패키저.
public struct KitBuildPackager: BuildPackaging {
    public init() {}

    public func package(appAt appURL: URL, to ipaURL: URL) async throws -> FileDigest {
        let r = try await IPABuilder.package(appAt: appURL, to: ipaURL, progress: nil)
        return FileDigest(size: r.size, sha256: r.sha256)
    }

    public func digest(of fileURL: URL) async throws -> FileDigest {
        let r = try await IPABuilder.fileDigest(at: fileURL, progress: nil)
        return FileDigest(size: r.size, sha256: r.sha256)
    }
}
