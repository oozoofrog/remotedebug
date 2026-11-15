import Foundation
import RDHostLogic
import Synchronization

// 관문 도구(`rd-swiftail-host`)가 쓰는 고정 경로 표. 로직의 자리(`HostRequestHandling`)에 끼운다.

/// 서버가 내보내는 것. 경로는 실행할 때 운영자가 정한다. 요청의 경로로 파일을 고르지 않는다.
public struct ServedContent: Sendable, Equatable {
    /// `/file`로 내보낼 파일 하나. nil이면 `/file`은 404.
    public var filePath: String?
    /// `/manifest.plist`·`/app.ipa`로 내보낼 앱. nil이면 둘 다 404.
    public var app: AppPackage?

    public init(filePath: String? = nil, app: AppPackage? = nil) {
        (self.filePath, self.app) = (filePath, app)
    }
}

/// 서버가 아는 경로. 기록에는 이 이름만 남기고 요청의 원문은 남기지 않는다.
public enum Route: String, Sendable, Equatable, CaseIterable {
    case index = "/"
    case file = "/file"
    case manifest = "/manifest.plist"
    case ipa = "/app.ipa"
}

/// 응답 하나의 기록. 요청의 원문(경로, 머리)은 담지 않는다.
public struct ResponseRecord: Sendable, Equatable {
    public var method: String
    /// 아는 경로면 그 경로, 아니면 nil(404 등).
    public var route: Route?
    public var status: Int
    /// 보낸 본문 바이트(머리 제외).
    public var bodyBytes: UInt64
    /// 로직이 응답을 돌려준 때부터 마지막 바이트를 네트워크 스택이 받아 갈 때까지.
    public var seconds: Double
    /// 약속한 본문을 다 보냈는가.
    public var completed: Bool
    /// 보낸 상대 노드의 `StableID`(직접 연결이면 빈 문자열).
    public var peerStableID: String
}

/// 고정 경로 표로 답하는 처리기. 매니페스트의 URL은 지금 인증서의 이름(`domain`)으로 만든다.
public final class StaticContentHandler: HostRequestHandling, Sendable {
    private let content: ServedContent
    private let domainBox = Mutex("")
    private let onResponse: @Sendable (ResponseRecord) -> Void

    public init(content: ServedContent, domain: String = "", onResponse: @escaping @Sendable (ResponseRecord) -> Void = { _ in }) {
        self.content = content
        self.onResponse = onResponse
        domainBox.withLock { $0 = domain }
    }

    /// TLS 리스너의 인증서 이름. 인증서가 오면 바꾼다.
    public var domain: String {
        get { domainBox.withLock { $0 } }
        set { domainBox.withLock { $0 = newValue } }
    }

    public func handle(_ request: HostRequest) async -> HostResponse {
        let started = ContinuousClock.now
        let peer: String = if case .tailnet(let peer) = request.origin { peer.stableID } else { "" }
        let route = Self.route(for: String(request.target.prefix { $0 != "?" }), content: content)
        var response = respond(request, route: route)
        let onResponse = onResponse
        let method = request.method
        let status = response.status
        response.onFinished = { sent, completed in
            let duration = started.duration(to: .now)
            onResponse(ResponseRecord(method: method, route: route, status: status, bodyBytes: sent,
                                      seconds: Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18,
                                      completed: completed, peerStableID: peer))
        }
        return response
    }

    static let commonHeaders: [(name: String, value: String)] = [("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")]

    private func respond(_ request: HostRequest, route: Route?) -> HostResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return HostResponse(status: 405, headers: Self.commonHeaders + [("Allow", "GET, HEAD")])
        }
        guard let route else { return HostResponse(status: 404, headers: Self.commonHeaders) }
        let domain = domain
        switch route {
        case .index:
            return HostResponse(status: 200, headers: Self.commonHeaders + [("Content-Type", "text/html; charset=utf-8")],
                                body: .bytes(Self.indexPage(content: content, domain: domain)))
        case .file:
            return Self.file(path: content.filePath ?? "", request: request, headers: [
                ("Content-Type", "application/octet-stream"), ("Content-Disposition", "attachment; filename=\"file.bin\""),
            ])
        case .manifest:
            guard let app = content.app else { return HostResponse(status: 404, headers: Self.commonHeaders) }
            let body = InstallManifest.render(ipaURL: "https://\(domain)\(Route.ipa.rawValue)", app: app)
            return HostResponse(status: 200, headers: Self.commonHeaders + [("Content-Type", "application/xml")], body: .bytes(body))
        case .ipa:
            return Self.file(path: content.app?.ipaPath ?? "", request: request, headers: [("Content-Type", "application/octet-stream")])
        }
    }

    /// 경로 표에서 찾는다. 내보낼 것이 없는 경로는 없는 것과 같다(404).
    static func route(for path: String, content: ServedContent) -> Route? {
        guard let route = Route(rawValue: path) else { return nil }
        switch route {
        case .index: return .index
        case .file: return content.filePath == nil ? nil : .file
        case .manifest, .ipa: return content.app == nil ? nil : route
        }
    }

    /// 파일 응답(단일 Range). 길이는 지금 파일의 길이다.
    static func file(path: String, request: HostRequest, headers: [(name: String, value: String)]) -> HostResponse {
        guard let source = try? FileSource(path: path) else { return HostResponse(status: 404, headers: commonHeaders) }
        let length = source.length
        var all = commonHeaders + headers + [("Accept-Ranges", "bytes")]
        switch ByteRange.decide(header: request.header("range"), hasIfRange: request.header("if-range") != nil, length: length) {
        case .full:
            return HostResponse(status: 200, headers: all, body: .file(path: path, offset: 0, count: length))
        case .partial(let start, let end):
            all.append(("Content-Range", ByteRange.contentRange(start: start, end: end, length: length)))
            return HostResponse(status: 206, headers: all, body: .file(path: path, offset: start, count: end - start + 1))
        case .unsatisfiable:
            return HostResponse(status: 416, headers: commonHeaders + [("Content-Range", ByteRange.unsatisfiedContentRange(length: length))])
        }
    }

    /// 첫 화면. 내보내는 것으로 가는 링크만 있다.
    static func indexPage(content: ServedContent, domain: String) -> [UInt8] {
        var items: [String] = []
        if content.filePath != nil {
            items.append("<li><a href=\"\(Route.file.rawValue)\">파일 받기</a></li>")
        }
        if let app = content.app {
            let install = InstallManifest.installURL(manifestURL: "https://\(domain)\(Route.manifest.rawValue)")
            items.append("<li><a href=\"\(InstallManifest.escapeXML(install))\">\(InstallManifest.escapeXML(app.title)) 설치</a></li>")
        }
        let list = items.isEmpty ? "<p>내보내는 파일이 없다.</p>" : "<ul>\(items.joined())</ul>"
        return Array("""
        <!doctype html>
        <html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Swiftail 호스트</title></head>
        <body>\(list)</body></html>

        """.utf8)
    }
}
