import Foundation
import RDModels

extension HostLogic {
    struct Route {
        let name: String
        let parameter: String
        let methods: [String]
        var isPairing: Bool { name == "pair" || name == "pairStatus" }
        /// 허용 목록에 없는 노드도 부를 수 있는 경로: 페어링과 노드 묶기(addenda S. 처리기가 토큰을 본다).
        var acceptsUnknownNode: Bool { isPairing || name == "linkNode" }
        var bodyLimit: Int {
            switch name {
            case "pair": 16 << 10
            case "logs": 128 << 10
            case "crashes": 4 << 20
            case "agentRequest": 32 << 10
            case "push": 4 << 10
            default: 0
            }
        }
    }

    static func route(_ rawPath: String, direct: Bool) -> Route? {
        guard rawPath.hasPrefix("/") else { return nil }
        let pieces = rawPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.allSatisfy({ !$0.isEmpty }),
              pieces.allSatisfy({ hostPercentDecode(String($0)) != nil }) else { return nil }
        let path = pieces.map { hostPercentDecode(String($0))! }
        var name: String?, parameter = "", methods = ["GET"]
        switch path {
        case ["v1", "info"]: name = "info"
        case ["v1", "builds"]: name = "builds"
        case ["v1", "logs"]: name = "logs"; methods = ["POST"]
        case ["v1", "crashes"]: name = "crashes"; methods = ["POST"]
        case ["v1", "agent"]: name = "agent"
        case ["v1", "agent", "requests"]: name = "agentRequest"; methods = ["POST"]
        case ["v1", "resources"]: name = "resources"
        case ["v1", "devices", "self", "push-token"]: name = "push"; methods = ["PUT", "DELETE"]
        case ["v1", "pair", "request"] where !direct: name = "pair"; methods = ["POST"]
        case ["v1", "direct", "enroll"] where !direct: name = "enroll"; methods = ["POST"]
        case ["v1", "devices", "self", "nodes"] where !direct: name = "linkNode"; methods = ["POST"]
        default:
            if path.count == 3 && path[0] == "v1" && path[1] == "resources" { name = "resource"; parameter = path[2] }
            // 진행 확인은 두 리스너 모두 받는다. 직접 연결에서는 케이블 설치(addenda R)의 세션을 본다.
            else if path.count == 3 && path[0] == "v1" && path[1] == "sessions" { name = "sessionStatus"; parameter = path[2] }
            else if direct && path.count == 4 && path[0] == "v1" && path[1] == "builds" && path[3] == "cable-install" {
                name = "cableInstall"; parameter = path[2]; methods = ["POST"]
            }
            else if path.count == 4 && Array(path.prefix(3)) == ["v1", "feedback", "checklist"] { name = "checklist"; parameter = path[3] }
            else if path.count == 5 && Array(path.prefix(3)) == ["v1", "agent", "requests"] && path[4] == "cancel" {
                name = "agentCancel"; parameter = path[3]; methods = ["POST"]
            } else if !direct {
                if path.count == 4 && Array(path.prefix(3)) == ["v1", "pair", "request"] { name = "pairStatus"; parameter = path[3] }
                else if path.count == 4 && path[0] == "v1" && path[1] == "builds" && path[3] == "sessions" {
                    name = "createSession"; parameter = path[2]; methods = ["POST"]
                } else if path.count == 3 && path[0] == "i" && (path[2] == "manifest.plist" || path[2] == "app.ipa") {
                    name = path[2] == "manifest.plist" ? "manifest" : "ipa"; parameter = path[1]
                }
            }
        }
        return name.map { Route(name: $0, parameter: parameter, methods: methods) }
    }

    static func cleanPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        return "/" + components.joined(separator: "/") + (path.hasSuffix("/") && !components.isEmpty ? "/" : "")
    }

    public func handle(_ request: HostRequest) async -> HostResponse {
        let rawPath = String(request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let direct: Bool
        if case .direct = request.origin { direct = true } else { direct = false }
        var route: Route?
        var peer: HostPeer?
        var agentDevice: DeviceEntry?
        let early: HostResponse? = locked {
            if !direct, let page = pageResponse(request, rawPath: rawPath) { return page }
            if case .direct(let ip, _) = request.origin {
                switch authenticateDirect(request, ip: ip, path: hostPercentDecode(rawPath) ?? rawPath) {
                case .success(let authenticated): peer = authenticated
                case .failure(let response): return response.value
                }
            } else if case .tailnet(let identity) = request.origin { peer = identity }
            if let refusal = requestOriginCheck(request, path: hostPercentDecode(rawPath) ?? rawPath) { return refusal }
            let cleaned = Self.cleanPath(rawPath)
            route = Self.route(cleaned, direct: direct)
            guard let route else { return failure(HostErrors.make("not_found")) }
            let method = request.method == "HEAD" ? "GET" : request.method
            guard route.methods.contains(method) else {
                // Go routeError는 GET과 POST만 시험한다. PUT/DELETE 전용 경로의 다른 메서드는 404다.
                return failure(HostErrors.make(route.methods.contains("GET") || route.methods.contains("POST") ? "method_not_allowed" : "not_found"))
            }
            if cleaned != rawPath {
                let suffix = request.target.firstIndex(of: "?").map { String(request.target[$0...]) } ?? ""
                let location = cleaned + suffix
                let escaped = location.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&#34;").replacingOccurrences(of: "'", with: "&#39;")
                return HostResponse(status: 301, headers: [("Location", location), ("Content-Type", "text/html; charset=utf-8")],
                                    body: .bytes(Array(("<a href=\"" + escaped + "\">Moved Permanently</a>.\n\n").utf8)))
            }
            guard let identity = peer, !identity.stableID.isEmpty else { return deny("not_paired", peer: nil, path: rawPath) }
            if !route.acceptsUnknownNode && devices[identity.stableID] == nil {
                // addenda S: 기기 항목에 묶은 노드면 그 기기의 신원으로 처리한다. 직접 연결은 이미 토큰의 기기 신원이다.
                guard case .tailnet = request.origin, let device = linkedDevice(identity.stableID) else {
                    return deny("not_paired", peer: identity, path: rawPath)
                }
                peer = device.hostPeer
            }
            guard let peer else { return deny("not_paired", peer: nil, path: rawPath) }
            if route.name == "agentRequest" || route.name == "agentCancel" {
                guard agentEnabled else { return failure(HostErrors.make("agent_disabled")) }
                agentDevice = devices[peer.stableID]
            }
            return nil
        }
        if let early { return withProtocol(early) }
        guard let route, let peer else { return withProtocol(failure(HostErrors.make("internal"))) }
        var body: HostJSON?
        if route.bodyLimit > 0 && !(route.name == "push" && request.method == "DELETE") {
            do { body = try await readJSON(request, limit: route.bodyLimit, singleValue: route.name == "push") }
            catch {
                let message: String
                switch route.name {
                case "logs": message = "로그 본문을 읽을 수 없습니다."
                case "crashes": message = "크래시 기록 본문을 읽을 수 없습니다."
                case "agentRequest": message = "요청 본문을 읽을 수 없습니다."
                default: message = "요청 본문이 올바른 JSON이 아닙니다."
                }
                return withProtocol(failure(HostErrors.make("bad_request", message)))
            }
        }
        var verifiedBuild: UUID?
        if route.name == "createSession" || route.name == "cableInstall" {
            if route.name == "cableInstall" {
                // 케이블 설치를 받지 않거나 케이블로 온 요청이 아니면 파일을 확인하기 전에 거절한다.
                if let refusal = cableInstallRefusal(request) { return withProtocol(failure(refusal)) }
            }
            guard let build = locked({ builds[route.parameter] }) else { return withProtocol(failure(HostErrors.make("build_not_found"))) }
            guard build.file.unchanged(), (try? build.file.hash()) == build.sum else {
                return withProtocol(failure(HostErrors.make("build_changed")))
            }
            verifiedBuild = build.identity
        }
        return locked {
            if let verifiedBuild {
                guard builds[route.parameter]?.identity == verifiedBuild else { return withProtocol(failure(HostErrors.make("build_not_found"))) }
            }
            do { return withProtocol(try dispatch(route, request: request, peer: peer, body: body, agentDevice: agentDevice, path: hostPercentDecode(rawPath) ?? rawPath)) }
            catch { return withProtocol(failure(HostErrors.from(error))) }
        }
    }

    func requestOriginCheck(_ request: HostRequest, path: String) -> HostResponse? {
        guard path.hasPrefix("/v1/"), ["POST", "PUT", "DELETE"].contains(request.method) else { return nil }
        if request.contentLength > 0 {
            let mediaType = (request.header("content-type") ?? "").split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard mediaType == "application/json" else { return failure(HostErrors.make("unsupported_media_type", "요청 본문은 application/json이어야 합니다.")) }
        }
        if request.header("sec-fetch-site")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cross-site" {
            return failure(HostErrors.make("origin_not_allowed", "같은 출처의 요청만 받습니다."))
        }
        if let origin = request.header("origin") {
            let expected: String
            switch request.origin {
            case .tailnet: expected = options.baseURL()
            case .direct:
                guard let authority = request.header("host"), Self.validAuthority(authority) else {
                    return failure(HostErrors.make("origin_not_allowed", "요청 출처를 확인할 수 없습니다."))
                }
                expected = "https://" + authority
            }
            guard origin == expected else { return failure(HostErrors.make("origin_not_allowed", "같은 출처의 요청만 받습니다.")) }
        }
        return nil
    }

    static func validAuthority(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }),
              let parsed = URLComponents(string: "https://" + value), parsed.host?.isEmpty == false,
              parsed.user == nil, parsed.password == nil, parsed.path.isEmpty, parsed.query == nil, parsed.fragment == nil else { return false }
        return parsed.port.map { (1...65535).contains($0) } ?? true
    }

    func readJSON(_ request: HostRequest, limit: Int, singleValue: Bool) async throws -> HostJSON {
        var bytes: [UInt8] = []
        guard let reader = request.body else { throw HostErrors.make("bad_request") }
        var remaining = request.contentLength
        while remaining > 0 && bytes.count <= limit {
            let count = min(limit + 1 - bytes.count, Int(min(remaining, UInt64(Int.max))))
            guard count > 0, let chunk = try await reader.read(upTo: count), !chunk.isEmpty else { break }
            guard chunk.count <= count else { throw HostErrors.make("bad_request") }
            bytes.append(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
            if !singleValue, let end = HostJSON.valueEnd(bytes), end <= limit { return try HostJSON(data: Data(bytes[..<end])) }
        }
        guard bytes.count <= limit else { throw HostErrors.make("bad_request") }
        return try HostJSON(data: Data(bytes), singleValue: singleValue)
    }

    func withProtocol(_ response: HostResponse) -> HostResponse {
        var response = response
        response.headers.append(("X-RD-Protocol", "1"))
        return response
    }

    struct ResponseError: Error { let value: HostResponse }
    func authenticateDirect(_ request: HostRequest, ip: String, path: String) -> Result<HostPeer, ResponseError> {
        let now = options.now()
        if let failure = directFailures[ip], now.timeIntervalSince(failure.first) >= 60 { directFailures.removeValue(forKey: ip) }
        if let failure = directFailures[ip], failure.count >= 10 { return .failure(.init(value: self.failure(HostErrors.make("too_many_attempts")))) }
        if let device = deviceForToken(request) { return .success(device.hostPeer) }
        if var failure = directFailures[ip] { failure.count += 1; directFailures[ip] = failure }
        else {
            if directFailures.count >= 1024 {
                directFailures = directFailures.filter { now.timeIntervalSince($0.value.first) < 60 }
                if directFailures.count >= 1024, let key = directFailures.keys.first { directFailures.removeValue(forKey: key) }
            }
            directFailures[ip] = DirectFailure(first: now, count: 1)
        }
        return .failure(.init(value: deny("not_paired", peer: nil, path: path)))
    }

    static var resourceRoot: URL { Bundle.module.resourceURL! }

    static let pages: [String: (String, String)] = [
        "/": ("index.html", "text/html; charset=utf-8"),
        "/assets/install.css": ("install.css", "text/css; charset=utf-8"),
        "/assets/install.js": ("install.js", "text/javascript; charset=utf-8"),
        "/assets/logic.js": ("logic.js", "text/javascript; charset=utf-8")
    ]
    func pageResponse(_ request: HostRequest, rawPath: String) -> HostResponse? {
        guard let (file, contentType) = Self.pages[rawPath] else { return nil }
        let headers: [(String, String)] = [
            ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
            ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"), ("Cache-Control", "no-store"), ("X-Frame-Options", "DENY")
        ]
        if request.method != "GET" && request.method != "HEAD" {
            var response = failure(HostErrors.make("method_not_allowed"))
            response.headers += headers + [("Allow", "GET, HEAD")]
            return response
        }
        guard let url = Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "web"), let data = try? Data(contentsOf: url) else {
            return failure(HostErrors.make("internal", "설치 페이지 파일을 읽지 못했습니다."))
        }
        return HostResponse(status: 200, headers: headers + [("Content-Type", contentType)], body: .bytes(Array(data)))
    }
}
