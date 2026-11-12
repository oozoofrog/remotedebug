import Foundation
import Observation
import RDModels

/// 이 iPhone 앱의 진단 로그. Mac에 보내기 전까지 파일에 남겨 앱이 꺼져도(업데이트 설치 등) 다음 실행에서 보낸다.
@MainActor
@Observable
public final class DeviceLogBook {
    /// 화면에 보여 줄 최근 줄(오래된 것부터).
    public private(set) var recent: [DeviceLogEntry] = []
    /// 아직 Mac에 보내지 않은 줄 수.
    public var unsentCount: Int { unsent.count }

    /// 보관하는 줄 수의 한도. 넘으면 오래된 줄부터 버린다.
    public nonisolated static let maxUnsent = 2000
    public nonisolated static let maxRecent = 300

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let now: @Sendable () -> Date
    private var unsent: [DeviceLogEntry] = []

    /// `fileURL`이 `nil`이면 메모리에만 둔다(시험·미리보기).
    public init(fileURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? RDJSON.decoder().decode([DeviceLogEntry].self, from: data) {
            unsent = Array(saved.suffix(Self.maxUnsent))
            recent = Array(unsent.suffix(Self.maxRecent))
        }
    }

    /// 앱 데이터 폴더의 기본 위치. 앱을 업데이트해도 남는다.
    public nonisolated static func defaultFileURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("device-log.json")
    }

    public func log(_ level: DeviceLogEntry.Level, _ source: String, _ message: String) {
        let entry = DeviceLogEntry(at: now(), level: level, source: source,
                                   message: HostAPI.truncated(message, maxBytes: DeviceLogBatch.maxMessageBytes))
        unsent.append(entry)
        if unsent.count > Self.maxUnsent { unsent.removeFirst(unsent.count - Self.maxUnsent) }
        recent.append(entry)
        if recent.count > Self.maxRecent { recent.removeFirst(recent.count - Self.maxRecent) }
        save()
    }

    /// 보낼 다음 묶음(오래된 것부터 최대 200줄).
    func nextBatch() -> [DeviceLogEntry] {
        Array(unsent.prefix(DeviceLogBatch.maxEntries))
    }

    /// 보낸 묶음을 지운다. 보내는 동안 앞쪽이 잘렸으면(한도 초과) 남은 것만 지운다.
    func markSent(_ batch: [DeviceLogEntry]) {
        let sent = Set(batch.map(\.id))
        unsent.removeAll { sent.contains($0.id) }
        save()
    }

    private func save() {
        guard let fileURL, let data = try? RDJSON.encoder().encode(unsent) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
