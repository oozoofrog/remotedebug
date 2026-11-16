import CryptoKit
import Darwin
import Foundation
import Network
import RDHostLogic
import RDModels
import Synchronization
import Testing

@testable import PhoneClientKit
@testable import SwiftailHostServer

/// 실제 호스트 로직(`HostLogic`)을 루프백 리스너 뒤에 두고 전송과 로직 사이의 이음새를 본다.
/// 계정·제어 서버·인증서 발급 없이 돈다.

/// 로직이 낸 사건(완전한 형태).
final class EmittedLog: Sendable {
    private let items = Mutex<[HostLogic.EmittedEvent]>([])
    func append(_ event: HostLogic.EmittedEvent) { items.withLock { $0.append(event) } }
    var all: [HostLogic.EmittedEvent] { items.withLock { $0 } }
    func sessionStates(_ id: String) -> [SessionState] {
        all.compactMap { if case .session(let e) = $0.event, e.sessionId == id { e.state } else { nil } }
    }
}

/// 게시 폴더와 로직 하나.
final class LogicHarness: @unchecked Sendable {
    static let fqdn = "rd-mac-1a2b3c4d.example.ts.net"
    let directory: URL
    let logic: HostLogic
    let events = EmittedLog()

    init(limits: HostLogic.Limits = HostLogic.Limits(), direct: @escaping @Sendable () -> HostLogic.DirectInfo? = { nil }) throws {
        directory = try makeTestDirectory("logic")
        let events = events
        logic = try HostLogic(options: HostLogic.Options(
            publishDirectory: directory.path,
            info: { HostLogic.Info(hostID: "h_1", hostName: "Mac", fqDN: LogicHarness.fqdn, appVersion: "1.0") },
            baseURL: { "https://" + LogicHarness.fqdn },
            limits: limits,
            direct: direct,
            events: { _ in },
            eventDetails: { events.append($0) }
        ))
    }

    deinit {
        logic.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func pair(_ peer: HostPeer, id: String = "d_1") throws {
        try logic.setDevices([DeviceEntry(id: id, name: "시험 iPhone", nodeStableId: peer.stableID, nodeName: peer.nodeName,
                                          loginName: "", pairedAt: Date())])
    }

    /// `size`바이트 IPA를 게시하고 빌드 id를 돌려준다.
    func publishBuild(size: Int) throws -> String {
        let url = directory.appending(path: "build-\(UUID().uuidString.prefix(8)).ipa")
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try logic.publish(PublishRequest(build: BuildDescriptor(
            id: "", bundleId: "com.example.app", displayName: "Sample", version: "1.0", buildNumber: "1", minOS: "26.0",
            debug: true, configuration: "Debug", configurationEvidence: .path,
            signing: .init(teamId: "EXAMPLE", profileName: "Example", profileExpires: Date().addingTimeInterval(3600),
                           provisionedDeviceCount: 1, getTaskAllow: true),
            ipa: .init(size: Int64(data.count), sha256: sha), publishedAt: Date()), ipaPath: url.path))
    }

    /// 게시 폴더 안의 스냅숏 파일들(같은 inode의 전송 사본 포함).
    var snapshotFiles: [String] {
        let root = directory.appending(path: ".rd-snapshots").path
        return ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).map { root + "/" + $0 }
    }
}

/// 요청 하나를 보내고 연결이 닫힐 때까지 응답을 읽는다. 시험이 머리를 그대로 정한다.
func exchange(port: UInt16, tls: Bool, _ head: String, body: [UInt8] = []) async throws -> (status: Int, headers: [String: String], body: [UInt8]) {
    let parameters: NWParameters
    if tls {
        let options = NWProtocolTLS.Options()
        // 직접 연결 인증서는 자체 서명이다. 이 시험은 머리 전달만 본다(고정 값 확인은 DirectListener 시험이 본다).
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in complete(true) },
                                              DispatchQueue(label: "test.verify"))
        parameters = NWParameters(tls: options)
    } else {
        parameters = .tcp
    }
    let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    defer { connection.cancel() }
    guard await ConnectionIO.ready(connection) else { throw URLError(.cannotConnectToHost) }
    _ = await ConnectionIO.send(connection, Array(head.utf8) + body)
    // 클라이언트처럼 Content-Length만큼 읽는다(닫힘을 기다리지 않는다).
    var received: [UInt8] = []
    func more() async throws {
        guard case .bytes(let bytes) = await ConnectionIO.receive(connection, maximum: 65_536), !bytes.isEmpty else {
            throw URLError(.networkConnectionLost)
        }
        received += bytes
    }
    while HTTPRequestParser.firstIndex(of: [13, 10, 13, 10], in: received) == nil { try await more() }
    let end = HTTPRequestParser.firstIndex(of: [13, 10, 13, 10], in: received)!
    let text = String(decoding: received[..<end], as: UTF8.self)
    var headers: [String: String] = [:]
    for line in text.split(separator: "\r\n").dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let status = Int(text.split(separator: " ")[1]) ?? 0
    let length = Int(headers["content-length"] ?? "0") ?? 0
    while received.count < end + 4 + length { try await more() }
    return (status, headers, Array(received[(end + 4)..<(end + 4 + length)]))
}

/// iPhone 앱의 `HostAPI`가 만든 `URLRequest`를 그대로 루프백 리스너에 보낸다.
/// `Host`는 URLSession처럼 URL의 authority로 붙인다(연결은 루프백으로 간다).
struct LoopbackTransport: PhoneClientKit.HTTPTransport {
    let port: UInt16
    let tls: Bool

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host(percentEncoded: false) else { throw URLError(.badURL) }
        let authority = host + (url.port.map { ":\($0)" } ?? "")
        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true) { target += "?" + query }
        let body = Array(request.httpBody ?? Data())
        let method = request.httpMethod ?? "GET"
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(authority)"]
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) { lines.append("\(name): \(value)") }
        // URLSession은 본문이 없는 POST·PUT에도 Content-Length: 0을 붙인다.
        if !body.isEmpty || method == "POST" || method == "PUT" { lines.append("Content-Length: \(body.count)") }
        lines.append("Connection: close")
        let reply = try await exchange(port: port, tls: tls, lines.joined(separator: "\r\n") + "\r\n\r\n", body: body)
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            throw URLError(.badServerResponse)
        }
        return (Data(reply.body), response)
    }
}

@Suite("전송과 로직", .serialized, .timeLimit(.minutes(3)))
struct LogicTransportTests {
    static let ipaSize = 48 << 20

    /// 세션을 만들고 IPA 경로를 돌려준다.
    static func ipaTarget(_ harness: LogicHarness, server: HTTPListener, buildID: String) async throws -> (sessionID: String, target: String) {
        let reply = try await exchange(port: server.port, tls: false,
                                       "POST /v1/builds/\(buildID)/sessions HTTP/1.1\r\nHost: \(LogicHarness.fqdn)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        #expect(reply.status == 201)
        let session = try JSONDecoder().decode(SessionResponse.self, from: Data(reply.body))
        return (session.sessionId, session.manifestUrl.path.replacingOccurrences(of: "manifest.plist", with: "app.ipa"))
    }

    static func sessionStatus(_ server: HTTPListener, _ id: String) async throws -> SessionStatus {
        let reply = try await exchange(port: server.port, tls: false,
                                       "GET /v1/sessions/\(id) HTTP/1.1\r\nHost: \(LogicHarness.fqdn)\r\nConnection: close\r\n\r\n")
        return try JSONDecoder().decode(SessionStatus.self, from: Data(reply.body))
    }

    /// IPA 받기를 시작하고 머리와 본문 일부만 받은 채 멈춘다.
    static func startStalledDownload(_ server: HTTPListener, target: String) async throws -> RawClient {
        let client = try await RawClient(port: server.port)
        await client.send("GET \(target) HTTP/1.1\r\nHost: \(LogicHarness.fqdn)\r\n\r\n")
        let head = try #require(await client.response(headOnly: true))
        #expect(head.status == 200)
        return client
    }

    @Test func installSessionShowsProgressWhileSendingAndCompletes() async throws {
        let harness = try LogicHarness()
        try harness.pair(testPeer)
        let server = try await startPlain(harness.logic)
        defer { server.close() }
        let buildID = try harness.publishBuild(size: Self.ipaSize)
        let (sessionID, target) = try await Self.ipaTarget(harness, server: server, buildID: buildID)
        let client = try await Self.startStalledDownload(server, target: target)

        // 받는 쪽이 멈춰 있어도 이미 보낸 조각이 진행률에 나온다(전에는 응답이 끝나야 0에서 바뀌었다).
        var status = try await Self.sessionStatus(server, sessionID)
        let deadline = ContinuousClock.now + .seconds(10)
        while status.bytesServed == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            status = try await Self.sessionStatus(server, sessionID)
        }
        #expect(status.state == .downloading)
        #expect(status.bytesServed > 0 && status.bytesServed < Int64(Self.ipaSize))

        var received = 0
        while received < Self.ipaSize {
            guard case .bytes(let more) = await ConnectionIO.receive(client.connection, maximum: 1 << 20), !more.isEmpty else { break }
            received += more.count
        }
        #expect(received >= Self.ipaSize)
        try await waitUntil { harness.events.sessionStates(sessionID).contains(.completed) }
        status = try await Self.sessionStatus(server, sessionID)
        #expect(status.state == .completed && status.bytesServed == Int64(Self.ipaSize))
    }

    @Test func revokedSessionStopsStalledTransfer() async throws {
        let harness = try LogicHarness()
        try harness.pair(testPeer)
        var limits = HTTPServerLimits()
        limits.progressTimeout = 120
        let server = try await startPlain(harness.logic, limits: limits)
        defer { server.close() }
        let buildID = try harness.publishBuild(size: Self.ipaSize)
        let (sessionID, target) = try await Self.ipaTarget(harness, server: server, buildID: buildID)
        let client = try await Self.startStalledDownload(server, target: target)
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.activeConnectionCount == 1)

        // 기기를 허용 목록에서 빼면 세션이 실패하고, 막힌 쓰기도 진전 기한(120초)을 기다리지 않고 끊긴다.
        try harness.logic.setDevices([])
        let started = ContinuousClock.now
        try await waitUntil(5) { server.activeConnectionCount == 0 }
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(harness.events.sessionStates(sessionID).last == .failed)
        _ = client
    }

    @Test func transferStopsAtSessionDeadline() async throws {
        let harness = try LogicHarness(limits: HostLogic.Limits(sessionTTL: 1, sessionMaxTTL: 2))
        try harness.pair(testPeer)
        var limits = HTTPServerLimits()
        limits.progressTimeout = 120
        let server = try await startPlain(harness.logic, limits: limits)
        defer { server.close() }
        let buildID = try harness.publishBuild(size: Self.ipaSize)
        let (sessionID, target) = try await Self.ipaTarget(harness, server: server, buildID: buildID)
        let client = try await Self.startStalledDownload(server, target: target)

        // 세션을 만든 지 2초(sessionMaxTTL)가 지나면 받는 쪽이 멈춰 있어도 끊긴다. 끊긴 뒤 세션은 만료된다.
        try await waitUntil(6) { server.activeConnectionCount == 0 }
        harness.logic.sweep()
        #expect(harness.events.sessionStates(sessionID).last == .expired)
        _ = client
    }

    @Test func readFailureFailsTheSession() async throws {
        let harness = try LogicHarness()
        try harness.pair(testPeer)
        let server = try await startPlain(harness.logic)
        defer { server.close() }
        let buildID = try harness.publishBuild(size: Self.ipaSize)
        let (sessionID, target) = try await Self.ipaTarget(harness, server: server, buildID: buildID)
        let client = try await Self.startStalledDownload(server, target: target)

        // 보내는 도중 스냅숏(전송 사본과 같은 inode)을 줄인다. 전송이 파일을 읽지 못하면 세션은 `failed`가 된다.
        for path in harness.snapshotFiles {
            chmod(path, 0o600)
            #expect(truncate(path, 0) == 0)
        }
        #expect(await client.waitForClose(seconds: 10))
        try await waitUntil { harness.events.sessionStates(sessionID).contains(.failed) }
        #expect(!harness.events.sessionStates(sessionID).contains(.completed))
    }

    /// iPhone 앱의 실제 전송(공개 키 고정 `URLSession`)은 맞는 고정 값일 때만 직접 연결 리스너의 TLS를 지난다.
    @Test func pinnedTransportPassesDirectListenerTLSOnlyWithTheRightPin() async throws {
        let directory = try makeTestDirectory("direct-pin")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try DirectIdentity(directory: directory)
        let harness = try LogicHarness()
        let direct = try await DirectListener.start(identity: identity, handler: harness.logic, loopbackOnly: true)
        defer { direct.close() }
        let request = URLRequest(url: try #require(URL(string: "https://127.0.0.1:\(direct.port)/v1/info")))

        // 맞는 고정 값: TLS를 지나 호스트의 답을 받는다(토큰 없는 요청이라 로직이 거절한다).
        let (_, response) = try await PinnedURLSessionTransport(pin: identity.spki, maximumTimeout: 10).send(request)
        #expect(response.statusCode == 403)
        // 틀린 고정 값: TLS에서 끊겨 답을 받지 못한다.
        await #expect(throws: (any Error).self) {
            _ = try await PinnedURLSessionTransport(pin: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", maximumTimeout: 10).send(request)
        }
    }

    /// iPhone 앱이 실제로 보내는 요청(`HostAPI`)과 설치 페이지의 같은 출처 요청이 tailnet 모양 리스너와 직접 연결 리스너
    /// 양쪽에서 받아들여지고, 다른 출처 요청은 막힌다. 리스너는 `host`·`origin`·`sec-fetch-site`·`content-type`을 그대로 넘긴다.
    @Test func phoneAndInstallPageRequestsPassOriginChecksOnBothListeners() async throws {
        let directDirectory = try makeTestDirectory("direct")
        defer { try? FileManager.default.removeItem(at: directDirectory) }
        let identity = try DirectIdentity(directory: directDirectory)
        // 직접 연결 정보의 포트는 리스너가 선 뒤에 정해진다.
        let portBox = Mutex(0)
        let harness = try LogicHarness(direct: { HostLogic.DirectInfo(id: identity.id, port: portBox.withLock { $0 }, spki: identity.spki) })
        let logic = harness.logic
        let webPeer = HostPeer(stableID: "nWEB5678", nodeName: "rd-web-5e6f7a8b", loginName: "user@example.com")
        let tailnet = try await startPlain(logic)
        defer { tailnet.close() }
        let web = try await HTTPListener.start(binding: .loopback(port: 0), security: .plaintext, admission: .acceptAllForTesting(webPeer),
                                               handler: logic)
        defer { web.close() }
        let direct = try await DirectListener.start(identity: identity, handler: logic, loopbackOnly: true)
        defer { direct.close() }
        portBox.withLock { $0 = Int(direct.port) }
        let client = ClientInfo(osVersion: "26.1", appVersion: "0.2.0")
        let buildID = try harness.publishBuild(size: 4096)
        try logic.setAgentBoard(Data(#"{"enabled":true,"projects":[],"agents":[],"requests":[]}"#.utf8))
        let pushToken = String(repeating: "ab", count: 32)

        // tailnet: 페어링부터 iPhone 앱이 보내는 요청 전부.
        let phone = try #require(HostAPI(host: LogicHarness.fqdn, transport: LoopbackTransport(port: tailnet.port, tls: false), client: client))
        let code = try logic.openPairing(ttlSeconds: 300)
        let pending = try await phone.requestPairing(code: PairingCode.parse(code.code), deviceName: "시험 iPhone")
        #expect(pending.state == .pending)
        _ = try logic.decidePairing(requestID: pending.requestId, allow: true)
        #expect(try await phone.pairingState(requestID: pending.requestId).state == .approved)
        #expect(try await phone.builds().map(\.id) == [buildID])
        let session = try await phone.createSession(buildID: buildID)
        #expect(try await phone.sessionStatus(sessionID: session.sessionId).state == .created)
        #expect(try await phone.sendLogs([DeviceLogEntry(at: Date(), level: .info, source: "app", message: "tailnet")]) == 1)
        try await phone.sendCrash(CrashReport(kind: .feedback, name: "tailnet", bundleId: "com.example.app", appVersion: "1.0",
                                              crashedAt: Date(), text: "tailnet"))
        try await phone.registerPushToken(token: pushToken, bundleId: "com.example.app")
        try await phone.removePushToken()
        let tailnetAgent = try await phone.submitAgentRequest(AgentSubmission(text: "tailnet", project: ""))
        try await phone.cancelAgentRequest(id: tailnetAgent)
        let enrollment = try await phone.enrollDirect()
        #expect(enrollment.port == Int(direct.port) && enrollment.tlsSPKI == identity.spki)

        // 직접 연결: 등록한 토큰으로 같은 요청들. Host는 iPhone이 찾은 사설 주소다(연결은 루프백으로 간다).
        let lan = "192.168.1.20"
        let viaDirect = try #require(HostAPI(direct: DirectEndpoint(host: lan, port: Int(direct.port)),
                                             authorization: "RD-Device \(enrollment.deviceId).\(enrollment.token)",
                                             transport: LoopbackTransport(port: direct.port, tls: true), client: client))
        #expect(try await viaDirect.info().hostId == "h_1")
        #expect(try await viaDirect.builds().map(\.id) == [buildID])
        #expect(try await viaDirect.sendLogs([DeviceLogEntry(at: Date(), level: .info, source: "app", message: "direct")]) == 1)
        try await viaDirect.sendCrash(CrashReport(kind: .feedback, name: "direct", bundleId: "com.example.app", appVersion: "1.0",
                                                  crashedAt: Date(), text: "direct"))
        try await viaDirect.registerPushToken(token: pushToken, bundleId: "com.example.app")
        try await viaDirect.removePushToken()
        let directAgent = try await viaDirect.submitAgentRequest(AgentSubmission(text: "direct", project: ""))
        try await viaDirect.cancelAgentRequest(id: directAgent)

        let types = harness.events.all.map(\.event.type)
        for type in ["device-log", "device-crash", "agent-request", "agent-cancel"] {
            #expect(types.filter { $0 == type }.count == 2, "\(type)")
        }

        // 설치 페이지(logic.js·install.js)의 fetch: 같은 출처라 브라우저가 Origin과 Sec-Fetch-Site: same-origin을 붙인다.
        func page(_ port: UInt16, tls: Bool = false, _ method: String, _ path: String, host: String, origin: String, site: String = "same-origin",
                  contentType: String = "application/json", authorization: String? = nil, body: String? = nil) async throws -> (Int, String) {
            let bytes = Array((body ?? "").utf8)
            var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nOrigin: \(origin)\r\nSec-Fetch-Site: \(site)\r\n"
            head += "Sec-Fetch-Mode: cors\r\nAccept: application/json\r\nX-RD-Client: Web/1\r\n"
            if body != nil { head += "Content-Type: \(contentType)\r\n" }
            if let authorization { head += "Authorization: \(authorization)\r\n" }
            head += "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
            let reply = try await exchange(port: port, tls: tls, head, body: bytes)
            let code = (try? JSONDecoder().decode(APIErrorBody.self, from: Data(reply.body)))?.error.code ?? ""
            return (reply.status, code)
        }
        let own = "https://" + LogicHarness.fqdn
        let webCode = try logic.openPairing(ttlSeconds: 300)
        let pairBody = #"{"code":"\#(webCode.code)","deviceName":"Safari","platform":"Web","clientVersion":"web-1"}"#
        // 다른 출처·cross-site·JSON이 아닌 본문은 막힌다(전송이 머리를 그대로 넘긴다는 증거).
        #expect(try await page(web.port, "POST", "/v1/pair/request", host: LogicHarness.fqdn, origin: "https://evil.example", body: pairBody)
                == (403, "origin_not_allowed"))
        #expect(try await page(web.port, "POST", "/v1/pair/request", host: LogicHarness.fqdn, origin: own, site: "cross-site", body: pairBody)
                == (403, "origin_not_allowed"))
        #expect(try await page(web.port, "POST", "/v1/pair/request", host: LogicHarness.fqdn, origin: own, contentType: "text/plain",
                               body: pairBody) == (415, "unsupported_media_type"))
        let paired = try await page(web.port, "POST", "/v1/pair/request", host: LogicHarness.fqdn, origin: own, body: pairBody)
        #expect(paired.0 == 202)
        let webRequest = try #require(harness.events.all.compactMap { event -> String? in
            if case .pairRequest(let e) = event.event, e.nodeName == webPeer.nodeName { e.requestId } else { nil }
        }.last)
        _ = try logic.decidePairing(requestID: webRequest, allow: true)
        #expect(try await page(web.port, "POST", "/v1/builds/\(buildID)/sessions", host: LogicHarness.fqdn, origin: own).0 == 201)

        // 직접 연결 리스너에는 설치 페이지가 없다. 같은 출처 규칙은 Host에서 정한 자기 출처로 본다.
        let authority = "\(lan):\(direct.port)"
        let auth = "RD-Device \(enrollment.deviceId).\(enrollment.token)"
        let logsBody = #"{"entries":[{"at":"2026-11-16T00:00:00Z","level":"info","source":"web","message":"direct"}]}"#
        #expect(try await page(direct.port, tls: true, "POST", "/v1/logs", host: authority, origin: "https://" + authority,
                               authorization: auth, body: logsBody).0 == 202)
        #expect(try await page(direct.port, tls: true, "POST", "/v1/logs", host: authority, origin: "https://192.168.1.21:\(direct.port)",
                               authorization: auth, body: logsBody) == (403, "origin_not_allowed"))
    }
}
