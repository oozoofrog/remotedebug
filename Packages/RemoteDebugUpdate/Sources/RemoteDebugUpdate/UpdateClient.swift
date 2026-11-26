#if DEBUG
import Foundation

// 개발 빌드에만 컴파일되는 업데이트 클라이언트·비교·딥링크 로직.
// 배포 빌드에는 이 파일의 어떤 코드나 문자열도 들어가지 않는다.

/// 현재 실행 중인 빌드의 버전·빌드 번호·처음 실행 시각.
struct CurrentBuild: Equatable, Sendable {
    var version: String
    var buildNumber: String
    /// 이 바이너리를 처음 실행한 시각(설치 시각 대신 쓴다).
    var installedAt: Date?

    /// `published`가 현재 설치된 빌드보다 새 빌드인지 판정한다.
    ///
    /// 1. `version`을 숫자 순서로 비교해 더 높으면 새 빌드, 더 낮으면 아님.
    /// 2. `version`이 같으면 `buildNumber`를 숫자 순서로 비교해 더 높으면 새 빌드, 더 낮으면 아님.
    /// 3. 둘 다 같으면(Debug 빌드에서 번호를 올리지 않은 경우) 게시 시각이 이 빌드의 처음 실행 시각보다 늦으면 새 빌드.
    func isNewer(_ published: UpdateInfo) -> Bool {
        let versionOrder = published.version.compare(version, options: .numeric)
        if versionOrder == .orderedDescending { return true }
        if versionOrder == .orderedAscending { return false }

        let buildOrder = published.buildNumber.compare(buildNumber, options: .numeric)
        if buildOrder == .orderedDescending { return true }
        if buildOrder == .orderedAscending { return false }

        if let installedAt {
            return published.publishedAt > installedAt
        }
        return false
    }

    /// 번들 정보와 바이너리 지문을 읽어 `CurrentBuild`를 만든다.
    /// `UserDefaults`를 쓰지 않고 앱 데이터 폴더의 JSON 파일에만 기록해 개인정보 매니페스트 요구 API를 건드리지 않는다.
    static func read(bundle: Bundle, storage: URL?, now: Date = Date()) -> CurrentBuild {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let buildNumber = info["CFBundleVersion"] as? String ?? ""
        let installedAt = firstLaunchDate(of: bundle, version: version, buildNumber: buildNumber, storage: storage, now: now)
        return CurrentBuild(version: version, buildNumber: buildNumber, installedAt: installedAt)
    }

    private struct Record: Codable {
        var fingerprint: String
        var firstLaunch: Date
    }

    private static func firstLaunchDate(of bundle: Bundle, version: String, buildNumber: String,
                                        storage: URL?, now: Date) -> Date? {
        guard let executable = bundle.executableURL,
              let values = try? executable.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        // fileSize와 버전·빌드 번호로 지문을 만든다(contentModificationDateKey는 Required Reason API를 피하려고 쓰지 않는다).
        let fingerprint = "\(version)|\(buildNumber)|\(size)"
        guard let storage else { return now }
        let file = storage.appendingPathComponent("installed.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Record.self, from: data),
           saved.fingerprint == fingerprint {
            return saved.firstLaunch
        }
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(Record(fingerprint: fingerprint, firstLaunch: now)) {
            try? encoded.write(to: file, options: .atomic)
        }
        return now
    }
}

/// RemoteDebug iPhone 앱으로 업데이트를 넘기는 URL(`remotedebug://update?bundleId=…`).
enum UpdateDeepLink {
    static let scheme = "remotedebug"

    static var probeURL: URL? {
        URL(string: "\(scheme)://update")
    }

    static func url(bundleId: String, buildId: String? = nil) -> URL? {
        guard isValidBundleID(bundleId) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "update"
        var items = [URLQueryItem(name: "bundleId", value: bundleId)]
        if let buildId, !buildId.isEmpty {
            items.append(URLQueryItem(name: "buildId", value: buildId))
        }
        components.queryItems = items
        return components.url
    }

    static func isValidBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && !value.hasPrefix(".") &&
            value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 }
    }
}

/// Mac 호스트에서 이 앱의 최신 게시 빌드 정보를 조회한다.
struct UpdateClient: Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let maxResponseBytes = 4 << 20

    let baseURL: URL
    let send: Send

    init?(host: String, send: @escaping Send = { try await URLSession.shared.data(for: $0) }) {
        guard let url = Self.baseURL(host: host) else { return nil }
        self.baseURL = url
        self.send = send
    }

    /// `rd-mac-….ts.net`이나 `https://rd-mac-….ts.net`에서 기본 주소를 만든다.
    static func baseURL(host: String) -> URL? {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("https://") { text.removeFirst("https://".count) }
        while text.hasSuffix("/") || text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, text.count <= 253,
              text.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "." }),
              text.contains(".") else { return nil }
        return URL(string: "https://\(text)")
    }

    /// 먼저 경량 경로 `GET /v1/updates/<bundleId>`를 묻고, 404면(이전 Mac 앱) `GET /v1/builds`로 내려간다.
    func check(bundleID: String, current: CurrentBuild) async -> UpdateStatus {
        guard UpdateDeepLink.isValidBundleID(bundleID) else { return .unavailable(.missingBundleID) }
        guard let updateURL = URL(string: "/v1/updates/\(bundleID)", relativeTo: baseURL)?.absoluteURL else {
            return .unavailable(.invalidResponse)
        }
        var request = URLRequest(url: updateURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await send(request), let http = response as? HTTPURLResponse else {
            return .unavailable(.unreachable)
        }

        let latest: UpdateInfo?
        switch http.statusCode {
        case 200:
            guard data.count <= Self.maxResponseBytes, let parsed = Self.parseUpdateResponse(data, bundleID: bundleID) else {
                return .unavailable(.invalidResponse)
            }
            latest = parsed.latest
        case 404:
            // 이전 버전 Mac 앱 호환: 전체 빌드 목록에서 이 앱의 최신 빌드를 고른다.
            switch await fetchFromBuildsList(bundleID: bundleID) {
            case .found(let info): latest = info
            case .failed(let reason): return .unavailable(reason)
            }
        default:
            return .unavailable(.unreachable)
        }

        guard let latest else { return .upToDate(nil) }
        return current.isNewer(latest) ? .available(latest) : .upToDate(latest)
    }

    private enum FetchResult {
        case found(UpdateInfo?)
        case failed(UpdateUnavailableReason)
    }

    private func fetchFromBuildsList(bundleID: String) async -> FetchResult {
        guard let buildsURL = URL(string: "/v1/builds", relativeTo: baseURL)?.absoluteURL else {
            return .failed(.invalidResponse)
        }
        var request = URLRequest(url: buildsURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await send(request), let http = response as? HTTPURLResponse else {
            return .failed(.unreachable)
        }
        guard http.statusCode == 200 else { return .failed(.unreachable) }
        guard data.count <= Self.maxResponseBytes, let list = Self.parseBuildsResponse(data, bundleID: bundleID) else {
            return .failed(.invalidResponse)
        }
        return .found(list.max(by: { $0.publishedAt < $1.publishedAt }))
    }

    // MARK: JSON 파싱

    private struct UpdateEnvelope: Decodable {
        var bundleId: String
        var latest: WireUpdate?
    }

    private struct WireUpdate: Decodable {
        var id: String
        var bundleId: String
        var displayName: String
        var version: String
        var buildNumber: String
        var minOS: String
        var publishedAt: String
        var releaseNotes: String?
        var ipaSize: Int64?
    }

    private struct BuildsEnvelope: Decodable {
        var builds: [WireBuild]
    }

    private struct WireBuild: Decodable {
        struct IPA: Decodable { var size: Int64? }
        var id: String
        var bundleId: String
        var displayName: String
        var version: String
        var buildNumber: String
        var minOS: String
        var publishedAt: String
        var releaseNotes: String?
        var ipa: IPA?
    }

    static func parseUpdateResponse(_ data: Data, bundleID: String) -> (bundleId: String, latest: UpdateInfo?)? {
        guard let envelope = try? JSONDecoder().decode(UpdateEnvelope.self, from: data),
              envelope.bundleId == bundleID else { return nil }
        guard let wire = envelope.latest else { return (envelope.bundleId, nil) }
        guard wire.bundleId == bundleID, let date = parseDate(wire.publishedAt) else { return nil }
        return (envelope.bundleId, UpdateInfo(
            buildId: wire.id,
            bundleId: wire.bundleId,
            displayName: wire.displayName,
            version: wire.version,
            buildNumber: wire.buildNumber,
            minOS: wire.minOS,
            publishedAt: date,
            releaseNotes: cleanNotes(wire.releaseNotes),
            ipaSize: wire.ipaSize
        ))
    }

    static func parseBuildsResponse(_ data: Data, bundleID: String) -> [UpdateInfo]? {
        guard let envelope = try? JSONDecoder().decode(BuildsEnvelope.self, from: data) else { return nil }
        return envelope.builds.compactMap { wire in
            guard wire.bundleId == bundleID, let date = parseDate(wire.publishedAt) else { return nil }
            return UpdateInfo(
                buildId: wire.id,
                bundleId: wire.bundleId,
                displayName: wire.displayName,
                version: wire.version,
                buildNumber: wire.buildNumber,
                minOS: wire.minOS,
                publishedAt: date,
                releaseNotes: cleanNotes(wire.releaseNotes),
                ipaSize: wire.ipa?.size
            )
        }
    }

    private static func cleanNotes(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
#endif
