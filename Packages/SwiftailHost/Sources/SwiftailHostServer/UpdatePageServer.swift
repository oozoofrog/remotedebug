import Foundation
import RDHostLogic
import Synchronization

/// RemoteDebug iPhone 앱 자신의 업데이트 페이지(docs/protocol-addenda.md I). 예전 Go 코어의 업데이트 페이지를 옮겨 온 것이다.
///
/// 루프백에서 듣는다. Mac의 공식 Tailscale 앱이 `tailscale serve`로 비밀 HTTPS 경로를 이 리스너로 넘기므로, iPhone은
/// 앱의 VPN(앱을 바꾸는 동안 iOS가 멈춘다) 대신 공식 Tailscale VPN으로 새 빌드를 설치할 수 있다.
///
/// 프로세스에 하나다(`shared`). 호스트 로직의 `/v1/info`가 `publicURL`을 읽는다.
public final class UpdatePageServer: Sendable {
    public struct Page: Sendable, Equatable {
        public var bundleID: String
        public var title: String
        public var version: String
        public var buildNumber: String
        public var minOS: String
        public var size: Int64
        public var sha256: String
        public var publishedAt: String
        public var ipaPath: String
        public var icon: [UInt8]?

        public init(bundleID: String, title: String, version: String, buildNumber: String, minOS: String, size: Int64,
                    sha256: String, publishedAt: String, ipaPath: String, icon: [UInt8]? = nil) {
            (self.bundleID, self.title, self.version, self.buildNumber, self.minOS) = (bundleID, title, version, buildNumber, minOS)
            (self.size, self.sha256, self.publishedAt, self.ipaPath, self.icon) = (size, sha256, publishedAt, ipaPath, icon)
        }
    }

    /// 업데이트 페이지 설정 입력(예전 Go 코어의 `rd_update_page_set`과 같은 JSON). `listen`이 비면 멈춘다. `publicURL`은 공식 Tailscale 앱이 이 페이지를 내는
    /// `/`로 끝나는 https 주소이고, 비면 아직 경로가 서지 않았다.
    public struct Configuration: Sendable, Equatable {
        public var listen: String
        public var publicURL: String
        public var page: Page?

        public init(listen: String, publicURL: String, page: Page?) {
            (self.listen, self.publicURL, self.page) = (listen, publicURL, page)
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidPublicURL
        case invalidPage
        case notLoopback
        case listenFailed(String)

        public var description: String {
            switch self {
            case .invalidPublicURL: "publicURL은 /로 끝나는 https 주소여야 합니다"
            case .invalidPage: "page에는 ipaPath와 bundleId가 필요합니다"
            case .notLoopback: "listen은 루프백 주소여야 합니다"
            case .listenFailed(let address): "\(address)에서 기다리지 못했습니다"
            }
        }
    }

    public static let shared = UpdatePageServer()

    private struct State: Sendable {
        var configuration = Configuration(listen: "", publicURL: "", page: nil)
        var listener: HTTPListener?
    }

    private let state = Mutex(State())
    private let serial = SerialGate()

    public init() {}

    /// 설정을 적용한다. 리스너를 띄우거나 옮기거나 멈춘다. 듣는 주소(`127.0.0.1:<포트>`, 멈췄으면 "")를 돌려준다.
    public func apply(_ configuration: Configuration) async throws(Failure) -> String {
        if !configuration.publicURL.isEmpty {
            guard let url = URL(string: configuration.publicURL), url.scheme == "https", url.host()?.isEmpty == false,
                  url.path().hasSuffix("/") else { throw .invalidPublicURL }
        }
        if let page = configuration.page, page.ipaPath.isEmpty || page.bundleID.isEmpty { throw .invalidPage }
        await serial.lock()
        defer { serial.unlock() }
        if configuration.listen.isEmpty {
            let old = state.withLock { value -> HTTPListener? in
                defer { value = State(configuration: configuration, listener: nil) }
                return value.listener
            }
            old?.close()
            return ""
        }
        let (current, previous) = state.withLock { ($0.listener, $0.configuration) }
        if let current, configuration.listen == previous.listen || configuration.listen == "127.0.0.1:\(current.port)" {
            state.withLock { $0.configuration = configuration }
            return "127.0.0.1:\(current.port)"
        }
        guard let port = Self.loopbackPort(configuration.listen) else { throw .notLoopback }
        let listener: HTTPListener
        do {
            listener = try await HTTPListener.start(binding: .loopback(port: port), security: .plaintext, admission: .loopback,
                                                    handler: UpdatePageHandler(server: self))
        } catch {
            throw .listenFailed(configuration.listen)
        }
        current?.close()
        state.withLock { $0 = State(configuration: configuration, listener: listener) }
        return "127.0.0.1:\(listener.port)"
    }

    /// iPhone이 열 페이지 주소. 페이지가 서지 않았거나 빌드가 없으면 "".
    public var publicURL: String {
        state.withLock { $0.listener == nil || $0.configuration.page == nil ? "" : $0.configuration.publicURL }
    }

    var configuration: Configuration { state.withLock { $0.configuration } }

    /// 이 페이지에 닿는 이름인가: 듣는 포트의 루프백 이름(`127.0.0.1`·`localhost`·`[::1]`)과 `publicURL`의 호스트(포트 없음
    /// 또는 그 URL의 포트, 없으면 443). 대소문자를 가리지 않는다.
    func accepts(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        let (port, publicURL) = state.withLock { ($0.listener?.port, $0.configuration.publicURL) }
        var allowed: Set<String> = []
        if let port {
            allowed.formUnion(["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"])
        }
        if let url = URL(string: publicURL), let name = url.host()?.lowercased(), !name.isEmpty {
            let publicPort = url.port ?? 443
            allowed.insert("\(name):\(publicPort)")
            if publicPort == 443 { allowed.insert(name) }
        }
        return allowed.contains(host)
    }

    /// `127.0.0.1:<포트>`·`localhost:<포트>`의 포트. 그 밖은 nil.
    static func loopbackPort(_ listen: String) -> UInt16? {
        guard let colon = listen.lastIndex(of: ":") else { return nil }
        let host = listen[..<colon]
        guard host == "127.0.0.1" || host == "localhost", let port = UInt16(listen[listen.index(after: colon)...]) else { return nil }
        return port
    }
}

/// 한 번에 하나씩 적용한다.
final class SerialGate: Sendable {
    private let state = Mutex<(busy: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func lock() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { value -> Bool in
                if value.busy {
                    value.waiters.append(continuation)
                    return false
                }
                value.busy = true
                return true
            }
            if acquired { continuation.resume() }
        }
    }

    func unlock() {
        let next = state.withLock { value -> CheckedContinuation<Void, Never>? in
            if value.waiters.isEmpty {
                value.busy = false
                return nil
            }
            return value.waiters.removeFirst()
        }
        next?.resume()
    }
}

/// 첫 화면·매니페스트·IPA·아이콘. 경로의 마지막 조각만 본다(프록시가 붙인 경로를 떼든 말든 같다).
/// 비밀 경로는 공식 Tailscale 앱의 `tailscale serve`가 지킨다(Go와 같다).
struct UpdatePageHandler: HostRequestHandling {
    let server: UpdatePageServer

    static let baseHeaders: [(name: String, value: String)] = [
        ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"),
    ]

    func handle(_ request: HostRequest) async -> HostResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return Self.text(405, "method not allowed")
        }
        // `Host`가 이 페이지의 이름(루프백 이름과 포트, 공식 Tailscale 앱이 내는 이름)일 때만 답한다.
        guard server.accepts(host: request.header("host")) else { return Self.text(421, "misdirected request") }
        let configuration = server.configuration
        let path = String(request.target.prefix { $0 != "?" })
        let name = path.hasSuffix("/") ? "index.html" : String(path.split(separator: "/").last ?? "")
        switch name {
        case "index.html":
            return HostResponse(status: 200, headers: Self.baseHeaders + [
                ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
                ("Content-Type", "text/html; charset=utf-8"),
            ], body: .bytes(Array(Self.page(configuration).utf8)))
        case "manifest.plist":
            guard let page = configuration.page, !configuration.publicURL.isEmpty else { return Self.text(404, "404 page not found") }
            let app = AppPackage(ipaPath: page.ipaPath, bundleIdentifier: page.bundleID, bundleVersion: page.version, title: page.title)
            return HostResponse(status: 200, headers: Self.baseHeaders + [("Content-Type", "application/xml")],
                                body: .bytes(InstallManifest.render(ipaURL: configuration.publicURL + "RemoteDebug.ipa", app: app)))
        case "RemoteDebug.ipa":
            guard let page = configuration.page else { return Self.text(404, "404 page not found") }
            guard let source = try? FileSource(path: page.ipaPath) else { return Self.text(410, "build is gone") }
            guard source.length == UInt64(max(0, page.size)) else { return Self.text(410, "build changed") }
            let length = source.length
            var headers = Self.baseHeaders + [("Content-Type", "application/octet-stream"), ("Accept-Ranges", "bytes")]
            switch ByteRange.decide(header: request.header("range"), hasIfRange: request.header("if-range") != nil, length: length) {
            case .full:
                return HostResponse(status: 200, headers: headers, body: .file(path: page.ipaPath, offset: 0, count: length))
            case .partial(let start, let end):
                headers.append(("Content-Range", ByteRange.contentRange(start: start, end: end, length: length)))
                return HostResponse(status: 206, headers: headers, body: .file(path: page.ipaPath, offset: start, count: end - start + 1))
            case .unsatisfiable:
                return HostResponse(status: 416, headers: Self.baseHeaders + [("Content-Range", ByteRange.unsatisfiedContentRange(length: length))])
            }
        case "icon.png":
            guard let icon = configuration.page?.icon, !icon.isEmpty else { return Self.text(404, "404 page not found") }
            return HostResponse(status: 200, headers: Self.baseHeaders + [("Content-Type", "image/png")], body: .bytes(icon))
        default:
            return Self.text(404, "404 page not found")
        }
    }

    /// Go `http.Error`·`http.NotFound`와 같은 평문 본문.
    static func text(_ status: Int, _ message: String) -> HostResponse {
        HostResponse(status: status, headers: baseHeaders + [("Content-Type", "text/plain; charset=utf-8")],
                     body: .bytes(Array((message + "\n").utf8)))
    }

    static func escape(_ text: String) -> String { InstallManifest.escapeXML(text) }

    static func page(_ configuration: UpdatePageServer.Configuration) -> String {
        var body = ""
        if let page = configuration.page {
            let hasIcon = !(page.icon ?? []).isEmpty
            body += "<div class=\"app\">\(hasIcon ? "<img src=\"icon.png\" alt=\"\">" : "")\n"
            body += "<div><h1>\(escape(page.title))</h1><div class=\"meta\">\(escape(page.version)) (\(escape(page.buildNumber))) · iOS \(escape(page.minOS)) 이상</div></div></div>\n"
            if !configuration.publicURL.isEmpty {
                let install = InstallManifest.installURL(manifestURL: configuration.publicURL + "manifest.plist")
                body += "<a class=\"button\" href=\"\(escape(install))\">설치</a>"
            } else {
                body += "<p>Mac 앱에서 공식 Tailscale 연결을 켜야 설치할 수 있습니다.</p>"
            }
            body += """

            <ol>
            <li>iOS 창에서 <b>설치</b>를 누릅니다. 설치하는 동안 RemoteDebug 앱이 닫힙니다.</li>
            <li>홈 화면에서 RemoteDebug를 열고 앱의 VPN을 다시 켭니다. 공식 Tailscale VPN은 꺼집니다.</li>
            <li>설정 &gt; "이 앱"에서 버전을 확인합니다.</li>
            </ol>
            <p class="note">앱이 열리지 않으면 설정 &gt; 일반 &gt; VPN 및 기기 관리에서 개발자를 신뢰하고, 설정 &gt; 개인정보 보호 및 보안 &gt; 개발자 모드를 확인하세요.</p>
            <p class="note">SHA-256 \(escape(page.sha256))</p>

            """
        } else {
            body += """
            <h1>RemoteDebug 업데이트</h1>
            <p>Mac에 게시된 RemoteDebug iPhone 빌드가 없습니다. Mac에서 RemoteDebugPhone 스킴을 빌드해 게시한 뒤 새로고침하세요.</p>

            """
        }
        return """
        <!doctype html>
        <html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>RemoteDebug 업데이트</title>
        <style>
        :root{color-scheme:light dark;--tint:#0a8c94}
        body{font:17px -apple-system,system-ui,sans-serif;margin:0;padding:24px 16px;max-width:520px;margin:auto}
        .app{display:flex;gap:14px;align-items:center;margin-bottom:20px}
        .app img{width:64px;height:64px;border-radius:14px}
        h1{font-size:22px;margin:0}
        .meta{color:gray;font-size:15px;margin-top:4px}
        a.button{display:block;text-align:center;background:var(--tint);color:#fff;text-decoration:none;font-weight:600;padding:14px;border-radius:12px;margin:20px 0}
        ol{padding-left:20px}li{margin:8px 0}
        .note{color:gray;font-size:14px}
        </style></head><body>
        \(body)</body></html>

        """
    }
}
