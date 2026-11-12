import Foundation
import Observation
import RDModels

/// iPhone이 보낸 진단 로그(docs/protocol-addenda.md G). 기기마다 `DeviceLogs/<기기 id>.jsonl`에 한 줄씩 덧붙인다.
@MainActor
@Observable
public final class DeviceLogStore {
    public struct Device: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var nodeName: String
        public var entries: [DeviceLogEntry]
        public var lastReceived: Date?
    }

    /// 화면에 들고 있는 기기당 줄 수. 파일은 `maxFileBytes`까지 둔다.
    public nonisolated static let memoryLimit = 5000
    public nonisolated static let maxFileBytes = 4 << 20

    /// 마지막으로 로그를 받은 기기가 앞.
    public private(set) var devices: [Device] = []

    @ObservationIgnored public let directory: URL?
    @ObservationIgnored private let now: @Sendable () -> Date

    /// `directory`가 `nil`이면 파일에 쓰지 않는다(시험·미리보기).
    public init(directory: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        guard let directory else { return }
        devices = Self.load(directory: directory)
    }

    public func device(id: String) -> Device? { devices.first { $0.id == id } }

    public func fileURL(deviceID: String) -> URL? {
        directory?.appendingPathComponent(Self.fileName(deviceID))
    }

    func receive(_ event: DeviceLogEvent) {
        var device = devices.first { $0.id == event.deviceId }
            ?? Device(id: event.deviceId, name: event.deviceName, nodeName: event.nodeName, entries: [])
        device.name = event.deviceName
        device.nodeName = event.nodeName
        device.entries.append(contentsOf: event.entries)
        device.entries.sort { $0.at < $1.at }
        if device.entries.count > Self.memoryLimit { device.entries.removeFirst(device.entries.count - Self.memoryLimit) }
        device.lastReceived = now()
        devices.removeAll { $0.id == device.id }
        devices.insert(device, at: 0)
        append(event)
    }

    /// 한 기기의 로그를 지운다(파일 포함).
    public func clear(deviceID: String) {
        devices.removeAll { $0.id == deviceID }
        if let url = fileURL(deviceID: deviceID) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: 파일

    /// 파일 한 줄: 기기 정보와 로그 한 줄.
    struct Line: Codable {
        var deviceId: String
        var deviceName: String
        var nodeName: String
        var entry: DeviceLogEntry
    }

    nonisolated static func fileName(_ deviceID: String) -> String {
        let safe = deviceID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        return (safe.isEmpty ? "device" : safe) + ".jsonl"
    }

    private func append(_ event: DeviceLogEvent) {
        guard let directory, let url = fileURL(deviceID: event.deviceId) else { return }
        let encoder = RDJSON.encoder()
        var data = Data()
        for entry in event.entries {
            guard let line = try? encoder.encode(Line(deviceId: event.deviceId, deviceName: event.deviceName, nodeName: event.nodeName, entry: entry)) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size + data.count > Self.maxFileBytes {
            Self.trim(url, keepingBytes: Self.maxFileBytes / 2)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 파일 뒤쪽 `keepingBytes`만 남긴다(줄 경계에서).
    private nonisolated static func trim(_ url: URL, keepingBytes: Int) {
        guard let data = try? Data(contentsOf: url), data.count > keepingBytes else { return }
        var tail = data.suffix(keepingBytes)
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: newline)...] }
        try? Data(tail).write(to: url, options: .atomic)
    }

    nonisolated static func readLines(_ url: URL) -> [Line] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = RDJSON.decoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Line.self, from: Data($0)) }
    }

    nonisolated static func load(directory: URL) -> [Device] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var devices: [Device] = []
        for url in files where url.pathExtension == "jsonl" {
            let lines = readLines(url)
            guard let last = lines.last else { continue }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            devices.append(Device(id: last.deviceId, name: last.deviceName, nodeName: last.nodeName,
                                  entries: Array(lines.map(\.entry).sorted { $0.at < $1.at }.suffix(memoryLimit)),
                                  lastReceived: modified))
        }
        return devices.sorted { ($0.lastReceived ?? .distantPast) > ($1.lastReceived ?? .distantPast) }
    }

    /// 에이전트용: 모든 기기의 최근 `limit`줄을 텍스트로(기기마다 머리줄).
    public nonisolated static func recentText(directory: URL, limit: Int, contains filter: String = "") -> String {
        let devices = load(directory: directory)
        guard !devices.isEmpty else { return "받은 iPhone 로그가 없습니다. iPhone 앱이 Mac과 페어링되어 VPN이 연결되면 빌드 목록을 받을 때 로그를 보냅니다." }
        return devices.map { device in
            var entries = device.entries
            if !filter.isEmpty { entries = entries.filter { $0.line.localizedCaseInsensitiveContains(filter) } }
            let shown = entries.suffix(max(1, limit))
            let header = "# \(device.name) (\(device.nodeName)) — \(shown.count)/\(entries.count)줄"
            return ([header] + shown.map(\.line)).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
