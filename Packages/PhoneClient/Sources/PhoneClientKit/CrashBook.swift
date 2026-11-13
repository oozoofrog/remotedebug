import Foundation
import Observation
import RDModels

/// 이 iPhone에 모은 크래시 기록. 이 앱 자신의 크래시(MetricKit)와 사용자가 넘긴 다른 앱의 .ips 파일을 파일로 남기고,
/// Mac에 보냈는지 기억한다.
@MainActor
@Observable
public final class CrashBook {
    public struct Item: Codable, Identifiable, Hashable, Sendable {
        public var id: String
        public var kind: CrashReport.Kind
        public var name: String
        public var bundleId: String
        public var appVersion: String
        public var crashedAt: Date
        public var sent: Bool

        /// 목록에 보일 이름: 번들 ID의 마지막 마디, 없으면 파일 이름.
        public var title: String {
            bundleId.split(separator: ".").last.map(String.init) ?? name
        }
    }

    /// 보관하는 기록 수. 넘으면 오래된 것부터 지운다.
    public nonisolated static let limit = 50

    /// 최근 크래시가 앞.
    public private(set) var items: [Item] = []

    @ObservationIgnored private let directory: URL?

    /// `directory`가 `nil`이면 메모리에만 둔다(시험·미리보기).
    public init(directory: URL? = nil) {
        self.directory = directory
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let saved = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = saved
    }

    /// 앱 데이터 폴더의 기본 위치.
    public nonisolated static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CrashReports", isDirectory: true)
    }

    public var unsent: [Item] { items.filter { !$0.sent } }

    /// 기록을 더한다. 이미 있는 기록이면 `nil`.
    @discardableResult
    public func add(_ report: CrashReport) -> Item? {
        let item = Item(id: report.id, kind: report.kind, name: report.name, bundleId: report.bundleId,
                        appVersion: report.appVersion, crashedAt: report.crashedAt, sent: false)
        guard !items.contains(where: { $0.id == item.id }) else { return nil }
        if let url = fileURL(item) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(report.text.utf8).write(to: url, options: .atomic)
            if let image = report.image, let imageURL = imageURL(item) { try? image.write(to: imageURL, options: .atomic) }
        } else {
            memory[item.id] = report.text
            images[item.id] = report.image
        }
        items.append(item)
        items.sort { $0.crashedAt > $1.crashedAt }
        for old in items.dropFirst(Self.limit) { removeFile(old) }
        items = Array(items.prefix(Self.limit))
        save()
        return item
    }

    /// 공유하거나 열 파일. 메모리에만 두면 `nil`.
    public func fileURL(_ item: Item) -> URL? {
        directory?.appendingPathComponent("\(item.id).\(item.kind.fileExtension)")
    }

    /// 피드백에 붙인 화면 사진을 두는 파일.
    func imageURL(_ item: Item) -> URL? {
        directory?.appendingPathComponent("\(item.id).image")
    }

    public func image(_ item: Item) -> Data? {
        if let url = imageURL(item) { return try? Data(contentsOf: url) }
        return images[item.id]
    }

    public func text(_ item: Item) -> String? {
        if let url = fileURL(item) { return try? String(contentsOf: url, encoding: .utf8) }
        return memory[item.id]
    }

    public func report(_ item: Item) -> CrashReport? {
        text(item).map {
            CrashReport(kind: item.kind, name: item.name, bundleId: item.bundleId, appVersion: item.appVersion, crashedAt: item.crashedAt, text: $0, image: image(item))
        }
    }

    public func markSent(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].sent = true
        save()
    }

    public func remove(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        removeFile(items[index])
        items.remove(at: index)
        save()
    }

    @ObservationIgnored private var memory: [String: String] = [:]
    @ObservationIgnored private var images: [String: Data] = [:]

    private func removeFile(_ item: Item) {
        memory[item.id] = nil
        images[item.id] = nil
        if let url = fileURL(item) { try? FileManager.default.removeItem(at: url) }
        if let url = imageURL(item) { try? FileManager.default.removeItem(at: url) }
    }

    private func save() {
        guard let directory, let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}
