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
        /// 옛 클라이언트가 피드백에 붙인 사진 파일 이름. 없으면 `nil`.
        public var imageFile: String?
        /// 사용자가 피드백에 붙인 사진과 파일. 없으면 `nil`.
        public var attachments: [Attached]?
        /// 확인 목록에 사용자가 고른 답(개발 빌드의 피드백). 원문 파일 끝에도 글로 적는다. 없으면 `nil`.
        public var checks: [CrashReport.Check]?

        /// 목록에 보일 이름: 번들 ID의 마지막 마디, 없으면 파일 이름.
        public var title: String {
            bundleId.split(separator: ".").last.map(String.init) ?? name
        }
    }

    /// 기록 옆에 저장한 첨부 하나.
    public struct Attached: Codable, Hashable, Sendable {
        /// 보낸 쪽이 붙인 이름(고친 것).
        public var name: String
        /// `CrashLogs/` 안의 파일 이름.
        public var file: String
        public var bytes: Int
    }

    /// 보관하는 기록 수. 넘으면 이 Mac이 받은 시각이 오래된 것부터 지운다.
    public nonisolated static let limit = 200
    /// 기기 하나에서 보관하는 기록 수. 넘으면 그 기기의 기록 가운데 받은 시각이 오래된 것부터 지운다.
    public nonisolated static let perDeviceLimit = 50

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
    /// 받은 시각은 코어가 알려 준 값(`event.receivedAt`), 없으면 지금이다.
    func receive(_ event: DeviceCrashEvent) {
        let report = event.report
        guard !items.contains(where: { $0.id == report.id }) else { return }
        // 첨부는 기록 id와 순번을 앞에 붙인 이름으로 같은 폴더에 둔다. 이름은 경로 마디가 없게 고친다.
        let attached: [Attached] = directory == nil ? [] : report.attachments.prefix(CrashReport.maxAttachments).enumerated().map { index, attachment -> Attached in
            let name = CrashReport.Attachment.safeName(attachment.name)
            return Attached(name: name, file: "\(report.id)-\(index + 1)-\(name)", bytes: attachment.data.count)
        }
        var item = Item(id: report.id, kind: report.kind, name: report.name, bundleId: report.bundleId,
                        appVersion: report.appVersion, crashedAt: report.crashedAt, receivedAt: event.receivedAt ?? now(),
                        deviceId: event.deviceId, deviceName: event.deviceName,
                        file: "\(report.id).\(report.kind.fileExtension)",
                        imageFile: report.image == nil || directory == nil ? nil : "\(report.id).\(report.image?.first == 0x89 ? "png" : "jpg")")
        item.attachments = attached.isEmpty ? nil : attached
        item.checks = report.checks.isEmpty ? nil : report.checks
        // 확인 목록의 답은 원문 끝에 붙여, 화면과 에이전트가 같은 글에서 읽는다.
        let stored = report.checks.isEmpty ? report.text : report.text + "\n---\n" + CrashReport.checksText(report.checks) + "\n"
        if let url = fileURL(item) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(stored.utf8).write(to: url, options: .atomic)
            if let image = report.image, let imageURL = imageURL(item) { try? image.write(to: imageURL, options: .atomic) }
            for (stored, attachment) in zip(attached, report.attachments) {
                // 실행 권한 없이 쓴다. 앱은 이 파일을 열거나 실행하지 않고 Finder에서 보여 주기만 한다.
                guard let target = attachmentURL(stored) else { continue }
                try? attachment.data.write(to: target, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
        } else {
            memory[item.id] = stored
        }
        items.append(item)
        // 남길 것은 이 Mac이 받은 시각으로 고른다(보낸 쪽이 적은 `crashedAt`이 아니라).
        let kept = Self.retained(items)
        for old in items where !kept.contains(old.id) { removeFile(old) }
        items = items.filter { kept.contains($0.id) }.sorted { $0.crashedAt > $1.crashedAt }
        save()
    }

    /// 남길 기록의 id: 기기마다 받은 시각이 최근인 `perDeviceLimit`개, 그 가운데 전체에서 받은 시각이 최근인 `limit`개.
    nonisolated static func retained(_ items: [Item]) -> Set<String> {
        let byReceipt = items.sorted { $0.receivedAt != $1.receivedAt ? $0.receivedAt > $1.receivedAt : $0.id < $1.id }
        var perDevice: [String: Int] = [:]
        var kept: [String] = []
        for item in byReceipt {
            let count = perDevice[item.deviceId, default: 0]
            guard count < perDeviceLimit else { continue }
            perDevice[item.deviceId] = count + 1
            kept.append(item.id)
            if kept.count == limit { break }
        }
        return Set(kept)
    }

    public func fileURL(_ item: Item) -> URL? {
        directory?.appendingPathComponent(item.file)
    }

    public func imageURL(_ item: Item) -> URL? {
        guard let name = item.imageFile else { return nil }
        return directory?.appendingPathComponent(name)
    }

    /// 첨부 파일의 위치. 저장된 이름이 폴더 밖을 가리키면 `nil`.
    public func attachmentURL(_ attached: Attached) -> URL? {
        directory.flatMap { Self.attachmentURL(attached, in: $0) }
    }

    nonisolated static func attachmentURL(_ attached: Attached, in directory: URL) -> URL? {
        guard !attached.file.isEmpty, !attached.file.contains("/"), !attached.file.hasPrefix(".") else { return nil }
        return directory.appendingPathComponent(attached.file)
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
        if let url = imageURL(item) { try? FileManager.default.removeItem(at: url) }
        for url in (item.attachments ?? []).compactMap(attachmentURL) { try? FileManager.default.removeItem(at: url) }
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
    /// `kind`가 "feedback"이면 사람이 쓴 피드백만, "crash"면 크래시 기록만.
    public nonisolated static func listText(directory: URL, contains filter: String = "", kind: String = "") -> String {
        var items = load(directory: directory)
        switch kind {
        case "feedback": items = items.filter { $0.kind == .feedback }
        case "crash": items = items.filter { $0.kind != .feedback }
        default: break
        }
        guard !items.isEmpty else {
            return "받은 크래시 기록이 없습니다. iPhone RemoteDebug 앱이 비정상 종료된 뒤 다시 열리거나, 사용자가 iPhone 설정의 분석 데이터에서 크래시 파일을 RemoteDebug 앱으로 공유하면 Mac에 들어옵니다."
        }
        if !filter.isEmpty {
            items = items.filter { "\($0.bundleId) \($0.name) \($0.deviceName)".localizedCaseInsensitiveContains(filter) }
        }
        let stamp = Date.ISO8601FormatStyle()
        let lines = items.map { item in
            let attached = (item.attachments ?? []).compactMap { one in
                attachmentURL(one, in: directory).map { "\n    첨부: \($0.path) (\(one.bytes)바이트)" }
            }.joined() + (item.checks.map { checks in
                "\n    확인 목록의 답: \(checks.filter { !$0.answer.isEmpty }.count)/\(checks.count)개 답함(원문 끝에 있다)"
            } ?? "")
            return "\(item.id)  \(item.crashedAt.formatted(stamp))  \(item.bundleId.isEmpty ? item.name : item.bundleId) \(item.appVersion)  [\(item.kind.label)]  \(item.deviceName)  \(directory.appendingPathComponent(item.file).path)\(item.imageFile.map { "  사진: " + directory.appendingPathComponent($0).path } ?? "")" + attached
        }
        return (["# 크래시·피드백 \(items.count)개 (id, 시각, 앱, 종류, 기기, 원문 파일. 아랫줄의 `첨부:`는 사용자가 붙인 사진·파일)"] + lines).joined(separator: "\n")
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
