import CryptoKit
import Foundation
import RDModels
import Synchronization
import Testing
@testable import MacHostKit

/// 실제 네트워크 대신 요청을 기록하고 정해 둔 응답을 돌려준다.
final class FakeAPNsTransport: APNsTransport {
    enum Reply: Sendable {
        case status(Int, String)
        case failure
    }

    struct State {
        var requests: [URLRequest] = []
        /// 차례대로 꺼낸다. 비면 200.
        var replies: [Reply] = []
        /// 토큰별 응답(차례 응답보다 먼저 본다).
        var perToken: [String: Reply] = [:]
        /// 있으면 요청을 기록한 뒤 이 문이 열릴 때까지 답하지 않는다.
        var gate: Gate?
    }

    let state = Mutex(State())

    init(_ replies: [Reply] = []) { state.withLock { $0.replies = replies } }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (reply, gate): (Reply, Gate?) = state.withLock { s in
            s.requests.append(request)
            let token = request.url?.lastPathComponent ?? ""
            if let r = s.perToken[token] { return (r, s.gate) }
            return (s.replies.isEmpty ? .status(200, "") : s.replies.removeFirst(), s.gate)
        }
        if let gate { await gate.wait() }
        switch reply {
        case .status(let code, let reason):
            return (code, reason.isEmpty ? Data() : Data(#"{"reason":"\#(reason)"}"#.utf8))
        case .failure:
            throw URLError(.notConnectedToInternet)
        }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

let testToken = String(repeating: "0123abcd", count: 8)
let testRegistration = PushRegistration(token: testToken, bundleId: "com.oozoofrog.app.RemoteDebugPhone", environment: "development")

struct NotJSONObject: Error {}

/// JSON 객체로 읽는다. 없거나 객체가 아니면 실패.
func jsonDict(_ data: Data?) throws -> [String: Any] {
    guard let data, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotJSONObject() }
    return object
}

func decodeBase64URL(_ text: String) -> Data? {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}

@Suite("APNs 전송")
struct APNsClientTests {
    let key = P256.Signing.PrivateKey()
    let clock = TestClock()

    func client(_ transport: FakeAPNsTransport) -> APNsClient {
        let clock = self.clock
        return APNsClient(keyID: "KEY0000001", teamID: "TEAM000001", privateKey: key, transport: transport, now: { clock.now })
    }

    func jwt(of request: URLRequest) -> String {
        String(request.value(forHTTPHeaderField: "authorization")?.dropFirst("bearer ".count) ?? "")
    }

    @Test func requestMatchesTheContract() async throws {
        let transport = FakeAPNsTransport()
        let result = await client(transport).send(APNsNotification(title: "새 빌드", body: "Sample 1.0 (1)", kind: .build, id: "b_1"), to: testRegistration)
        #expect(result == .sent)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/\(testToken)")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apns-topic") == "com.oozoofrog.app.RemoteDebugPhone")
        #expect(request.value(forHTTPHeaderField: "apns-push-type") == "alert")
        #expect(request.value(forHTTPHeaderField: "apns-priority") == "10")
        #expect(request.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ") == true)

        let body = try jsonDict(request.httpBody)
        let aps = try #require(body["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: String])
        #expect(alert == ["title": "새 빌드", "body": "Sample 1.0 (1)"])
        #expect(aps["sound"] as? String == "default")
        #expect(body["rd"] as? [String: String] == ["kind": "build", "id": "b_1"])
    }

    @Test func payloadOmitsMissingID() throws {
        let data = APNsNotification(title: "새 파일", body: "파일 3개", kind: .resource).payload()
        let body = try jsonDict(data)
        #expect(body["rd"] as? [String: String] == ["kind": "resource"])
    }

    @Test func jwtCarriesKeyTeamAndAValidSignature() async throws {
        let transport = FakeAPNsTransport()
        _ = await client(transport).send(PushPlanner.test, to: testRegistration)
        let token = jwt(of: try #require(transport.requests.first))
        let parts = token.split(separator: ".").map(String.init)
        try #require(parts.count == 3)
        let header = try jsonDict(decodeBase64URL(parts[0]))
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "KEY0000001")
        let claims = try jsonDict(decodeBase64URL(parts[1]))
        #expect(claims["iss"] as? String == "TEAM000001")
        #expect(claims["iat"] as? Int == Int(clock.now.timeIntervalSince1970))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(decodeBase64URL(parts[2])))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func jwtIsReusedForFiftyMinutes() async throws {
        let transport = FakeAPNsTransport()
        let c = client(transport)
        _ = await c.send(PushPlanner.test, to: testRegistration)
        clock.advance(49 * 60)
        _ = await c.send(PushPlanner.test, to: testRegistration)
        clock.advance(2 * 60)
        _ = await c.send(PushPlanner.test, to: testRegistration)
        let tokens = transport.requests.map(jwt)
        #expect(tokens.count == 3)
        #expect(tokens[0] == tokens[1])
        #expect(tokens[1] != tokens[2])
    }

    @Test func responsesAreClassified() async {
        let cases: [(FakeAPNsTransport.Reply, APNsResult)] = [
            (.status(200, ""), .sent),
            (.status(410, "Unregistered"), .invalidToken(reason: "Unregistered")),
            (.status(400, "BadDeviceToken"), .invalidToken(reason: "BadDeviceToken")),
            (.status(400, "BadTopic"), .rejected(status: 400, reason: "BadTopic")),
            (.status(403, "InvalidProviderToken"), .rejected(status: 403, reason: "InvalidProviderToken")),
        ]
        for (reply, expected) in cases {
            let result = await client(FakeAPNsTransport([reply])).send(PushPlanner.test, to: testRegistration)
            #expect(result == expected)
        }
        let offline = await client(FakeAPNsTransport([.failure])).send(PushPlanner.test, to: testRegistration)
        guard case .networkFailure = offline else {
            Issue.record("네트워크 실패로 나와야 한다: \(offline)")
            return
        }
    }

    @Test func expiredProviderTokenRetriesOnceWithANewJWT() async {
        let transport = FakeAPNsTransport([.status(403, "ExpiredProviderToken"), .status(200, "")])
        #expect(await client(transport).send(PushPlanner.test, to: testRegistration) == .sent)
        let tokens = transport.requests.map(jwt)
        #expect(tokens.count == 2)
        #expect(tokens[0] != tokens[1])

        let again = FakeAPNsTransport([.status(403, "ExpiredProviderToken"), .status(403, "ExpiredProviderToken"), .status(200, "")])
        #expect(await client(again).send(PushPlanner.test, to: testRegistration) == .rejected(status: 403, reason: "ExpiredProviderToken"))
        #expect(again.requests.count == 2, "한 번만 다시 보낸다")
    }

    @Test func nonHexTokenIsNeverSent() async {
        let transport = FakeAPNsTransport()
        var bad = testRegistration
        bad.token = "../evil"
        #expect(await client(transport).send(PushPlanner.test, to: bad) == .invalidToken(reason: "BadDeviceToken"))
        #expect(transport.requests.isEmpty)
    }

    @Test func keyParsingAcceptsPKCS8AndRejectsOthers() throws {
        let pem = key.pemRepresentation
        #expect(pem.hasPrefix("-----BEGIN PRIVATE KEY-----"))
        #expect(try APNsKey.parse(pem).publicKey.rawRepresentation == key.publicKey.rawRepresentation)
        #expect(throws: APNsKeyFailure.notP256Key) { try APNsKey.parse("not a key") }
        #expect(APNsKey.normalizedID(" abc123defg ") == "ABC123DEFG")
        #expect(APNsKey.normalizedID("short") == nil)
        #expect(APNsKey.normalizedID("ABC-123DEF") == nil)
    }
}
