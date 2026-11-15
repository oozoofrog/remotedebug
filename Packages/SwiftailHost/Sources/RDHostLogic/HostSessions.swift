import Foundation
import RDModels

extension HostLogic {
    final class Session {
        let id: String
        let token: String
        let buildID: String
        let peer: HostPeer
        let created: Date
        let size: UInt64
        var expires: Date
        var state = SessionState.created
        var manifests = 0
        var ipaStarted = false
        var covered: [Range<UInt64>] = []
        var inflight = 0
        var terminal: Bool { state == .completed || state == .expired || state == .failed }
        var bytesServed: UInt64 { covered.reduce(0) { $0 + $1.countValue } }
        var fullyCovered: Bool { size == 0 || covered.count == 1 && covered[0].lowerBound == 0 && covered[0].upperBound >= size }
        init(id: String, token: String, buildID: String, peer: HostPeer, created: Date, expires: Date, size: UInt64) {
            (self.id, self.token, self.buildID, self.peer, self.created, self.expires, self.size) = (id, token, buildID, peer, created, expires, size)
        }
        func addSpan(_ span: Range<UInt64>) {
            guard !span.isEmpty else { return }
            var lower = span.lowerBound, upper = span.upperBound, result: [Range<UInt64>] = []
            for current in covered {
                if current.upperBound < lower || current.lowerBound > upper { result.append(current) }
                else { lower = min(lower, current.lowerBound); upper = max(upper, current.upperBound) }
            }
            result.append(lower..<upper)
            covered = result.sorted { $0.lowerBound < $1.lowerBound }
        }
    }

    func expireSession(_ session: Session, now: Date) {
        if !session.terminal && session.inflight == 0 && now >= session.expires { session.state = .expired; emitSession(session) }
    }
    func failSession(_ session: Session) {
        if !session.terminal { session.state = .failed; emitSession(session) }
    }
    func emitSession(_ session: Session, userAgent: String = "") {
        emit(.session(.init(sessionId: session.id, buildId: session.buildID, nodeName: session.peer.nodeName,
                            state: session.state, userAgent: userAgent, bytesServed: Int64(session.bytesServed))))
    }
    func createSession(buildID: String, peer: HostPeer, request: HostRequest) throws -> HostResponse {
        guard let build = builds[buildID] else { throw HostErrors.make("build_not_found") }
        let now = options.now()
        let session = Session(id: HostIDs.newID("s_"), token: HostIDs.newToken(), buildID: buildID, peer: peer,
                              created: now, expires: now.addingTimeInterval(options.limits.sessionTTL), size: UInt64(build.descriptor.ipa.size))
        sessions[session.id] = session
        tokens[session.token] = session
        emitSession(session, userAgent: request.header("user-agent") ?? "")
        let manifestURL = options.baseURL() + "/i/" + session.token + "/manifest.plist"
        let escaped = Self.queryEscape(manifestURL)
        return object(["sessionId": session.id, "state": "created", "manifestUrl": manifestURL,
                       "installUrl": "itms-services://?action=download-manifest&url=" + escaped,
                       "expiresAt": hostTimestamp(session.expires)], status: 201)
    }

    func serveManifest(_ session: Session, build: Build, request: HostRequest) throws -> HostResponse {
        guard session.manifests < options.limits.manifestMaxFetches else { throw HostErrors.make("session_expired") }
        let head = request.method == "HEAD"
        guard build.file.unchanged() else {
            if !head { failSession(session) }
            throw HostErrors.make("build_changed")
        }
        if !head {
            session.manifests += 1
            if session.state == .created { session.state = .manifestServed }
            emitSession(session, userAgent: request.header("user-agent") ?? "")
        }
        return HostResponse(status: 200, headers: [("Content-Type", "text/xml")], body: .bytes(Array(Self.manifest(
            ipaURL: options.baseURL() + "/i/" + session.token + "/app.ipa", bundleID: build.descriptor.bundleId,
            version: build.descriptor.version, title: build.descriptor.displayName).utf8)))
    }

    func serveIPA(_ session: Session, build: Build, request: HostRequest) throws -> HostResponse {
        let head = request.method == "HEAD"
        guard build.file.unchanged() else {
            if !head { failSession(session) }
            throw HostErrors.make("build_changed")
        }
        var response = serveFile(build.file, request: request, allowMultipleRanges: false)
        if head { return response }
        if !session.ipaStarted {
            session.ipaStarted = true
            session.expires = session.created.addingTimeInterval(options.limits.sessionMaxTTL)
        }
        session.state = .downloading
        session.inflight += 1
        let userAgent = request.header("user-agent") ?? ""
        emitSession(session, userAgent: userAgent)
        let offset: UInt64, count: UInt64
        if case .file(_, let start, let length) = response.body { offset = start; count = length }
        else { offset = 0; count = 0 }
        let sessionID = session.id
        let completion = CompletionOnce()
        let releaseFile = response.onFinished
        let filePath: String?
        if case .file(let path, _, _) = response.body {
            filePath = path
            fileTransfers[path] = FileTransfer(sessionID: sessionID, offset: offset, count: count)
        } else { filePath = nil }
        response.onFinished = { [weak self] sent, completed in
            defer { releaseFile?(sent, completed) }
            guard let self else { return }
            self.locked {
                guard completion.claim(), let current = self.sessions[sessionID] else { return }
                if let filePath { self.fileTransfers.removeValue(forKey: filePath) }
                let actual = min(sent, count)
                // 끊긴 응답은 Go io.Copy의 마지막 32KiB 조각을 확정하지 않는다.
                let committed = completed ? actual : actual / 32768 * 32768
                current.addSpan(offset..<(offset + committed))
                current.inflight = max(0, current.inflight - 1)
                if !current.terminal {
                    if current.fullyCovered { current.state = .completed; self.emitSession(current, userAgent: userAgent) }
                    else { self.expireSession(current, now: self.options.now()) }
                }
            }
        }
        return response
    }

    // 전송은 이 값을 매 조각 쓰기 전에 확인하고, deadline을 쓰기 기한으로 적용한다.
    // 접점의 파일 경로만으로는 같은 빌드의 여러 세션을 구별할 수 없어 sessionID로 조회한다.
    public struct TransferState: Sendable {
        public var allowed: Bool
        public var deadline: Date
    }
    public func transferState(sessionID: String) -> TransferState? {
        locked {
            guard let session = sessions[sessionID] else { return nil }
            let deadline = session.created.addingTimeInterval(options.limits.sessionMaxTTL)
            let remaining = deadline.timeIntervalSince(options.now())
            // 주입한 논리 시계의 남은 시간을 전송의 실제 쓰기 기한으로 옮긴다.
            // 전송을 멈추는 것은 세션 실패(철회·읽기 오류·게시 취소·로직 닫기)와 기한뿐이다(Go `ipaReader`의 `revoked`).
            // 다른 요청이 세션을 `completed`로 만들어도 이미 보내는 응답은 끝까지 보낸다.
            // 진행 중인 응답이 있는 세션은 `expired`가 되지 않는다(`expireSession`은 inflight가 0일 때만).
            return TransferState(allowed: session.state != .failed && remaining > 0, deadline: Date().addingTimeInterval(remaining))
        }
    }

    public func transferState(for request: HostRequest) -> TransferState? {
        let path = String(request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard let route = Self.route(path, direct: false), route.name == "ipa" else { return nil }
        return locked {
            guard let session = tokens[route.parameter] else { return nil }
            return transferState(sessionID: session.id)
        }
    }

    public static func manifest(ipaURL: String, bundleID: String, version: String, title: String) -> String {
        func escape(_ value: String) -> String {
            var output = ""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "&": output += "&amp;"
                case "<": output += "&lt;"
                case ">": output += "&gt;"
                case "\"": output += "&#34;"
                case "'": output += "&#39;"
                case "\t": output += "&#x9;"
                case "\n": output += "&#xA;"
                case "\r": output += "&#xD;"
                default:
                    if scalar.value < 32 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { output += "�" }
                    else { output.unicodeScalars.append(scalar) }
                }
            }
            return output
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>items</key>
          <array>
            <dict>
              <key>assets</key>
              <array>
                <dict>
                  <key>kind</key><string>software-package</string>
                  <key>url</key><string>\(escape(ipaURL))</string>
                </dict>
              </array>
              <key>metadata</key>
              <dict>
                <key>bundle-identifier</key><string>\(escape(bundleID))</string>
                <key>bundle-version</key><string>\(escape(version))</string>
                <key>kind</key><string>software</string>
                <key>title</key><string>\(escape(title))</string>
              </dict>
            </dict>
          </array>
        </dict>
        </plist>

        """
    }
    static func queryEscape(_ text: String) -> String {
        text.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(Unicode.Scalar(byte))
            }
            if byte == 32 { return "+" }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}

private final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}

private extension Range where Bound == UInt64 {
    var countValue: UInt64 { upperBound - lowerBound }
}
