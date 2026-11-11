#if os(macOS)
import CryptoKit
import Darwin
import Foundation

public enum IPABuilder {
    /// `.app` 폴더를 `Payload/<Name>.app/...` 구조의 IPA로 묶는다.
    /// 항목 순서는 깊이 우선·이름 오름차순(바이트 기준)이라 같은 입력은 같은 항목 순서를 만든다.
    /// 심볼릭 링크는 링크로, 권한은 그대로 기록한다. 항목 하나라도 4 GiB 이상이면 `ZipError.entryTooLarge`.
    ///
    /// - `appURL`이 심볼릭 링크이면 실제 번들을 묶는다(`Payload/` 아래 이름도 실제 번들 이름).
    /// - `ipaURL`에 이미 일반 파일이 있으면 원자적으로(rename) 바꾼다. 폴더·심볼릭 링크 등 일반 파일이 아닌 것이 있으면
    ///   건드리지 않고 `ZipError.invalidDestination`을 던진다.
    /// - `control`: 항목·1 MiB 청크마다 취소를 확인하고(`CancellationError`) 진행 상황을 보고한다. 취소·실패 시 임시 파일은 지운다.
    public static func package(appAt appURL: URL, to ipaURL: URL, control: OperationControl = .default) throws -> (size: Int64, sha256: String) {
        let fm = FileManager.default
        let appURL = appURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: appURL.path, isDirectory: &isDir), isDir.boolValue, appURL.pathExtension == "app" else {
            throw ZipError.io("\(appURL.lastPathComponent)은(는) .app 폴더가 아닙니다")
        }
        let ipaURL = ipaURL.standardizedFileURL
        try checkDestination(ipaURL)

        // 먼저 목록을 만든다(진행률의 전체 크기 계산과 결정적 순서).
        let items = try collect(appURL, prefix: "Payload/\(appURL.lastPathComponent)")
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.size }
        let meter = ProgressMeter(control, total: totalBytes)
        try meter.check()

        let partial = ipaURL.deletingLastPathComponent().appendingPathComponent(".\(ipaURL.lastPathComponent).partial-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: partial) }

        let writer = try ZipWriter(url: partial)
        let appAttrs = try fm.attributesOfItem(atPath: appURL.path)
        let appDate = (appAttrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        try writer.addDirectory(name: "Payload/", mode: 0o755, modified: appDate)
        try writer.addDirectory(name: "Payload/\(appURL.lastPathComponent)/", mode: permissions(appAttrs, default: 0o755), modified: appDate)
        for item in items {
            try meter.check()
            switch item.kind {
            case .symlink(let dest): try writer.addSymlink(name: item.name, destination: dest, modified: item.modified)
            case .directory: try writer.addDirectory(name: item.name + "/", mode: item.mode, modified: item.modified)
            case .file:
                try writer.addFile(at: item.url, name: item.name, mode: item.mode, modified: item.modified, onChunk: meter.advance)
            }
        }
        try writer.finish()
        try meter.check()

        // 마지막 확인 뒤 rename(2): 일반 파일은 원자적으로 바뀌고, 그사이 폴더가 생겼다면 rename이 실패한다(폴더는 지우지 않는다).
        try checkDestination(ipaURL)
        if rename(partial.path, ipaURL.path) != 0 {
            let err = errno
            if err == EISDIR || err == ENOTEMPTY || err == EEXIST { throw ZipError.invalidDestination(ipaURL.lastPathComponent) }
            throw ZipError.io("\(ipaURL.lastPathComponent): \(String(cString: strerror(err)))")
        }
        return try fileDigest(at: ipaURL, control: control)
    }

    /// `package(appAt:to:control:)`를 협력 스레드 풀 밖에서 돌린다. 태스크를 취소하면 다음 청크 경계에서 멈추고 임시 파일을 지운다.
    public static func package(
        appAt appURL: URL, to ipaURL: URL, progress: (@Sendable (ArchiveProgress) -> Void)? = nil
    ) async throws -> (size: Int64, sha256: String) {
        let result = try await BlockingWork.run(progress: progress) { control in
            let r = try package(appAt: appURL, to: ipaURL, control: control)
            return DigestBox(size: r.size, sha256: r.sha256)
        }
        return (result.size, result.sha256)
    }

    /// 파일 크기와 SHA-256(소문자 16진수)을 1 MiB 단위로 계산한다.
    public static func fileDigest(at url: URL) throws -> (size: Int64, sha256: String) {
        try fileDigest(at: url, control: .default)
    }

    /// 청크마다 `control`로 취소를 확인하고 진행 상황을 보고한다.
    public static func fileDigest(at url: URL, control: OperationControl) throws -> (size: Int64, sha256: String) {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ZipError.io("\(error)") }
        defer { try? handle.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let meter = ProgressMeter(control, total: total)
        var hasher = SHA256()
        var size: Int64 = 0
        do {
            try meter.check()
            while let chunk = try handle.read(upToCount: ZipWriter.chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
                size += Int64(chunk.count)
                try meter.advance(chunk.count)
            }
        } catch let e as CancellationError { throw e } catch { throw ZipError.io("\(error)") }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// `fileDigest(at:)`의 비동기 판(협력 스레드 풀 밖에서 읽는다).
    public static func fileDigest(at url: URL, progress: (@Sendable (ArchiveProgress) -> Void)? = nil) async throws -> (size: Int64, sha256: String) {
        let r = try await BlockingWork.run(progress: progress) { control in
            let d = try fileDigest(at: url, control: control)
            return DigestBox(size: d.size, sha256: d.sha256)
        }
        return (r.size, r.sha256)
    }

    // MARK: 내부

    private struct DigestBox: Sendable {
        var size: Int64
        var sha256: String
    }

    /// 출력 위치는 없거나 일반 파일이어야 한다(lstat: 심볼릭 링크도 거부).
    private static func checkDestination(_ url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) == 0 {
            if st.st_mode & S_IFMT != S_IFREG { throw ZipError.invalidDestination(url.lastPathComponent) }
        } else if errno != ENOENT {
            throw ZipError.io("\(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    private enum ItemKind {
        case file
        case directory
        case symlink(String)
    }

    private struct Item {
        var url: URL
        var name: String
        var kind: ItemKind
        var mode: UInt16
        var modified: Date
        var size: Int64
    }

    private static func permissions(_ attrs: [FileAttributeKey: Any], default value: UInt16) -> UInt16 {
        (attrs[.posixPermissions] as? NSNumber).map { UInt16($0.uint16Value & 0o7777) } ?? value
    }

    /// 깊이 우선·이름 오름차순(UTF-8 바이트) 목록. 폴더 항목 바로 뒤에 그 내용이 온다.
    private static func collect(_ dir: URL, prefix: String) throws -> [Item] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: dir.path)
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var items: [Item] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            let entryName = prefix + "/" + name
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let modified = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                let dest = try fm.destinationOfSymbolicLink(atPath: url.path)
                items.append(Item(url: url, name: entryName, kind: .symlink(dest), mode: 0o755, modified: modified, size: 0))
            } else if type == .typeDirectory {
                items.append(Item(url: url, name: entryName, kind: .directory, mode: permissions(attrs, default: 0o755), modified: modified, size: 0))
                items += try collect(url, prefix: entryName)
            } else if type == .typeRegular {
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                items.append(Item(url: url, name: entryName, kind: .file, mode: permissions(attrs, default: 0o644), modified: modified, size: size))
            } else {
                throw ZipError.io("지원하지 않는 파일 종류: \(entryName)")
            }
        }
        return items
    }
}
#endif
