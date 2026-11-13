import Foundation
import RDModels

/// 요청에 실어 보내는 클라이언트 정보.
public struct ClientInfo: Hashable, Sendable {
    /// iOS 버전(예: `26.1`). `X-RD-Client: iOS/<osVersion>`과 페어링 본문의 `platform`에 쓴다.
    public var osVersion: String
    /// 앱 버전(예: `0.1.0`). 페어링 본문의 `clientVersion`.
    public var appVersion: String

    public init(osVersion: String, appVersion: String) {
        self.osVersion = osVersion
        self.appVersion = appVersion
    }

    var headerValue: String { "iOS/\(osVersion)" }
    var platform: String { "iOS \(osVersion)" }
}

/// 호스트 한 곳(`https://<host>`)의 REST API(protocol §4). 만들 때 정한 주소로만 요청한다.
public struct HostAPI: Sendable {
    /// 요청 하나의 제한 시간(초).
    public struct Timeouts: Hashable, Sendable {
        /// 설치 세션 생성을 뺀 모든 요청.
        public var request: TimeInterval
        /// `POST /v1/builds/{id}/sessions`. 호스트가 응답 전에 IPA 전체의 해시를 다시 계산하므로 길게 둔다.
        public var createSession: TimeInterval

        public init(request: TimeInterval = 10, createSession: TimeInterval = 60) {
            self.request = request
            self.createSession = createSession
        }

        public static let standard = Timeouts()
    }

    /// 호스트가 받는 페어링 본문 필드의 최대 길이(UTF-8 바이트, core/internal/host/pairing.go).
    public static let maxDeviceNameBytes = 200
    public static let maxPlatformBytes = 200
    public static let maxClientVersionBytes = 100

    public let host: String
    public let timeouts: Timeouts
    private let baseURL: URL
    private let transport: any HTTPTransport
    private let client: ClientInfo
    /// 직접 연결(docs/protocol-addenda.md O)의 `Authorization` 값. tailnet 경로에서는 `nil`.
    private let authorization: String?

    /// 같은 네트워크 직접 연결인가.
    public var isDirect: Bool { authorization != nil }

    /// 직접 연결용: `https://<사설 IP>:<포트>`로 보내고 요청마다 기기 토큰을 싣는다.
    /// `transport`는 인증서의 공개 키를 고정한 전송이어야 한다(`DirectTransportMaking`).
    /// 주소가 사설·링크 로컬 IP가 아니면 `nil`(토큰을 다른 곳으로 보내지 않는다).
    init?(direct endpoint: DirectEndpoint, authorization: String, transport: any HTTPTransport, client: ClientInfo, timeouts: Timeouts = .standard) {
        let authority = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        guard (1...65535).contains(endpoint.port), PeerPath.isPrivateEndpoint("\(authority):\(endpoint.port)"),
              let base = URL(string: "https://\(authority):\(endpoint.port)") else { return nil }
        self.host = endpoint.host
        self.baseURL = base
        self.transport = transport
        self.client = client
        self.timeouts = timeouts
        self.authorization = authorization
    }

    /// 호스트가 정책을 통과하지 못하면 `nil`.
    public init?(
        host: String,
        policy: HostPolicy = .tailnetOnly,
        transport: any HTTPTransport,
        client: ClientInfo,
        timeouts: Timeouts = .standard
    ) {
        guard let valid = policy.validatedHost(host) else { return nil }
        let authority = valid.contains(":") ? "[\(valid)]" : valid
        guard let base = URL(string: "https://\(authority)") else { return nil }
        self.host = valid
        self.baseURL = base
        self.transport = transport
        self.client = client
        self.timeouts = timeouts
        self.authorization = nil
    }

    /// 직접 연결에 등록한다(docs/protocol-addenda.md O). tailnet 경로에서만 부른다. 다시 부르면 토큰이 바뀐다.
    public func enrollDirect() async throws -> DirectEnrollment {
        try await call("POST", ["v1", "direct", "enroll"], bodyData: nil, timeout: timeouts.request, expect: DirectEnrollment.self)
    }

    public func info() async throws -> InfoResponse {
        try await call("GET", ["v1", "info"], expect: InfoResponse.self)
    }

    public func builds() async throws -> [BuildDescriptor] {
        try await call("GET", ["v1", "builds"], expect: BuildsResponse.self).builds
    }

    public func requestPairing(code: PairingCode, deviceName: String) async throws -> PairRequestState {
        let body = PairRequestBody(
            code: code.normalized,
            deviceName: Self.truncated(deviceName, maxBytes: Self.maxDeviceNameBytes),
            platform: Self.truncated(client.platform, maxBytes: Self.maxPlatformBytes),
            clientVersion: Self.truncated(client.appVersion, maxBytes: Self.maxClientVersionBytes)
        )
        return try await call("POST", ["v1", "pair", "request"], body: body, expect: PairRequestState.self)
    }

    public func pairingState(requestID: String) async throws -> PairRequestState {
        try await call("GET", ["v1", "pair", "request", Self.checkedID(requestID)], expect: PairRequestState.self)
    }

    public func createSession(buildID: String) async throws -> SessionResponse {
        try await call("POST", ["v1", "builds", Self.checkedID(buildID), "sessions"], bodyData: nil, timeout: timeouts.createSession, expect: SessionResponse.self)
    }

    public func sessionStatus(sessionID: String) async throws -> SessionStatus {
        try await call("GET", ["v1", "sessions", Self.checkedID(sessionID)], expect: SessionStatus.self)
    }

    /// Mac이 보낸 파일 목록(docs/protocol-addenda.md H).
    public func resources() async throws -> [ResourceDescriptor] {
        try await call("GET", ["v1", "resources"], expect: ResourcesResponse.self).resources
    }

    /// 파일 하나를 임시 파일로 받고 크기와 SHA-256을 목록과 대조한다. 돌려준 파일은 부른 쪽이 옮기거나 지운다.
    public func download(_ resource: ResourceDescriptor, progress: @escaping FileDownloader.Progress = { _, _ in }) async throws -> URL {
        var url = baseURL
        for component in ["v1", "resources", try Self.checkedID(resource.id)] { url.append(path: component, directoryHint: .notDirectory) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(client.headerValue, forHTTPHeaderField: "X-RD-Client")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let file: URL
        let response: HTTPURLResponse
        do {
            let context = try? RDJSON.encoder().encode(resource)
            (file, response) = try await transport.download(request, key: resource.id, context: context, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw HostAPIError.timedOut("URLError \(error.code.rawValue)")
        } catch let error as URLError {
            throw HostAPIError.connectionFailed("URLError \(error.code.rawValue)")
        } catch {
            throw HostAPIError.connectionFailed(String(describing: type(of: error)))
        }
        try Task.checkCancellation()
        try Self.checkDownloaded(file: file, response: response, resource: resource)
        return file
    }

    /// 받은 파일을 확인한다: 프로토콜 헤더, 상태, 크기와 SHA-256. 틀리면 파일을 지우고 던진다.
    /// 앱을 다시 띄운 뒤 넘겨받은 전송(`FileDownloader.attach`)도 이것으로 확인한다.
    public static func checkDownloaded(file: URL, response: HTTPURLResponse, resource: ResourceDescriptor) throws {
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: file) } }
        guard response.value(forHTTPHeaderField: "X-RD-Protocol")?.trimmingCharacters(in: .whitespaces) == "1" else {
            if response.statusCode >= 400 { throw HostAPIError.connectionFailed("HTTP \(response.statusCode) without X-RD-Protocol") }
            throw HostAPIError.protocolMismatch("X-RD-Protocol")
        }
        guard (200..<300).contains(response.statusCode) else {
            if let data = try? Data(contentsOf: file), let body = try? RDJSON.decoder().decode(APIErrorBody.self, from: data) {
                throw HostAPIError(status: response.statusCode, code: body.error.code, message: body.error.message)
            }
            throw HostAPIError.invalidResponse(status: response.statusCode, "undecodable error body")
        }
        let (size, sha) = try FileDigest.sha256(of: file)
        guard size == resource.size, sha.caseInsensitiveCompare(resource.sha256) == .orderedSame else {
            FileDownloader.shared.discardResumeData(key: resource.id)
            throw HostAPIError(status: response.statusCode, code: HostAPIError.fileMismatchCode, message: "size or sha256 differs")
        }
        keep = true
    }

    /// 진단 로그 묶음을 보낸다(docs/protocol-addenda.md G). 호스트가 받은 줄 수를 돌려준다.
    @discardableResult
    public func sendLogs(_ entries: [DeviceLogEntry]) async throws -> Int {
        struct Accepted: Decodable { var accepted: Int }
        return try await call("POST", ["v1", "logs"], body: DeviceLogBatch(entries: entries), expect: Accepted.self).accepted
    }

    /// 크래시 기록 하나를 보낸다(docs/protocol-addenda.md L).
    public func sendCrash(_ report: CrashReport) async throws {
        struct Accepted: Decodable { var accepted: Int }
        _ = try await call("POST", ["v1", "crashes"], body: report, expect: Accepted.self)
    }

    // MARK: 에이전트 요청(addenda K)

    public func agentBoard() async throws -> AgentBoard {
        try await call("GET", ["v1", "agent"], expect: AgentBoard.self)
    }

    /// 요청 id를 돌려준다. 진행과 결과는 `agentBoard()`의 `requests`에 나온다.
    public func submitAgentRequest(_ submission: AgentSubmission) async throws -> String {
        struct Accepted: Decodable { var id: String }
        return try await call("POST", ["v1", "agent", "requests"], body: submission, expect: Accepted.self).id
    }

    public func cancelAgentRequest(id: String) async throws {
        struct Accepted: Decodable {}
        _ = try await call("POST", ["v1", "agent", "requests", Self.checkedID(id), "cancel"], bodyData: nil,
                           timeout: timeouts.request, expect: Accepted.self)
    }

    // MARK: -

    /// 앞뒤 공백을 지우고 UTF-8 `maxBytes` 바이트 안에 들어가게 글자(Character) 경계에서 자른다.
    static func truncated(_ text: String, maxBytes: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maxBytes else { return trimmed }
        var out = ""
        var used = 0
        for ch in trimmed {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 경로에 넣는 식별자는 `[A-Za-z0-9_-]`만 허용한다(경로 조작 방지).
    private static func checkedID(_ id: String) throws -> String {
        let ok = !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
        guard ok else { throw HostAPIError(status: 0, code: "bad_request", message: "invalid identifier") }
        return id
    }

    private func call<T: Decodable>(_ method: String, _ path: [String], expect: T.Type) async throws -> T {
        try await call(method, path, bodyData: nil, timeout: timeouts.request, expect: expect)
    }

    private func call<B: Encodable, T: Decodable>(_ method: String, _ path: [String], body: B, expect: T.Type) async throws -> T {
        let data = try RDJSON.encoder().encode(body)
        return try await call(method, path, bodyData: data, timeout: timeouts.request, expect: expect)
    }

    private func call<T: Decodable>(_ method: String, _ path: [String], bodyData: Data?, timeout: TimeInterval, expect: T.Type) async throws -> T {
        var url = baseURL
        for component in path { url.append(path: component, directoryHint: .notDirectory) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(client.headerValue, forHTTPHeaderField: "X-RD-Client")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as HostAPIError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw HostAPIError.timedOut("URLError \(error.code.rawValue)")
        } catch let error as URLError {
            // URL(토큰 포함 가능)은 남기지 않고 오류 종류만 남긴다.
            throw HostAPIError.connectionFailed("URLError \(error.code.rawValue)")
        } catch {
            throw HostAPIError.connectionFailed(String(describing: type(of: error)))
        }
        try Task.checkCancellation()

        // 호스트의 모든 응답에는 X-RD-Protocol이 붙는다. 없으면 중간(로컬 프록시 등)에서 끊긴 것이다.
        guard let proto = response.value(forHTTPHeaderField: "X-RD-Protocol") else {
            if response.statusCode >= 400 { throw HostAPIError.connectionFailed("HTTP \(response.statusCode) without X-RD-Protocol") }
            throw HostAPIError.protocolMismatch("missing X-RD-Protocol")
        }
        guard proto.trimmingCharacters(in: .whitespaces) == "1" else {
            throw HostAPIError.protocolMismatch("X-RD-Protocol \(proto)")
        }

        guard (200..<300).contains(response.statusCode) else {
            if let body = try? RDJSON.decoder().decode(APIErrorBody.self, from: data) {
                throw HostAPIError(status: response.statusCode, code: body.error.code, message: body.error.message)
            }
            throw HostAPIError.invalidResponse(status: response.statusCode, "undecodable error body")
        }
        do {
            return try RDJSON.decoder().decode(T.self, from: data)
        } catch {
            throw HostAPIError.invalidResponse(status: response.statusCode, "undecodable \(T.self)")
        }
    }
}
