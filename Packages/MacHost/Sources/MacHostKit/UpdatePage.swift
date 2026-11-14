import Foundation
import Observation
import RDModels

/// `rd_update_page_set` 입력(docs/protocol-addenda.md I).
public struct UpdatePageConfig: Codable, Sendable, Hashable {
    public struct Build: Codable, Sendable, Hashable {
        public var bundleId: String
        public var title: String
        public var version: String
        public var buildNumber: String
        public var minOS: String
        public var size: Int64
        public var sha256: String
        public var publishedAt: String
        public var ipaPath: String
        public var icon: Data?
    }

    public var listen: String
    public var publicURL: String
    public var page: Build?
}

/// 루프백 업데이트 페이지 서버. 실제 구현은 Go 코어(`rd_update_page_set`)다.
public protocol UpdatePageServing: Sendable {
    /// 적용하고 듣는 주소(`127.0.0.1:P`)를 돌려준다.
    func apply(_ config: UpdatePageConfig) async throws -> String
}

/// 이 Mac의 공식 Tailscale 명령.
public protocol TailscaleControlling: Sendable {
    /// 명령을 찾지 못하면 nil.
    func run(_ arguments: [String]) async -> (status: Int32, output: String)?
}

/// `/Applications/Tailscale.app`이나 PATH의 `tailscale`을 실행한다.
public struct TailscaleCLI: TailscaleControlling {
    public static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    public init() {}

    public func run(_ arguments: [String]) async -> (status: Int32, output: String)? {
        guard let path = Self.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            // Tailscale.app 실행 파일은 터미널 밖(TERM 없음)에서 띄우면 CLI가 아니라 GUI로 시작하려 한다.
            var environment = ProcessInfo.processInfo.environment
            environment["TAILSCALE_BE_CLI"] = "1"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (127, error.localizedDescription))
                return
            }
            // 출력이 파이프 버퍼보다 커도 막히지 않게 끝까지 읽은 뒤 종료를 기다린다.
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

/// RemoteDebug iPhone 앱 자신의 업데이트를 공식 Tailscale로 내주는 페이지.
///
/// iOS는 앱을 바꾸는 동안 그 앱의 VPN(패킷 터널)을 멈춘다. 그래서 RemoteDebug 앱은 자기 VPN으로 자기 업데이트를 받을 수 없다.
/// Mac 앱이 루프백에 페이지를 열고, 공식 Tailscale의 `tailscale serve`가 비밀 경로를 그 페이지로 넘긴다.
/// 페이지는 Mac에 게시된 가장 최근 iPhone 앱 빌드를 자동으로 내준다.
@MainActor
@Observable
public final class UpdatePageModel {
    public enum TailscaleState: Sendable, Hashable {
        case checking
        /// 이 Mac에 공식 Tailscale 앱이 없다.
        case missing
        /// 앱은 있지만 연결돼 있지 않다(상태 문구).
        case notConnected(String)
        /// 연결됨. 이 Mac의 MagicDNS 이름.
        case connected(dnsName: String)
    }

    struct Settings: Codable, Sendable {
        var path: String
        var port: Int
    }

    public private(set) var tailscale: TailscaleState = .checking
    /// `tailscale serve`가 이 페이지로 넘기고 있다.
    public private(set) var isRouted = false
    /// iPhone이 Safari로 여는 주소. 공식 Tailscale 연결과 경로가 모두 준비돼야 있다.
    public private(set) var pageURL: URL?
    /// 페이지가 내주는 빌드.
    public private(set) var servedBuild: BuildDescriptor?
    public private(set) var isWorking = false
    public var lastError: String?

    public let phoneBundleID: String
    @ObservationIgnored private let server: any UpdatePageServing
    @ObservationIgnored private let cli: any TailscaleControlling
    @ObservationIgnored private let file: JSONFile<Settings>
    @ObservationIgnored private var settings: Settings?
    @ObservationIgnored private var page: UpdatePageConfig.Build?
    @ObservationIgnored private var monitor: Task<Void, Never>?

    public init(root: URL, server: any UpdatePageServing, cli: any TailscaleControlling = TailscaleCLI(),
                phoneBundleID: String = "com.oozoofrog.app.RemoteDebugPhone") {
        self.server = server
        self.cli = cli
        self.phoneBundleID = phoneBundleID
        self.file = JSONFile(url: root.appendingPathComponent("update-page.json"))
    }

    /// 경로 이름(`/remotedebug-update-<32자>`). 처음 부를 때 만든다.
    public var routePath: String? { settings?.path }
    public var localAddress: String? { settings.map { "127.0.0.1:\($0.port)" } }

    /// 페이지 서버를 열고 공식 Tailscale 상태를 읽는다.
    public func start() async {
        if settings == nil {
            settings = (try? file.load()) ?? Settings(path: "/remotedebug-update-" + Self.randomHex(16), port: 0)
        }
        await apply()
        await refresh()
    }

    /// 공식 Tailscale 연결이나 `tailscale serve` 설정이 앱 밖에서 바뀌어도 따라가게 주기적으로 다시 읽는다.
    public func startMonitoring(every interval: Duration = .seconds(60)) {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    /// 게시된 빌드가 바뀌었다. 가장 최근 iPhone 앱 빌드를 페이지에 올린다.
    public func sync(builds: [LibraryBuild], ipaURL: (String) -> URL) async {
        // 다른 팀으로 서명한 RemoteDebug는 번들 ID 앞부분이 다르다(`<앞부분>.RemoteDebugPhone`).
        let newest = builds.map(\.descriptor)
            .filter { $0.bundleId == phoneBundleID || $0.bundleId.hasSuffix(".RemoteDebugPhone") }
            .max { $0.publishedAt < $1.publishedAt }
        guard newest?.id != servedBuild?.id || (newest == nil) != (page == nil) else { return }
        servedBuild = newest
        page = newest.map { d in
            UpdatePageConfig.Build(bundleId: d.bundleId, title: d.displayName, version: d.version, buildNumber: d.buildNumber,
                                   minOS: d.minOS, size: d.ipa.size, sha256: d.ipa.sha256, publishedAt: RDTimestamp.string(d.publishedAt),
                                   ipaPath: ipaURL(d.id).path, icon: d.icon)
        }
        if settings != nil { await apply() }
    }

    /// 공식 Tailscale 연결과 경로를 다시 읽는다.
    public func refresh() async {
        guard let status = await cli.run(["status", "--json"]) else {
            tailscale = .missing
            isRouted = false
            return await apply()
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(status.output.utf8))) as? [String: Any]
        let state = json?["BackendState"] as? String ?? ""
        let dns = ((json?["Self"] as? [String: Any])?["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard state == "Running", !dns.isEmpty else {
            tailscale = .notConnected(state.isEmpty ? String(localized: "응답 없음") : state)
            isRouted = false
            return await apply()
        }
        tailscale = .connected(dnsName: dns)
        isRouted = await currentProxy(dns: dns) == localProxy
        await apply()
    }

    /// `tailscale serve`에 경로를 더한다(이 Mac의 tailnet 안에서만 열린다).
    public func enable() async {
        guard let path = settings?.path, let proxy = localProxy else { return }
        await runChange(["serve", "--bg", "--yes", "--set-path", path, proxy])
    }

    /// `tailscale serve`에서 경로를 뺀다.
    public func disable() async {
        guard let path = settings?.path else { return }
        await runChange(["serve", "--https=443", "--set-path", path, "off"])
    }

    private func runChange(_ arguments: [String]) async {
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        guard let result = await cli.run(arguments) else {
            tailscale = .missing
            return
        }
        if result.status != 0 {
            lastError = String(localized: "공식 Tailscale 설정을 바꾸지 못했습니다: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        await refresh()
    }

    private var localProxy: String? {
        guard let port = settings?.port, port > 0 else { return nil }
        return "http://127.0.0.1:\(port)"
    }

    private func currentProxy(dns: String) async -> String? {
        guard let path = settings?.path, let result = await cli.run(["serve", "status", "--json"]), result.status == 0,
              let json = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any],
              let web = json["Web"] as? [String: Any],
              let site = web["\(dns):443"] as? [String: Any],
              let handlers = site["Handlers"] as? [String: Any],
              let handler = handlers[path] as? [String: Any]
        else { return nil }
        return (handler["Proxy"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func apply() async {
        guard var s = settings else { return }
        var publicURL = ""
        if isRouted, case .connected(let dns) = tailscale { publicURL = "https://\(dns)\(s.path)/" }
        let config = UpdatePageConfig(listen: "127.0.0.1:\(s.port)", publicURL: publicURL, page: page)
        do {
            let addr = try await server.apply(config)
            if s.port == 0, let port = addr.split(separator: ":").last.flatMap({ Int($0) }) {
                s.port = port
                settings = s
                try? file.save(s)
            } else if (try? file.load()) == nil {
                try? file.save(s)
            }
        } catch {
            lastError = String(localized: "업데이트 페이지를 열지 못했습니다: \(HostErrorText.message(for: error))")
        }
        pageURL = page != nil && !publicURL.isEmpty ? URL(string: publicURL) : nil
    }

    static func randomHex(_ bytes: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &g)) }.joined()
    }
}
