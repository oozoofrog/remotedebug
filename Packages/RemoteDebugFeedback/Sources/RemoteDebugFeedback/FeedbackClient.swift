import Foundation

/// Mac에 보내는 기록 하나. RemoteDebug 프로토콜(docs/protocol-addenda.md L.1)의 본문과 같다.
public struct FeedbackReport: Codable, Equatable, Sendable {
    public var kind: String
    public var name: String
    public var bundleId: String
    public var appVersion: String
    public var crashedAt: String
    public var text: String
    /// 사진 한 장(JPEG나 PNG)의 base64. 옛 방식이고, 이 패키지는 `attachments`로 보낸다.
    public var image: String?
    /// 사용자가 붙인 사진과 파일. 피드백에만 붙인다. 옛 Mac 앱은 이 필드를 읽지 않고 글만 받는다.
    public var attachments: [Attachment]?

    public struct Attachment: Codable, Equatable, Sendable {
        public var name: String
        /// MIME 종류.
        public var type: String
        public var base64: String
    }
}

/// 기록을 폴더에 쌓아 두고 Mac의 `POST /v1/crashes`로 보낸다. 보내지 못한 기록은 남겨 두었다가 다음에 다시 보낸다.
public actor FeedbackClient {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// 쌓아 두는 기록 수. 넘으면 오래된 것부터 지운다.
    public static let queueLimit = 30
    /// 쌓아 두는 기록을 모두 합친 크기 한도(바이트). 넘으면 오래된 것부터 지운다. 가장 큰 기록 네 개 분량이다.
    public static let queueByteLimit = 16 << 20
    /// 코어가 받는 `text` 크기 한도(바이트).
    public static let maxTextBytes = 1536 << 10
    /// 코어가 받는 본문 크기 한도(바이트). 넘는 기록은 보내지도 쌓지도 않는다.
    public static let maxBodyBytes = 4 << 20

    let endpoint: URL
    let directory: URL
    let send: Send

    public init(endpoint: URL, directory: URL, send: @escaping Send = { try await URLSession.shared.data(for: $0) }) {
        self.endpoint = endpoint
        self.directory = directory
        self.send = send
    }

    /// `rd-mac-….ts.net`이나 `https://rd-mac-….ts.net` 같은 글자에서 보낼 주소를 만든다. 틀리면 `nil`.
    public static func endpoint(host: String) -> URL? {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("https://") { text.removeFirst("https://".count) }
        while text.hasSuffix("/") || text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, text.count <= 253,
              text.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "." }),
              text.contains(".") else { return nil }
        return URL(string: "https://\(text)/v1/crashes")
    }

    /// 쌓지 않고 한 번 보내 본다. Mac이 받았으면 `true`.
    public func trySend(_ report: FeedbackReport) async -> Bool {
        guard let body = try? JSONEncoder().encode(report), body.count <= Self.maxBodyBytes else { return false }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await send(request), let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// 기록을 쌓고 바로 보내 본다. 이번에 Mac이 받았으면 `true`.
    @discardableResult
    public func submit(_ report: FeedbackReport) async -> Bool {
        guard !report.text.isEmpty, report.text.utf8.count <= Self.maxTextBytes,
              let data = try? JSONEncoder().encode(report), data.count <= Self.maxBodyBytes else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json")
        try? data.write(to: file, options: .atomic)
        prune()
        await flush()
        return !fm.fileExists(atPath: file.path)
    }

    /// 쌓인 기록을 오래된 것부터 보낸다. Mac에 닿지 않으면 멈추고 남겨 둔다.
    public func flush() async {
        for file in pending() {
            guard let body = try? Data(contentsOf: file) else { continue }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let (_, response) = try? await send(request), let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200..<300, 400, 413: try? FileManager.default.removeItem(at: file) // 받았거나, 다시 보내도 받지 않을 본문
            default: return // 페어링 안 됨(403) 등은 나중에 다시
            }
        }
    }

    /// 쌓인 기록이 수나 크기 한도를 넘으면 오래된 것부터 지운다. 방금 쌓은 하나는 남긴다.
    func prune() {
        let fm = FileManager.default
        var files = pending()
        for old in files.dropLast(Self.queueLimit) { try? fm.removeItem(at: old) }
        files = Array(files.suffix(Self.queueLimit))
        var sizes = files.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        var total = sizes.reduce(0, +)
        while total > Self.queueByteLimit, files.count > 1 {
            try? fm.removeItem(at: files.removeFirst())
            total -= sizes.removeFirst()
        }
    }

    /// 아직 보내지 못한 기록 파일(오래된 것이 앞).
    public func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
