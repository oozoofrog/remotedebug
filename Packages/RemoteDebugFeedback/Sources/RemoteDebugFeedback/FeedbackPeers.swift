import Foundation

/// 같은 앱의 다른 기기(Apple Watch 등)가 남긴 로그 한 묶음.
///
/// 기기 사이로 옮기는 일은 앱이 한다(WatchConnectivity 등). 이 패키지는 묶음을 만들고(`capturePeerReport`),
/// 받은 것을 기기마다 하나씩 두었다가(`storePeerReport`) 피드백을 보낼 때 이 기기의 로그와 함께 붙인다.
/// 묶음마다 수집한 시각과 담긴 범위를 적어, 오래된 묶음이 붙었을 때 받는 사람이 알 수 있게 한다.
struct FeedbackPeerReport: Codable, Equatable, Sendable {
    /// 묶음 하나의 크기 한도(바이트). 넘으면 만들 때는 앞쪽 줄을 덜어 내고, 받을 때는 받지 않는다.
    static let maxBytes = 256 << 10
    /// 받아 두는 기기 수. 넘는 기기의 묶음은 받지 않는다.
    static let maxSources = 3
    static let maxLines = 1000
    static let currentFormat = 1

    var format = FeedbackPeerReport.currentFormat
    /// 어느 기기인지 앱이 붙인 이름(`watch`). 영어 소문자, 숫자, `-`만 쓴다.
    var source: String
    /// 기기 종류(`Watch7,1`). 사용자가 붙인 기기 이름이 아니다.
    var device: String
    var system: String
    var appVersion: String
    /// 그 기기가 묶음을 만든 시각(그 기기의 시계).
    var capturedAt: Date
    /// 담긴 첫 줄과 마지막 줄의 시각. 줄이 없으면 없다.
    var firstEntryAt: Date?
    var lastEntryAt: Date?
    /// 한도에 걸려 앞쪽 줄이 빠졌는가.
    var isTruncated: Bool
    var lines: [String]

    static func isValidSource(_ source: String) -> Bool {
        (1...24).contains(source.count)
            && source.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// 줄 맨 앞의 시각(`FeedbackLog`가 붙인 ISO 8601).
    static func entryDate(_ line: String) -> Date? {
        ISO8601DateFormatter.fractional.date(from: String(line.prefix { $0 != " " }))
    }

    /// 줄을 묶음으로 만든다. 크기 한도를 넘으면 앞쪽(오래된) 줄부터 덜어 낸다.
    static func make(source: String, lines: [String], truncated: Bool, device: String, system: String, appVersion: String,
                     now: Date) -> FeedbackPeerReport? {
        guard isValidSource(source) else { return nil }
        var kept = Array(lines.suffix(maxLines))
        var report = FeedbackPeerReport(source: source, device: device, system: system, appVersion: appVersion, capturedAt: now,
                                        isTruncated: truncated || kept.count < lines.count, lines: kept)
        // 머리말 몫을 남기고 줄의 크기를 맞춘다. JSON으로 바꾸면 따옴표와 이스케이프만큼 늘어나므로 넉넉히 뺀다.
        var bytes = kept.reduce(0) { $0 + $1.utf8.count + 8 }
        while bytes > maxBytes / 2, !kept.isEmpty {
            bytes -= kept.removeFirst().utf8.count + 8
            report.isTruncated = true
        }
        report.lines = kept
        report.firstEntryAt = kept.lazy.compactMap(entryDate).first
        report.lastEntryAt = kept.reversed().lazy.compactMap(entryDate).first
        return report
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(self), data.count <= Self.maxBytes else { return nil }
        return data
    }

    /// 다른 기기에서 온 묶음을 읽는다. 크기, 형식, 이름, 줄 수가 한도 안일 때만 받는다.
    static func decode(_ data: Data) -> FeedbackPeerReport? {
        guard data.count <= maxBytes else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard var report = try? decoder.decode(FeedbackPeerReport.self, from: data), report.format == currentFormat,
              isValidSource(report.source), report.lines.count <= maxLines else { return nil }
        report.device = String(report.device.prefix(60))
        report.system = String(report.system.prefix(60))
        report.appVersion = String(report.appVersion.prefix(60))
        return report
    }
}

/// 피드백에 붙일 다른 기기의 묶음 하나와, 그것을 언제 어떻게 받았는지.
struct FeedbackPeerCapture: Codable, Equatable, Sendable {
    var report: FeedbackPeerReport
    /// 이 기기가 묶음을 받은 시각(이 기기의 시계). 지금 요청해 받은 묶음에서는 `capturedAt`과의 차이가 두 기기의 시계 차이에 가깝다.
    var receivedAt: Date
    /// 이번에 보내면서 요청해 받은 것인가. 거짓이면 요청에 답이 없어 앞서 받아 둔 것을 붙였다.
    var isLive = false

    #if DEBUG
    /// Mac으로 가는 기록의 글에 넣는 모양(Debug 빌드 전용). `RemoteDebugFeedback.report`의 다른 줄처럼 기기 언어로 바꾸지 않는다.
    func text(now: Date) -> String {
        let stamp = { (date: Date) in ISO8601DateFormatter.fractional.string(from: date) }
        var text = "기기 기록: \(report.source) (\(report.device), \(report.system), 앱 \(report.appVersion))\n"
        if isLive {
            text += "수집: \(stamp(report.capturedAt)) (보내면서 요청해 받음)\n"
        } else {
            let minutes = max(0, Int(now.timeIntervalSince(receivedAt) / 60))
            text += "수집: \(stamp(report.capturedAt)) (요청에 답이 없어 \(minutes)분 전에 받아 둔 기록을 붙임. 그 뒤의 일은 들어 있지 않음)\n"
        }
        if let first = report.firstEntryAt, let last = report.lastEntryAt {
            text += "범위: \(stamp(first)) ~ \(stamp(last)), \(report.lines.count)줄\(report.isTruncated ? " (앞부분이 한도에 걸려 빠짐)" : "")\n"
        } else {
            text += "범위: \(report.lines.count)줄\(report.isTruncated ? " (앞부분이 한도에 걸려 빠짐)" : "")\n"
        }
        return text + report.lines.joined(separator: "\n")
    }
    #endif

    /// 메일에 붙는 진단 파일에 넣는 모양.
    var json: [String: Any] {
        let stamp = { (date: Date) in ISO8601DateFormatter.fractional.string(from: date) }
        var object: [String: Any] = [
            "source": report.source, "device": report.device, "os": report.system, "appVersion": report.appVersion,
            "capturedAt": stamp(report.capturedAt), "receivedAt": stamp(receivedAt), "live": isLive,
            "truncated": report.isTruncated, "logs": report.lines,
        ]
        if let first = report.firstEntryAt { object["firstEntryAt"] = stamp(first) }
        if let last = report.lastEntryAt { object["lastEntryAt"] = stamp(last) }
        return object
    }
}

/// 받은 묶음을 기기 이름마다 파일 하나로 둔다. 새로 받으면 그 기기의 앞선 파일을 덮어쓴다.
struct FeedbackPeerStore {
    static let folderName = "peers"
    let directory: URL

    init(storage: URL) { directory = storage.appendingPathComponent(Self.folderName, isDirectory: true) }

    private func file(_ source: String) -> URL { directory.appendingPathComponent("\(source).json") }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    /// 받아 둔 것보다 앞서 수집한 묶음과, 기기 수 한도를 넘는 새 기기의 묶음은 두지 않는다.
    @discardableResult
    func save(_ report: FeedbackPeerReport, receivedAt: Date) -> Bool {
        let stored = all()
        if let old = stored.first(where: { $0.report.source == report.source }) {
            guard report.capturedAt >= old.report.capturedAt else { return false }
        } else if stored.count >= FeedbackPeerReport.maxSources {
            return false
        }
        guard let data = try? Self.encoder.encode(FeedbackPeerCapture(report: report, receivedAt: receivedAt)) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: file(report.source), options: .atomic)) != nil
    }

    /// 받아 둔 묶음(기기 이름 순).
    func all() -> [FeedbackPeerCapture] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? Self.decoder.decode(FeedbackPeerCapture.self, from: $0) } }
    }

    static func remove(in storage: URL) {
        try? FileManager.default.removeItem(at: FeedbackPeerStore(storage: storage).directory)
    }
}

public extension RemoteDebugFeedback {
    /// 다른 기기에 지금 요청해 묶음을 받아 오는 일. 앱이 자기 전송 수단으로 구현한다.
    typealias PeerRequest = @Sendable () async -> [Data]

    /// 이 기기의 로그를 다른 기기로 보낼 묶음으로 만든다(Apple Watch 쪽에서 부른다).
    /// `source`는 기기를 가리키는 이름이다(`watch`. 영어 소문자, 숫자, `-`, 24자까지).
    /// 지금 로그를 남겨도 되는 상태가 아니면(배포 빌드에서 이 기기가 동의를 받기 전) `nil`이다.
    static func capturePeerReport(source: String) async -> Data? {
        guard isRecordingAllowed, FeedbackPeerReport.isValidSource(source) else { return nil }
        return await Task.detached {
            let (lines, truncated) = FeedbackLog.shared.collectAll()
            return FeedbackPeerReport.make(source: source, lines: lines, truncated: truncated, device: deviceModel,
                                           system: systemSummary, appVersion: appVersion, now: Date())?.encoded()
        }.value
    }

    /// 다른 기기에서 온 묶음을 받아 둔다(iPhone 쪽에서 부른다). 기기 이름마다 가장 최근에 수집한 하나만 남는다.
    /// 받아 두었으면 `true`. 로그를 남겨도 되는 상태가 아니거나, 읽을 수 없거나, 한도를 넘으면 두지 않는다.
    @discardableResult
    static func storePeerReport(_ data: Data) -> Bool {
        storePeerReport(data, receivedAt: Date())
    }

    /// 피드백을 보낼 때 다른 기기에 묶음을 요청하는 방법을 정한다. 정해 두면 로그를 붙여 보낼 때마다 불러서
    /// 몇 초 안에 온 묶음은 "지금 받은 것"으로 붙이고, 답이 없으면 앞서 받아 둔 것을 그렇게 적어서 붙인다.
    static func setPeerRequest(_ request: PeerRequest?) {
        withState { $0.peerRequest = request }
    }
}

extension RemoteDebugFeedback {
    /// 지금 요청을 기다리는 시간(초).
    static let peerRequestTimeout: TimeInterval = 3

    static func storePeerReport(_ data: Data, receivedAt: Date) -> Bool {
        guard isRecordingAllowed, let storage = withState({ $0.storage }), let report = FeedbackPeerReport.decode(data) else { return false }
        return FeedbackPeerStore(storage: storage).save(report, receivedAt: receivedAt)
    }

    /// 피드백에 붙일 다른 기기의 묶음을 모은다. 요청할 방법이 있으면 먼저 요청하고 `timeout`초까지 기다린다.
    /// 늦게 온 답은 이번에는 못 쓰지만 받아 두어 다음에 쓴다.
    static func gatherPeers(timeout: TimeInterval = peerRequestTimeout) async -> [FeedbackPeerCapture] {
        guard isRecordingAllowed, let storage = withState({ $0.storage }) else { return [] }
        var live: Set<String> = []
        if let request = withState({ $0.peerRequest }) {
            let answered = await firstResult(of: request, within: timeout) { late in
                for data in late { _ = storePeerReport(data, receivedAt: Date()) }
            }
            for data in answered ?? [] {
                guard let report = FeedbackPeerReport.decode(data), storePeerReport(data, receivedAt: Date()) else { continue }
                live.insert(report.source)
            }
        }
        // 기다리는 사이에 사용자가 동의를 거두었으면 붙이지 않는다.
        guard isRecordingAllowed else { return [] }
        return FeedbackPeerStore(storage: storage).all().map {
            var capture = $0
            capture.isLive = live.contains($0.report.source)
            return capture
        }
    }

    /// `work`의 결과를 `seconds`초까지 기다린다. 그 안에 끝나지 않으면 `nil`을 돌려주고, 나중에 끝난 결과는 `late`로 넘긴다.
    /// `work`가 취소를 따르지 않아도 기다림이 길어지지 않는다.
    static func firstResult<T: Sendable>(of work: @escaping @Sendable () async -> T, within seconds: TimeInterval,
                                         late: @escaping @Sendable (T) -> Void) async -> T? {
        let claim = Claim()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task {
                let result = await work()
                if claim.take() { continuation.resume(returning: result) } else { late(result) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if claim.take() { continuation.resume(returning: nil) }
            }
        }
    }

    /// 둘 가운데 먼저 온 쪽만 답하게 한다.
    private final class Claim: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false

        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }
}
