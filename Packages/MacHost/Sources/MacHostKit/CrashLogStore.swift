import Foundation
import Observation
import RDModels

/// iPhone이 보낸 크래시 기록(docs/protocol-addenda.md L). `CrashLogs/`에 기록마다 원문 파일 하나와 목록(`index.json`)을 둔다.
@MainActor
@Observable
public final class CrashLogStore {
    public struct Item: Codable, Identifiable, Hashable, Sendable {
        public var id: String
        public var kind: CrashReport.Kind
        public var name: String
        public var bundleId: String
        public var appVersion: String
        public var crashedAt: Date
        public var receivedAt: Date
        public var deviceId: String
        public var deviceName: String
        /// `CrashLogs/` 안의 원문 파일 이름.
        public var file: String

        /// 목록에 보일 이름: 번들 ID의 마지막 마디, 없으면 파일 이름.
        public var title: String {
            bundleId.split(separator: ".").last.map(String.init) ?? name
        }
    }

    /// 보관하는 기록 수. 넘으면 오래된 것부터 지운다.
    public nonisolated static let limit = 200

    /// 최근 크래시가 앞.
    public private(set) var items: [Item] = []

    @ObservationIgnored public let directory: URL?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var memory: [String: String] = [:]

    /// `directory`가 `nil`이면 파일에 쓰지 않는다(시험·미리보기).
    public init(directory: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        if let directory { items = Self.load(directory: directory) }
    }

    /// 받은 기록을 저장한다. 같은 기기가 같은 기록을 다시 보내면 그대로 둔다.
    func receive(_ event: DeviceCrashEvent) {
        let report = event.report
        guard !items.contains(where: { $0.id == report.id }) else { return }
        let item = Item(id: report.id, kind: report.kind, name: report.name, bundleId: report.bundleId,
                        appVersion: report.appVersion, crashedAt: report.crashedAt, receivedAt: now(),
                        deviceId: event.deviceId, deviceName: event.deviceName,
                        file: "\(report.id).\(report.kind.fileExtension)")
        if let url = fileURL(item) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(report.text.utf8).write(to: url, options: .atomic)
        } else {
            memory[item.id] = report.text
        }
        items.append(item)
        items.sort { $0.crashedAt > $1.crashedAt }
        for old in items.dropFirst(Self.limit) { removeFile(old) }
        items = Array(items.prefix(Self.limit))
        save()
    }

    public func fileURL(_ item: Item) -> URL? {
        directory?.appendingPathComponent(item.file)
    }

    public func text(_ item: Item) -> String? {
        if let url = fileURL(item) { return try? String(contentsOf: url, encoding: .utf8) }
        return memory[item.id]
    }

    public func remove(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        removeFile(items[index])
        items.remove(at: index)
        save()
    }

    private func removeFile(_ item: Item) {
        memory[item.id] = nil
        if let url = fileURL(item) { try? FileManager.default.removeItem(at: url) }
    }

    private func save() {
        guard let directory, let data = try? RDJSON.encoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    nonisolated static func load(directory: URL) -> [Item] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let items = try? RDJSON.decoder().decode([Item].self, from: data) else { return [] }
        return items.sorted { $0.crashedAt > $1.crashedAt }
    }

    // MARK: 에이전트용

    /// 받은 기록 목록을 텍스트로. `filter`가 있으면 앱·기기·파일 이름에 그 글자가 든 것만.
    public nonisolated static func listText(directory: URL, contains filter: String = "") -> String {
        var items = load(directory: directory)
        guard !items.isEmpty else {
            return "받은 크래시 기록이 없습니다. iPhone RemoteDebug 앱이 비정상 종료된 뒤 다시 열리거나, 사용자가 iPhone 설정의 분석 데이터에서 크래시 파일을 RemoteDebug 앱으로 공유하면 Mac에 들어옵니다."
        }
        if !filter.isEmpty {
            items = items.filter { "\($0.bundleId) \($0.name) \($0.deviceName)".localizedCaseInsensitiveContains(filter) }
        }
        let stamp = Date.ISO8601FormatStyle()
        let lines = items.map { item in
            "\(item.id)  \(item.crashedAt.formatted(stamp))  \(item.bundleId.isEmpty ? item.name : item.bundleId) \(item.appVersion)  [\(item.kind.label)]  \(item.deviceName)  \(directory.appendingPathComponent(item.file).path)"
        }
        return (["# 크래시·피드백 \(items.count)개 (id, 시각, 앱, 종류, 기기, 원문 파일)"] + lines).joined(separator: "\n")
    }

    /// 기록 하나의 원문. `maxBytes`를 넘으면 앞부분만 돌려주고 파일 경로를 알려 준다.
    public nonisolated static func reportText(directory: URL, id: String, maxBytes: Int = 200 << 10) -> String? {
        guard let item = load(directory: directory).first(where: { $0.id == id }) else { return nil }
        let url = directory.appendingPathComponent(item.file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard data.count > maxBytes else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: data.prefix(maxBytes), as: UTF8.self)
            + "\n… (\(data.count)바이트 가운데 앞 \(maxBytes)바이트. 전체는 \(url.path))"
    }
}
