import Foundation
import RDModels
import Testing

@testable import PhoneClientKit

@Suite struct HostAPITests {
    let transport = FakeTransport()
    var api: HostAPI {
        HostAPI(host: hostFQDN, transport: transport, client: ClientInfo(osVersion: "26.1", appVersion: "0.1.0"))!
    }

    @Test func refusesHostOutsidePolicy() {
        #expect(HostAPI(host: "example.com", transport: transport, client: ClientInfo(osVersion: "26.1", appVersion: "0.1.0")) == nil)
    }

    @Test func infoSendsClientHeaderToHTTPSHost() async throws {
        transport.on("GET", "/v1/info", .json(Examples.info))
        let info = try await api.info()
        #expect(info.hostId == "h_4be0c7a1")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://\(hostFQDN)/v1/info")
        #expect(request.value(forHTTPHeaderField: "X-RD-Client") == "iOS/26.1")
        #expect(request.httpMethod == "GET")
    }

    @Test func pairingRequestBody() async throws {
        transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        let state = try await api.requestPairing(code: PairingCode("k7m2-9qxd")!, deviceName: "내 iPhone")
        #expect(state.state == .pending)
        #expect(state.expiresAt == t0.addingTimeInterval(420))
        let body = try #require(transport.requests.first?.jsonBody)
        #expect(body["code"] as? String == "K7M29QXD")
        #expect(body["deviceName"] as? String == "내 iPhone")
        #expect(body["platform"] as? String == "iOS 26.1")
        #expect(body["clientVersion"] as? String == "0.1.0")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func pairingFieldsAreClampedToHostLimits() async throws {
        transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        let longName = String(repeating: "가", count: 100)  // 300바이트
        let api = HostAPI(host: hostFQDN, transport: transport, client: ClientInfo(osVersion: String(repeating: "9", count: 300), appVersion: String(repeating: "1", count: 150)))!
        _ = try await api.requestPairing(code: PairingCode("K7M29QXD")!, deviceName: longName)
        let body = try #require(transport.requests.first?.jsonBody)
        let name = try #require(body["deviceName"] as? String)
        #expect(name == String(repeating: "가", count: 66))
        #expect(name.utf8.count <= 200)
        #expect((body["platform"] as? String)?.utf8.count == 200)
        #expect((body["clientVersion"] as? String)?.utf8.count == 100)
    }

    @Test func truncationKeepsCharacters() {
        #expect(HostAPI.truncated("  내 iPhone  ", maxBytes: 200) == "내 iPhone")
        #expect(HostAPI.truncated("ab👍🏽cd", maxBytes: 3) == "ab")
        #expect(HostAPI.truncated("abc", maxBytes: 3) == "abc")
    }

    @Test func requestTimeouts() async throws {
        transport.on("GET", "/v1/info", .json(Examples.info))
        transport.on("POST", "/v1/builds/b_9f3a1c2e/sessions", .json(Examples.sessionCreated, status: 201))
        _ = try await api.info()
        _ = try await api.createSession(buildID: "b_9f3a1c2e")
        #expect(transport.requests.map(\.timeoutInterval) == [10, 60])

        let custom = HostAPI(host: hostFQDN, transport: transport, client: ClientInfo(osVersion: "26.1", appVersion: "0.1.0"), timeouts: .init(request: 5, createSession: 90))!
        _ = try await custom.createSession(buildID: "b_9f3a1c2e")
        #expect(transport.requests.last?.timeoutInterval == 90)
    }

    @Test func emptyAndNullBuilds() async throws {
        transport.on("GET", "/v1/builds", .json(Examples.emptyBuilds), .json(#"{"builds":null}"#), .json(Examples.builds))
        #expect(try await api.builds().isEmpty)
        #expect(try await api.builds().isEmpty)
        #expect(try await api.builds().map(\.id) == ["b_9f3a1c2e"])
    }

    @Test func sessionEndpoints() async throws {
        transport.on("POST", "/v1/builds/b_9f3a1c2e/sessions", .json(Examples.sessionCreated, status: 201))
        transport.on("GET", "/v1/sessions/s_52d9a07e", .json(try Examples.sessionStatus(.downloading, served: 10_485_760)))
        let session = try await api.createSession(buildID: "b_9f3a1c2e")
        #expect(session.installUrl.scheme == "itms-services")
        let status = try await api.sessionStatus(sessionID: session.sessionId)
        #expect(status.bytesServed == 10_485_760)
    }

    @Test func rejectsPathInjectionWithoutSending() async {
        await #expect(throws: HostAPIError.self) { try await api.createSession(buildID: "../info") }
        await #expect(throws: HostAPIError.self) { try await api.pairingState(requestID: "a/b") }
        #expect(transport.requests.isEmpty)
    }

    @Test(arguments: [
        ("not_paired", 403, "이 iPhone은 Mac에서 승인되지 않았습니다. 다시 페어링하세요."),
        ("pair_code_invalid", 403, "페어링 코드가 맞지 않거나 만료되었습니다. Mac에 표시된 코드를 확인하고 다시 입력하세요."),
        ("too_many_attempts", 429, "코드를 너무 많이 틀렸습니다. Mac에서 새 페어링 코드를 연 뒤 다시 시도하세요."),
        ("token_invalid", 403, "설치 세션을 확인할 수 없습니다. 다시 설치하세요."),
        ("session_expired", 410, "설치 세션이 만료되었습니다. 다시 설치하세요."),
        ("build_not_found", 404, "Mac에 이 빌드가 없습니다. 목록을 새로고침하세요."),
        ("build_changed", 409, "Mac에서 빌드가 바뀌었습니다. 목록을 새로고침하세요."),
        ("not_debug_build", 422, "디버그 빌드가 아니라서 설치할 수 없습니다. Mac에서 Debug 빌드를 게시하세요."),
        ("not_found", 404, "Mac 앱이 이 요청을 처리하지 못했습니다. iPhone 앱과 Mac 앱을 최신 버전으로 맞추세요."),
        ("method_not_allowed", 405, "Mac 앱이 이 요청을 처리하지 못했습니다. iPhone 앱과 Mac 앱을 최신 버전으로 맞추세요."),
        ("bad_request", 400, "Mac 앱이 이 요청을 처리하지 못했습니다. iPhone 앱과 Mac 앱을 최신 버전으로 맞추세요."),
        ("internal", 500, "Mac 앱에서 오류가 났습니다. 잠시 뒤 다시 시도하세요."),
    ])
    func hostErrorCodes(_ code: String, _ status: Int, _ message: String) async throws {
        transport.on("GET", "/v1/builds", .error(code, status: status))
        let error = await #expect(throws: HostAPIError.self) { try await api.builds() }
        #expect(error?.status == status)
        #expect(error?.code == code)
        #expect(error?.message == "host says \(code)")
        #expect(error?.userMessage == message)
    }

    @Test func connectionFailures() async throws {
        transport.on("GET", "/v1/info", .fail(.timedOut))
        let e1 = await #expect(throws: HostAPIError.self) { try await api.info() }
        #expect(e1?.code == HostAPIError.timedOutCode)
        #expect(e1?.isConnectionFailure == true)
        #expect(e1?.userMessage == "Mac에 연결할 수 없습니다. iPhone의 VPN이 켜져 있는지, Mac 앱이 공유 중인지 확인하세요.")

        // 로컬 프록시의 평문 거부(X-RD-Protocol 없음)
        transport.on("GET", "/v1/builds", Reply(status: 502, body: "bad gateway", headers: ["Content-Type": "text/plain"]))
        let e2 = await #expect(throws: HostAPIError.self) { try await api.builds() }
        #expect(e2?.code == HostAPIError.connectionFailedCode)
    }

    @Test func cancellationIsNotReportedAsError() async {
        transport.on("GET", "/v1/info", .fail(.cancelled))
        await #expect(throws: CancellationError.self) { try await api.info() }
    }

    @Test func protocolHeaderMustBeOne() async {
        transport.on("GET", "/v1/info", Reply(status: 200, body: Examples.info, headers: ["X-RD-Protocol": "2"]))
        let e1 = await #expect(throws: HostAPIError.self) { try await api.info() }
        #expect(e1?.code == HostAPIError.protocolMismatchCode)

        transport.on("GET", "/v1/builds", Reply(status: 200, body: Examples.emptyBuilds, headers: [:]))
        let e2 = await #expect(throws: HostAPIError.self) { try await api.builds() }
        #expect(e2?.code == HostAPIError.protocolMismatchCode)
    }

    @Test func undecodableBodies() async {
        transport.on("GET", "/v1/info", .json("{}"))
        transport.on("GET", "/v1/builds", .json("<html>", status: 500))
        let e1 = await #expect(throws: HostAPIError.self) { try await api.info() }
        #expect(e1?.code == HostAPIError.invalidResponseCode)
        let e2 = await #expect(throws: HostAPIError.self) { try await api.builds() }
        #expect(e2?.code == HostAPIError.invalidResponseCode)
        #expect(e2?.status == 500)
    }

    @Test func registerPushTokenSendsPut() async throws {
        transport.on("PUT", "/v1/devices/self/push-token", .json(#"{"registered":true}"#))
        try await api.registerPushToken(token: fakePushToken, bundleId: phoneBundleID)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://\(hostFQDN)/v1/devices/self/push-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.jsonBody)
        #expect(body.count == 3)
        #expect(body["token"] as? String == fakePushToken)
        #expect(body["bundleId"] as? String == phoneBundleID)
        #expect(body["environment"] as? String == "development")
    }

    @Test func registerPushTokenNeedsRegisteredTrue() async {
        transport.on("PUT", "/v1/devices/self/push-token", .json(#"{"registered":false}"#))
        let error = await #expect(throws: HostAPIError.self) { try await api.registerPushToken(token: fakePushToken, bundleId: phoneBundleID) }
        #expect(error?.code == HostAPIError.invalidResponseCode)
    }

    @Test func removePushTokenSendsDeleteWithoutBody() async throws {
        transport.on("DELETE", "/v1/devices/self/push-token", .json(#"{"registered":false}"#))
        try await api.removePushToken()
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test func pushTokenOnDirectRouteCarriesAuthorization() async throws {
        let direct = try #require(HostAPI(direct: DirectEndpoint(host: "192.168.0.10", port: 49152), authorization: "RD-Device test-device-token",
                                          transport: transport, client: ClientInfo(osVersion: "26.1", appVersion: "0.1.0")))
        transport.on("PUT", "/v1/devices/self/push-token", .json(#"{"registered":true}"#))
        transport.on("DELETE", "/v1/devices/self/push-token", .json(#"{"registered":false}"#))
        try await direct.registerPushToken(token: fakePushToken, bundleId: phoneBundleID)
        try await direct.removePushToken()
        #expect(transport.requests.count == 2)
        for request in transport.requests {
            #expect(request.url?.absoluteString == "https://192.168.0.10:49152/v1/devices/self/push-token")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "RD-Device test-device-token")
        }
    }

    @Test(arguments: [("not_paired", 403), ("not_found", 404), ("bad_request", 400)])
    func pushTokenErrors(_ code: String, _ status: Int) async {
        transport.on("PUT", "/v1/devices/self/push-token", .error(code, status: status))
        transport.on("DELETE", "/v1/devices/self/push-token", .error(code, status: status))
        let e1 = await #expect(throws: HostAPIError.self) { try await api.registerPushToken(token: fakePushToken, bundleId: phoneBundleID) }
        #expect(e1?.code == code)
        #expect(e1?.status == status)
        let e2 = await #expect(throws: HostAPIError.self) { try await api.removePushToken() }
        #expect(e2?.code == code)
    }

    @Test func pairedHostCodableRoundTrip() throws {
        let data = try RDJSON.encoder().encode(Harness.pairedHostValue)
        #expect(String(decoding: data, as: UTF8.self).contains("2026-11-11T09:00:00Z"))
        #expect(try RDJSON.decoder().decode(PairedHost.self, from: data) == Harness.pairedHostValue)
    }

    @Test @MainActor func inMemoryStore() throws {
        let store = InMemoryPairedHostStore()
        #expect(store.load() == nil)
        try store.save(Harness.pairedHost)
        #expect(store.load() == Harness.pairedHost)
        store.clear()
        #expect(store.load() == nil)
    }
}

extension Harness {
    nonisolated static var pairedHostValue: PairedHost {
        PairedHost(hostId: "h_4be0c7a1", hostName: "작업용 Mac", fqdn: hostFQDN, pairedAt: t0)
    }
}
