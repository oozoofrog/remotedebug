import CryptoKit
import Foundation
import RDModels

/// iPhone에 보내는 파일 목록(docs/protocol-addenda.md H).
///
/// 파일은 `Published/Files/<id>`에 사본으로 두고 목록은 `resources.json`에 저장한다.
/// 공유 중(`activate` 뒤)이면 넣고 빼는 즉시 코어에 반영하고, 공유를 시작할 때 저장된 파일을 모두 다시 게시한다.
/// 이름이 같은 파일을 다시 넣으면 이전 것을 바꾼다.
public actor ResourceLibrary {
    public static let maxFileBytes: Int64 = 4 << 30
    public static let maxCount = 500

    public private(set) var resources: [ResourceDescriptor] = []
    private let paths: HostPaths
    private let host: any HostCore
    private let now: @Sendable () -> Date
    private let file: JSONFile<[ResourceDescriptor]>
    private var isActive = false

    public init(paths: HostPaths, host: any HostCore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.host = host
        self.now = now
        self.file = JSONFile(url: paths.resourcesFile)
    }

    /// 저장된 목록을 읽는다. 파일이 없어진 항목은 뺀다.
    public func load() throws {
        let stored = try file.load() ?? []
        resources = stored.filter { $0.isLink || FileManager.default.fileExists(atPath: paths.resourceURL(forID: $0.id).path) }
        if resources.count != stored.count { try? file.save(resources) }
    }

    /// 공유를 시작했다. 저장된 파일을 모두 코어에 게시하고 실패한 파일 이름을 돌려준다.
    public func activate() async -> [String] {
        isActive = true
        var failed: [String] = []
        for r in resources {
            do {
                try await host.publishResource(request(r))
            } catch {
                failed.append(r.name)
            }
        }
        return failed
    }

    /// 공유를 멈췄다(코어가 게시본을 모두 지운다).
    public func deactivate() {
        isActive = false
    }

    /// 파일을 목록에 넣는다. 같은 이름의 이전 파일은 뺀다.
    @discardableResult
    public func add(_ source: URL) async throws -> ResourceDescriptor {
        let fm = FileManager.default
        let resolved = source.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw ResourceLibraryError.notAFile(source.lastPathComponent) }
        guard Int64(values?.fileSize ?? 0) <= Self.maxFileBytes else { throw ResourceLibraryError.tooLarge(source.lastPathComponent) }
        let name = Self.safeName(source.lastPathComponent)

        try fm.createDirectory(at: paths.workDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.filesDir, withIntermediateDirectories: true)
        let temp = paths.workDir.appendingPathComponent("file-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try fm.copyItem(at: resolved, to: temp)
        let (size, sha) = try Self.hash(temp)
        let id = ResourceDescriptor.makeID(name: name, sha256: sha)
        if let existing = resources.first(where: { $0.id == id }) { return existing }
        guard resources.count < Self.maxCount || resources.contains(where: { $0.name == name }) else {
            throw ResourceLibraryError.tooMany
        }

        let destination = paths.resourceURL(forID: id)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: temp, to: destination)
        let descriptor = ResourceDescriptor(id: id, name: name, size: size, sha256: sha, publishedAt: Self.wholeSeconds(now()))
        if isActive {
            do {
                try await host.publishResource(request(descriptor))
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
        }
        let replaced = resources.filter { $0.name == name && $0.id != id }
        resources.removeAll { $0.id == id || $0.name == name }
        resources.insert(descriptor, at: 0)
        try? file.save(resources)
        for old in replaced { await drop(old.id) }
        return descriptor
    }

    /// 링크를 목록에 넣는다. 같은 주소의 이전 링크는 뺀다. 이름이 없으면 주소에서 만든다.
    @discardableResult
    public func addLink(_ url: URL, title: String? = nil) async throws -> ResourceDescriptor {
        let link = url.absoluteString
        guard url.scheme?.isEmpty == false, link.utf8.count <= 8 << 10 else { throw ResourceLibraryError.badLink(link) }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = Self.safeName(trimmed.isEmpty ? Self.linkName(url) : trimmed)
        let sha = ResourceDescriptor.linkHash(link)
        let id = ResourceDescriptor.makeID(name: name, sha256: sha)
        if let existing = resources.first(where: { $0.id == id }) { return existing }
        guard resources.count < Self.maxCount || resources.contains(where: { $0.link == link }) else { throw ResourceLibraryError.tooMany }
        let descriptor = ResourceDescriptor(id: id, name: name, size: 0, sha256: sha, publishedAt: Self.wholeSeconds(now()), link: link)
        if isActive { try await host.publishResource(request(descriptor)) }
        let replaced = resources.filter { $0.link == link && $0.id != id }
        resources.removeAll { $0.id == id || $0.link == link }
        resources.insert(descriptor, at: 0)
        try? file.save(resources)
        for old in replaced { await drop(old.id) }
        return descriptor
    }

    /// 주소에서 보기 좋은 이름: 호스트와 경로 끝(`example.com – docs`), 호스트가 없으면 스킴.
    static func linkName(_ url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? ""
        let last = url.pathComponents.last(where: { $0 != "/" }) ?? ""
        let base = host.isEmpty ? (url.scheme ?? "링크") + " 링크" : host
        return last.isEmpty ? base : "\(base) – \(last)"
    }

    /// 파일을 목록에서 뺀다.
    public func remove(id: String) async throws {
        guard resources.contains(where: { $0.id == id }) else { return }
        if isActive {
            do {
                try await host.unpublishResource(id: id)
            } catch let error as APIErrorBody where error.error.code == "resource_not_found" {
                // 코어에 이미 없다.
            }
        }
        resources.removeAll { $0.id == id }
        try file.save(resources)
        try? FileManager.default.removeItem(at: paths.resourceURL(forID: id))
    }

    private func drop(_ id: String) async {
        if isActive { try? await host.unpublishResource(id: id) }
        try? FileManager.default.removeItem(at: paths.resourceURL(forID: id))
    }

    private func request(_ r: ResourceDescriptor) -> ResourcePublishRequest {
        ResourcePublishRequest(resource: r, path: r.isLink ? "" : paths.resourceURL(forID: r.id).path)
    }

    /// 코어가 받지 않는 글자(`/ \ :`, 제어 문자)를 `_`로 바꾸고 255바이트 안으로 줄인다.
    public static func safeName(_ raw: String) -> String {
        var name = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            "/\\:".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0) ? "_" : $0
        }))
        while name.utf8.count > 255 { name.removeFirst() }
        return ResourceDescriptor.isValidName(name) ? name : "file"
    }

    /// 저장·전송 형식(초 단위 ISO-8601)과 같게 맞춘다.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    static func hash(_ url: URL) throws -> (Int64, String) {
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

public enum ResourceLibraryError: LocalizedError, Equatable {
    case notAFile(String)
    case tooLarge(String)
    case tooMany
    case badLink(String)

    public var errorDescription: String? {
        switch self {
        case .notAFile(let name): "\(name)은(는) 파일이 아닙니다. 폴더는 압축해서 보내세요."
        case .tooLarge(let name): "\(name)이(가) 4GB보다 큽니다."
        case .tooMany: "파일은 500개까지 보낼 수 있습니다. 쓰지 않는 파일을 지운 뒤 다시 보내세요."
        case .badLink(let text): "\(text)은(는) 보낼 수 있는 주소가 아닙니다. https://… 나 앱스킴://… 처럼 스킴이 있는 주소를 넣으세요."
        }
    }
}
