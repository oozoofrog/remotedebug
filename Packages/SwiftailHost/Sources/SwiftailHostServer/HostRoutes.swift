// 고정 경로 표와 응답 계획. 소켓을 모르는 값 함수다.

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

struct ResponseHeader: Sendable, Equatable {
    var name: String
    var value: String
}

/// 요청 하나에 무엇을 보낼지.
enum ResponsePlan: Sendable, Equatable {
    /// 메모리의 본문(작은 것만).
    case bytes(status: Int, headers: [ResponseHeader], body: [UInt8])
    /// 파일. 상태와 구간은 파일을 연 뒤 실제 길이로 정한다(`FileResponse`).
    case file(path: String, headers: [ResponseHeader])
}

enum HostRouter {
    static let noBodyHeaders: [ResponseHeader] = []

    /// 경로 표에서 찾는다. 내보낼 것이 없는 경로는 없는 것과 같다(404).
    static func route(for path: String, content: ServedContent) -> Route? {
        guard let route = Route(rawValue: path) else { return nil }
        switch route {
        case .index: return .index
        case .file: return content.filePath == nil ? nil : .file
        case .manifest, .ipa: return content.app == nil ? nil : route
        }
    }

    static func plan(_ request: HTTPRequest, content: ServedContent, domain: String) -> (Route?, ResponsePlan) {
        guard let route = route(for: request.path, content: content) else {
            return (nil, .bytes(status: 404, headers: noBodyHeaders, body: []))
        }
        switch route {
        case .index:
            return (route, .bytes(status: 200, headers: [ResponseHeader(name: "Content-Type", value: "text/html; charset=utf-8")],
                                  body: indexPage(content: content, domain: domain)))
        case .file:
            return (route, .file(path: content.filePath ?? "", headers: [
                ResponseHeader(name: "Content-Type", value: "application/octet-stream"),
                ResponseHeader(name: "Content-Disposition", value: "attachment; filename=\"file.bin\""),
            ]))
        case .manifest:
            guard let app = content.app else { return (nil, .bytes(status: 404, headers: noBodyHeaders, body: [])) }
            let body = InstallManifest.render(ipaURL: "https://\(domain)\(Route.ipa.rawValue)", app: app)
            return (route, .bytes(status: 200, headers: [ResponseHeader(name: "Content-Type", value: "application/xml")], body: body))
        case .ipa:
            return (route, .file(path: content.app?.ipaPath ?? "", headers: [
                ResponseHeader(name: "Content-Type", value: "application/octet-stream"),
            ]))
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

/// 파일 응답의 상태·머리·구간. 파일을 연 뒤 실제 길이로 정한다.
struct FileResponse: Sendable, Equatable {
    var status: Int
    var headers: [ResponseHeader]
    /// 보낼 첫 바이트의 오프셋.
    var offset: UInt64
    /// 보낼 바이트 수(`Content-Length`). HEAD에도 같은 값을 쓴다.
    var count: UInt64

    static func make(length: UInt64, request: HTTPRequest, baseHeaders: [ResponseHeader]) -> FileResponse {
        var headers = baseHeaders + [ResponseHeader(name: "Accept-Ranges", value: "bytes")]
        switch ByteRange.decide(header: request.headers["range"], hasIfRange: request.headers["if-range"] != nil, length: length) {
        case .full:
            return FileResponse(status: 200, headers: headers, offset: 0, count: length)
        case .partial(let start, let end):
            headers.append(ResponseHeader(name: "Content-Range", value: ByteRange.contentRange(start: start, end: end, length: length)))
            return FileResponse(status: 206, headers: headers, offset: start, count: end - start + 1)
        case .unsatisfiable:
            headers = [ResponseHeader(name: "Content-Range", value: ByteRange.unsatisfiedContentRange(length: length))]
            return FileResponse(status: 416, headers: headers, offset: 0, count: 0)
        }
    }
}

enum ResponseHead {
    static let reasons: [Int: String] = [
        200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed",
        414: "URI Too Long", 416: "Range Not Satisfiable", 431: "Request Header Fields Too Large",
        500: "Internal Server Error", 505: "HTTP Version Not Supported",
    ]

    /// 상태 줄과 머리. 연결마다 요청 하나만 받으므로 늘 `Connection: close`다.
    static func serialize(status: Int, contentLength: UInt64, headers: [ResponseHeader]) -> [UInt8] {
        var lines = ["HTTP/1.1 \(status) \(reasons[status] ?? "Error")",
                     "Content-Length: \(contentLength)",
                     "Connection: close",
                     "Cache-Control: no-store",
                     "X-Content-Type-Options: nosniff"]
        if status == 405 { lines.append("Allow: GET, HEAD") }
        lines += headers.map { "\($0.name): \($0.value)" }
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}
