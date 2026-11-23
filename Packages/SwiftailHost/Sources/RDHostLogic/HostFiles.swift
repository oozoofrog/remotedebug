import CryptoKit
import Foundation
import RDModels

extension HostLogic {
    struct Snapshot: Sendable {
        let path: String
        let size: UInt64
        let inode: UInt64
        let device: UInt64
        let modified: Date
        init(path: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { throw HostErrors.make("build_changed") }
            self.path = path
            self.size = size.uint64Value
            self.inode = inode.uint64Value
            self.device = device.uint64Value
            self.modified = modified
        }
        func unchanged(checkTime: Bool = true) -> Bool {
            guard let current = try? Snapshot(path: path) else { return false }
            return size == current.size && inode == current.inode && device == current.device && (!checkTime || modified == current.modified)
        }
        func hash() throws -> String {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            var digest = SHA256(), read: UInt64 = 0
            while let data = try handle.read(upToCount: 32 << 10), !data.isEmpty {
                digest.update(data: data)
                read += UInt64(data.count)
            }
            guard read == size else { throw HostErrors.make("build_changed") }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Build { let identity = UUID(); var descriptor: BuildDescriptor; let file: Snapshot; let sum: String; var wire: Data? = nil; var sortTimestamp: String? = nil }
    struct Resource { var descriptor: ResourceDescriptor; let file: Snapshot?; var wire: Data? = nil; var sortTimestamp: String? = nil }

    func resolveFile(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw HostErrors.make("path_outside_publish_dir") }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(publishDirectory + "/"), !resolved.hasPrefix(snapshotDirectory + "/"),
              (try? FileManager.default.attributesOfItem(atPath: resolved)[.type] as? FileAttributeType) == .typeRegular else {
            throw HostErrors.make("path_outside_publish_dir")
        }
        return resolved
    }

    func snapshot(_ source: String) throws -> String {
        let destination = snapshotDirectory + "/" + HostIDs.newID("tmp-") + ".ipa"
        do {
            // FileManager의 파일 복사는 지원하는 볼륨에서 clonefile을 사용하고 나머지는 스트림 복사한다.
            try FileManager.default.copyItem(atPath: source, toPath: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(atPath: destination)
            throw error
        }
    }

    @discardableResult
    public func publish(_ request: PublishRequest) throws -> String { try publishBuild(request, wire: nil, timestamp: nil) }

    func publishBuild(_ request: PublishRequest, wire: Data?, timestamp: String?) throws -> String {
        var descriptor = request.build
        guard descriptor.debug else { throw HostErrors.make("not_debug_build", "debug가 true가 아닙니다.") }
        guard descriptor.signing.getTaskAllow else { throw HostErrors.make("not_debug_build", "signing.getTaskAllow가 true가 아닙니다.") }
        guard !descriptor.bundleId.isEmpty else { throw HostErrors.make("bad_request", "bundleId가 필요합니다.") }
        if let icon = descriptor.icon, !icon.isEmpty, icon.count > BuildDescriptor.maxIconBytes || !BuildDescriptor.isPNG(icon) {
            throw HostErrors.make("bad_request", "icon은 64KiB 이하의 PNG여야 합니다.")
        }
        if descriptor.icon?.isEmpty == true { descriptor.icon = nil }
        descriptor.releaseNotes = BuildDescriptor.cleanReleaseNotes(descriptor.releaseNotes)
        if let notes = descriptor.releaseNotes, notes.utf8.count > BuildDescriptor.maxReleaseNotesBytes {
            throw HostErrors.make("bad_request", "releaseNotes는 4KiB 이하여야 합니다.")
        }
        let source = try resolveFile(request.ipaPath)
        let temporary: String
        do { temporary = try snapshot(source) }
        catch { throw HostErrors.make("internal", "IPA 사본을 만들지 못했습니다.") }
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        let file: Snapshot, sum: String
        do { file = try Snapshot(path: temporary); sum = try file.hash() }
        catch { throw HostErrors.make("internal", "IPA를 읽지 못했습니다.") }
        guard descriptor.ipa.size >= 0, UInt64(descriptor.ipa.size) == file.size, descriptor.ipa.sha256.lowercased() == sum else {
            throw HostErrors.make("hash_mismatch", "IPA 크기 또는 SHA-256이 설명과 다릅니다.")
        }
        descriptor.ipa.sha256 = sum
        let id = HostIDs.buildID(bundleID: descriptor.bundleId, sha256: sum)
        guard descriptor.id.isEmpty || descriptor.id == id else {
            throw HostErrors.make("bad_request", "id가 bundleId와 IPA 해시에서 계산한 값과 다릅니다: " + id)
        }
        descriptor.id = id
        return try locked {
            guard !closed else { throw HostErrors.make("not_running", "노드가 종료되었습니다.") }
            if builds[id] != nil { builds[id]?.descriptor = descriptor; builds[id]?.wire = wire; builds[id]?.sortTimestamp = timestamp; return id }
            let final = snapshotDirectory + "/" + id + ".ipa"
            do {
                try FileManager.default.moveItem(atPath: temporary, toPath: final)
                builds[id] = Build(descriptor: descriptor, file: try Snapshot(path: final), sum: sum, wire: wire, sortTimestamp: timestamp)
            } catch { throw HostErrors.make("internal", "IPA 사본을 저장하지 못했습니다.") }
            return id
        }
    }

    public func unpublish(buildID: String) throws {
        try locked {
            guard let build = builds.removeValue(forKey: buildID) else { throw HostErrors.make("build_not_found") }
            for session in sessions.values where session.buildID == buildID { failSession(session) }
            try? FileManager.default.removeItem(atPath: build.file.path)
        }
    }

    @discardableResult
    public func publishResource(_ request: ResourcePublishRequest) throws -> String { try publishResourceRequest(request, timestamp: nil) }

    func publishResourceRequest(_ request: ResourcePublishRequest, timestamp: String?) throws -> String {
        var descriptor = request.resource
        guard Self.validResourceName(descriptor.name) else {
            throw HostErrors.make("bad_request", "name은 255바이트 이하의 파일 이름이어야 합니다(/, \\, :, 제어 문자 불가).")
        }
        guard Self.validProject(descriptor.project) else {
            throw HostErrors.make("bad_request", "project는 id(영문자·숫자·_·- 64바이트 이하)와 name(255바이트 이하, 제어 문자 불가)이 있어야 합니다.")
        }
        var temporary: String?
        defer { if let temporary { try? FileManager.default.removeItem(atPath: temporary) } }
        let sum: String
        if let link = descriptor.link, !link.isEmpty {
            guard Self.validLink(link) else { throw HostErrors.make("bad_request", "link는 8KiB 이하의 절대 URL이어야 합니다.") }
            descriptor.size = 0
            sum = HostIDs.sha256(Data(link.utf8))
        } else {
            descriptor.link = nil
            guard descriptor.size >= 0 && descriptor.size <= 4 << 30 else { throw HostErrors.make("bad_request", "파일이 너무 큽니다(최대 4GiB).") }
            let source = try resolveFile(request.path)
            do { temporary = try snapshot(source) }
            catch { throw HostErrors.make("internal", "파일 사본을 만들지 못했습니다.") }
            let file: Snapshot
            do {
                file = try Snapshot(path: temporary!)
                sum = try file.hash()
            } catch { throw HostErrors.make("internal", "파일을 읽지 못했습니다.") }
            guard UInt64(descriptor.size) == file.size, descriptor.sha256.lowercased() == sum else {
                throw HostErrors.make("hash_mismatch", "파일 크기 또는 SHA-256이 설명과 다릅니다.")
            }
        }
        descriptor.sha256 = sum
        let id = HostIDs.resourceID(name: descriptor.name, sha256: sum)
        guard descriptor.id.isEmpty || descriptor.id == id else {
            throw HostErrors.make("bad_request", "id가 name과 SHA-256에서 계산한 값과 다릅니다: " + id)
        }
        descriptor.id = id
        var wire: Data?
        if let timestamp {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any] ?? [:]
            object["publishedAt"] = timestamp
            wire = try JSONSerialization.data(withJSONObject: object)
        }
        return try locked {
            guard !closed else { throw HostErrors.make("not_running", "노드가 종료되었습니다.") }
            if resources[id] != nil { resources[id]?.descriptor = descriptor; resources[id]?.wire = wire; resources[id]?.sortTimestamp = timestamp; return id }
            guard resources.count < 500 else { throw HostErrors.make("bad_request", "파일은 500개까지 공유할 수 있습니다.") }
            var stored: Snapshot?
            if let temporary {
                let final = snapshotDirectory + "/" + id + ".res"
                do {
                    try FileManager.default.moveItem(atPath: temporary, toPath: final)
                    stored = try Snapshot(path: final)
                } catch { throw HostErrors.make("internal", "파일 사본을 저장하지 못했습니다.") }
            }
            resources[id] = Resource(descriptor: descriptor, file: stored, wire: wire, sortTimestamp: timestamp)
            return id
        }
    }

    public func unpublishResource(id: String) throws {
        try locked {
            guard let resource = resources.removeValue(forKey: id) else { throw HostErrors.make("resource_not_found") }
            if let file = resource.file { try? FileManager.default.removeItem(atPath: file.path) }
        }
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.value < 32 || (127...159).contains(scalar.value) }
    static func validResourceName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." &&
        !name.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0 == ":" || isControl($0) }
    }
    static func validProject(_ project: ResourceProject?) -> Bool {
        guard let project else { return true }
        return !project.id.isEmpty && project.id.utf8.count <= 64 && !project.name.isEmpty && project.name.utf8.count <= 255 &&
            project.id.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 } &&
            !project.name.unicodeScalars.contains(where: isControl)
    }
    static func validLink(_ link: String) -> Bool {
        guard !link.isEmpty, link.utf8.count <= 8 << 10, !link.unicodeScalars.contains(where: isControl),
              let colon = link.firstIndex(of: ":"), colon != link.startIndex else { return false }
        let scheme = link[..<colon]
        guard scheme.utf8.first.map({ (65...90).contains($0) || (97...122).contains($0) }) == true,
              scheme.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46 }) else { return false }
        let rest = link[link.index(after: colon)...]
        if let hash = rest.firstIndex(of: "#"), hostPercentDecode(String(rest[rest.index(after: hash)...])) == nil { return false }
        // 스킴 뒤의 불투명 부분은 Go url.Parse처럼 경로 이스케이프 검사를 하지 않는다.
        if !rest.hasPrefix("/") { return true }
        return hostPercentDecode(String(rest)) != nil && URLComponents(string: link) != nil
    }
}
