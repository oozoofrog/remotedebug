import CryptoKit
import Foundation
import RDModels

enum FileDigest {
    /// 파일 크기와 SHA-256(소문자 16진수).
    static func sha256(of url: URL) throws -> (Int64, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// iPhone에 받아 둔 파일 하나.
public struct ReceivedFile: Hashable, Sendable, Identifiable {
    public var url: URL
    public var size: Int64
    public var modifiedAt: Date?
    /// Mac 목록의 SHA-256(이 앱이 받은 파일이면). 파일 앱에서 바꾸면 맞지 않을 수 있다.
    public var sha256: String?

    public var id: String { name }
    public var name: String { url.lastPathComponent }

    public init(url: URL, size: Int64, modifiedAt: Date?, sha256: String?) {
        self.url = url
        self.size = size
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
    }
}

/// 받은 파일을 앱의 Documents 폴더에 둔다. 파일 앱의 "나의 iPhone > RemoteDebug"에 보인다.
/// 어떤 내용(SHA-256)을 받았는지는 따로 기록해 Mac 목록과 비교한다.
public final class ReceivedFileStore: @unchecked Sendable {
    public let directory: URL
    private let indexURL: URL
    private let lock = NSLock()

    public init(directory: URL, indexURL: URL) {
        self.directory = directory
        self.indexURL = indexURL
    }

    /// 앱의 Documents와 Application Support의 기록 파일.
    public static func standard() -> ReceivedFileStore {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return ReceivedFileStore(directory: documents, indexURL: support.appendingPathComponent("received-files.json"))
    }

    /// 받은 임시 파일을 `name`으로 옮긴다. 같은 이름이 있으면 바꾼다.
    @discardableResult
    public func save(_ temp: URL, as resource: ResourceDescriptor) throws -> URL {
        guard ResourceDescriptor.isValidName(resource.name) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(resource.name, isDirectory: false)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
        lock.withLock {
            var index = loadIndex()
            index[resource.name] = resource.sha256.lowercased()
            saveIndex(index)
        }
        return destination
    }

    public func delete(_ name: String) throws {
        guard ResourceDescriptor.isValidName(name) else { throw CocoaError(.fileNoSuchFile) }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        lock.withLock {
            var index = loadIndex()
            index[name] = nil
            saveIndex(index)
        }
    }

    /// 폴더의 파일(숨김 파일·폴더 제외), 최근에 바뀐 것부터.
    public func list() -> [ReceivedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let index = lock.withLock { loadIndex() }
        return items.compactMap { url -> ReceivedFile? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return ReceivedFile(url: url, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate,
                                sha256: index[url.lastPathComponent])
        }
        .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    private func loadIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveIndex(_ index: [String: String]) {
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(index).write(to: indexURL, options: [.atomic])
    }
}
