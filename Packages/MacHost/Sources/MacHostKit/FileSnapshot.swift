import CryptoKit
import Foundation

/// lstat 결과로 본 경로의 종류.
enum FileKind: Sendable, Hashable {
    case missing
    case regular
    /// 심볼릭 링크·폴더 등 일반 파일이 아님.
    case other
    /// 없음 외의 이유로 읽지 못했다(일시적 I/O 오류 등).
    case unreadable(Int32)

    static func of(_ url: URL) -> FileKind {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable(errno)
        }
        return (st.st_mode & S_IFMT) == S_IFREG ? .regular : .other
    }
}

/// `.app` 번들 트리의 지문: 모든 항목의 상대 경로·종류·크기·수정 시각(ns)·inode.
/// 검사와 묶기 사이에 번들이 바뀌었는지 확인하는 데 쓴다. 내용 해시가 아니라 메타데이터 지문이다.
struct BundleSnapshot: Sendable, Hashable {
    let digest: String
    let entries: Int

    /// 심볼릭 링크를 푼 번들을 훑는다. 번들을 읽을 수 없으면 nil.
    static func take(_ appURL: URL) -> BundleSnapshot? {
        let root = appURL.standardizedFileURL.resolvingSymlinksInPath()
        var hasher = SHA256()
        var count = 0
        guard let rootLine = line(root, relative: ".") else { return nil }
        hasher.update(data: Data(rootLine.utf8))
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return nil }
        var names: [String] = []
        while let name = e.nextObject() as? String { names.append(name) }
        for name in names.sorted() {
            guard let l = line(root.appendingPathComponent(name), relative: name) else { return nil }
            hasher.update(data: Data(l.utf8))
            count += 1
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return BundleSnapshot(digest: hex, entries: count)
    }

    private static func line(_ url: URL, relative: String) -> String? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let m = st.st_mtimespec
        return "\(relative)\u{0}\(st.st_mode)\u{0}\(st.st_size)\u{0}\(m.tv_sec).\(m.tv_nsec)\u{0}\(st.st_ino)\n"
    }
}
