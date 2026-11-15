import Foundation
import RDModels
import Testing
@testable import RDHostLogic

@Suite("식별자와 오류")
struct SupportTests {
    @Test("코드는 Crockford 문자 여덟 개이고 충분히 고유")
    func 코드생성() {
        let codes = (0..<1000).map { _ in HostIDs.newPairCode() }
        #expect(Set(codes).count >= 990)
        for code in codes { #expect(code.count == 8 && code.allSatisfy { HostIDs.alphabet.contains($0) }) }
    }
    @Test("코드 정규화 비교와 표시")
    func 코드정규화() {
        let code = "K7M29QXD"
        for input in [code, "K7M2-9QXD", "k7m2-9qxd", " k7m2 9qxd "] { #expect(HostIDs.pairCodeEqual(code, input)) }
        for input in ["", "K7M29QX", "K7M29QXDD", "K7M29QXE", "K7M2_9QXD", "K7M29QXU", "K7M2\t9QXD"] {
            #expect(!HostIDs.pairCodeEqual(code, input))
        }
        #expect(HostIDs.normalizePairCode("ol1i-0000") == "01110000")
        #expect(!HostIDs.pairCodeEqual("SS000000", "ß000000"))
        #expect(HostIDs.displayPairCode(code) == "K7M2-9QXD")
        #expect(HostIDs.displayPairCode("abc") == "abc")
    }
    @Test("토큰과 결정적 식별자")
    func 토큰과식별자() {
        let a = HostIDs.newToken(), b = HostIDs.newToken()
        #expect(a.count == 43 && a != b && !a.contains(where: { "+/=".contains($0) }))
        #expect(HostIDs.directTokenHash(a).count == 64)
        let id = HostIDs.newID("s_")
        #expect(id.count == 10 && id.hasPrefix("s_"))
        #expect(HostIDs.buildID(bundleID: "com.example.app", sha256: String(repeating: "0", count: 64)) == "b_484290ac")
        #expect(HostIDs.buildID(bundleID: "a", sha256: "x") != HostIDs.buildID(bundleID: "b", sha256: "x"))
        #expect(HostIDs.resourceID(name: "a", sha256: "x") != HostIDs.resourceID(name: "b", sha256: "x"))
        #expect(HostIDs.hostID(stableID: "tail0001") == "h_" + digest(Data("rd-host\ntail0001".utf8)).prefix(8))
        for token in ["", "abc", a + "=", String(repeating: "!", count: 43)] { #expect(HostIDs.directTokenHash(token).isEmpty) }
    }
    @Test("주소 형식 매니페스트 이스케이프와 토큰 가리기")
    func 주소와매니페스트() {
        #expect(HostLogic.baseURL(tls: true, fqDN: "rd-mac-1.example.ts.net.", port: 443) == "https://rd-mac-1.example.ts.net")
        #expect(HostLogic.baseURL(tls: true, fqDN: "rd-mac-1.example.ts.net", port: 8443) == "https://rd-mac-1.example.ts.net:8443")
        #expect(HostLogic.baseURL(tls: false, fqDN: "rd-mac-1.example.ts.net", port: 8080) == "http://rd-mac-1.example.ts.net:8080")
        let manifest = HostLogic.manifest(ipaURL: "https://h.ts.net/i/T/app.ipa", bundleID: "com.example.a&b", version: "1.0", title: "<Sample>")
        for string in ["<string>https://h.ts.net/i/T/app.ipa</string>", "<string>com.example.a&amp;b</string>", "<string>&lt;Sample&gt;</string>", "<string>software-package</string>"] {
            #expect(manifest.contains(string))
        }
        #expect(!HostLogic.redactPath("/i/SECRET/app.ipa").contains("SECRET"))
        #expect(HostLogic.redactPath("/v1/info") == "/v1/info")
    }
    @Test("오류는 코드와 메시지만 가진 공유 모델")
    func 오류형식() throws {
        let error = HostErrors.make("not_paired")
        #expect(HostErrors.status(error) == 403)
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(error)) as? [String: [String: String]]
        #expect(raw?.count == 1 && raw?["error"]?.count == 2)
        #expect(raw?["error"]?["code"] == "not_paired")
        #expect(HostErrors.from(error) == error)
        #expect(HostErrors.from(CocoaError(.fileReadUnknown)).error.code == "internal")
        #expect(HostErrors.status(HostErrors.make("hash_mismatch")) == 500)
    }
}

@Suite("유한 사건 큐")
struct EventQueueTests {
    @Test("가장 오래된 사건 제거와 손실 기록")
    func 오래된사건() {
        let queue = HostEventQueue(capacity: 3)
        for index in 0..<5 { queue.push(.unknown(type: "x\(index)")) }
        guard case .log(let log) = queue.next() else { Issue.record("손실 기록 없음"); return }
        #expect(log.level == "warn" && log.message == "event queue full: dropped 2 events")
        for index in 2..<5 { #expect(queue.next()?.type == "x\(index)") }
        #expect(queue.next(timeoutMilliseconds: 1) == nil)
    }
    @Test("새 사건과 닫기는 기다리는 소비자를 깨움")
    func 깨우기() async throws {
        let queue = HostEventQueue()
        let task = Task.detached { queue.next(timeoutMilliseconds: 2000) }
        try await Task.sleep(for: .milliseconds(20))
        queue.push(.unknown(type: "state"))
        #expect(await task.value?.type == "state")
        let next = Task.detached { queue.next(timeoutMilliseconds: 2000) }
        queue.close()
        #expect(await next.value == nil)
        queue.push(.unknown(type: "ignored"))
        #expect(queue.next() == nil)
    }
    @Test("낮은 우선순위부터 버리고 높은 우선순위 보존")
    func 우선순위() {
        let queue = HostEventQueue(capacity: 3)
        queue.push(.unknown(type: "pair-request"))
        queue.push(.denied(.init(path: "/", reason: "not_paired")))
        queue.push(.unknown(type: "session"))
        queue.push(.unknown(type: "device-added"))
        queue.push(.log(.init(level: "info", message: "x")))
        queue.push(.unknown(type: "pair-decided"))
        guard case .log(let log) = queue.next() else { Issue.record("손실 기록 없음"); return }
        #expect(log.message == "event queue full: dropped 3 events")
        #expect(queue.next()?.type == "session")
        #expect(queue.next()?.type == "device-added")
        #expect(queue.next()?.type == "pair-decided")
    }
    @Test("같은 종류 교체는 나머지 순서를 보존")
    func 최신교체() {
        let queue = HostEventQueue()
        queue.push(.unknown(type: "state"))
        queue.replace(.networkSettings(.init(addresses: ["first"], routes: [], dnsServers: [], dnsMatchDomains: [], mtu: 1280)))
        queue.push(.log(.init(level: "info", message: "x")))
        queue.replace(.networkSettings(.init(addresses: ["last"], routes: [], dnsServers: [], dnsMatchDomains: [], mtu: 1280)))
        #expect(queue.next()?.type == "state")
        #expect(queue.next()?.type == "log")
        guard case .networkSettings(let settings) = queue.next() else { Issue.record("설정 사건 없음"); return }
        #expect(settings.addresses == ["last"])
        #expect(queue.next() == nil)
    }
}

@Suite("페어링과 허용 목록")
struct PairingTests {
    @Test("일회용 코드 승인 사건 순서와 신원 결합")
    func 승인() async throws {
        let fixture = try HostFixture(paired: false)
        let code = try fixture.host.openPairing(ttlSeconds: 0)
        #expect(code.expiresAt == fixture.clock.now().addingTimeInterval(300))
        let response = try await fixture.request("POST", "/v1/pair/request", body: jsonText(["code": code.displayCode.lowercased(), "deviceName": "시험 iPhone"]))
        #expect(response.status == 202)
        let state: PairRequestState = try decode(response)
        #expect(state.state == .pending && state.expiresAt == fixture.clock.now().addingTimeInterval(120))
        #expect(fixture.events.next()?.type == "pair-request")
        #expect(try await fixture.request("POST", "/v1/pair/request", body: jsonText(["code": code.code])).status == 403)
        _ = fixture.drain()
        let device = try #require(try fixture.host.decidePairing(requestID: state.requestId, allow: true))
        #expect(device.nodeStableId == HostFixture.peer.stableID && device.name == "시험 iPhone")
        #expect(fixture.drain().map(\.type) == ["device-added", "pair-decided"])
        let status: PairRequestState = try decode(await fixture.request("/v1/pair/request/" + state.requestId))
        #expect(status.state == .approved && status.host?.hostId == "h_1")
        #expect(fixture.host.counts().devices == 1)
        expectError("bad_request") { _ = try fixture.host.decidePairing(requestID: state.requestId, allow: true) }
        let foreign = HostPeer(stableID: "n_other", nodeName: "rd-phone-00000002", loginName: "")
        let denied = await fixture.request("GET", "/v1/pair/request/" + state.requestId, origin: .tailnet(foreign))
        #expect(try denied.status == 403 && (errorCode(denied)) == "not_paired")
    }
    @Test("다섯 번째 실패는 거부하고 다음 시도부터 차단 및 정각 만료")
    func 실패와만료() async throws {
        let fixture = try HostFixture(paired: false)
        let code = try fixture.host.openPairing(ttlSeconds: 10)
        for _ in 0..<5 {
            let response = await fixture.request("POST", "/v1/pair/request", body: #"{"code":"wrong"}"#)
            #expect(try response.status == 403 && (errorCode(response)) == "pair_code_invalid")
        }
        let blocked = try await fixture.request("POST", "/v1/pair/request", body: jsonText(["code": code.code]))
        #expect(try blocked.status == 429 && (errorCode(blocked)) == "too_many_attempts")
        fixture.clock.advance(10)
        let expired = try await fixture.request("POST", "/v1/pair/request", body: jsonText(["code": code.code]))
        #expect(try expired.status == 403 && (errorCode(expired)) == "pair_code_invalid")
        expectError("bad_request") { _ = try fixture.host.openPairing(ttlSeconds: 3601) }
    }
    @Test("보류 요청은 만료되거나 거절되고 오래된 기록은 정리")
    func 보류요청() async throws {
        let fixture = try HostFixture(paired: false)
        let code = try fixture.host.openPairing(ttlSeconds: 5)
        let state: PairRequestState = try decode(await fixture.request("POST", "/v1/pair/request", body: jsonText(["code": code.code])))
        fixture.clock.advance(120)
        fixture.host.sweep()
        let status: PairRequestState = try decode(await fixture.request("/v1/pair/request/" + state.requestId))
        #expect(status.state == .expired)
        expectError("bad_request") { _ = try fixture.host.decidePairing(requestID: state.requestId, allow: true) }
        fixture.clock.advance(3601)
        fixture.host.sweep()
        #expect(await fixture.request("/v1/pair/request/" + state.requestId).status == 403)
        let nextCode = try fixture.host.openPairing(ttlSeconds: -1)
        let next: PairRequestState = try decode(await fixture.request("POST", "/v1/pair/request", body: jsonText(["code": nextCode.code])))
        #expect(try fixture.host.decidePairing(requestID: next.requestId, allow: false) == nil)
        let denied: PairRequestState = try decode(await fixture.request("/v1/pair/request/" + next.requestId))
        #expect(denied.state == .denied)
    }
    @Test("재페어링은 기기 id만 보존하고 직접 토큰과 푸시는 제거")
    func 재페어링() async throws {
        let fixture = try HostFixture()
        try fixture.host.setDevices([fixture.device(hash: String(repeating: "a", count: 64), push: .init(token: "token", bundleId: "com.example.app", environment: "development"))])
        let code = try fixture.host.openPairing(ttlSeconds: 30)
        let state: PairRequestState = try decode(await fixture.request("POST", "/v1/pair/request", body: jsonText(["code": code.code])))
        let device = try #require(try fixture.host.decidePairing(requestID: state.requestId, allow: true))
        #expect(device.id == "d_1" && device.directTokenHash == nil && device.push == nil)
    }
    @Test("잘못된 목록은 기존 목록을 보존하고 마지막 중복 값 사용")
    func 목록검증() throws {
        let fixture = try HostFixture()
        expectError("bad_request") { try fixture.host.setDevices([fixture.device(stableID: "")]) }
        #expect(fixture.host.counts().devices == 1)
        try fixture.host.setDevices([fixture.device(id: "d_first"), fixture.device(id: "d_last")])
        #expect(fixture.host.locked { fixture.host.devices[HostFixture.peer.stableID]?.id } == "d_last")
    }
    @Test("거부 사건은 경로별 다섯 초 제한과 생략 횟수 및 토큰 가림")
    func 거부횟수() async throws {
        let fixture = try HostFixture(paired: false)
        for _ in 0..<4 { #expect(await fixture.request("/v1/info").status == 403) }
        #expect(fixture.drain().count == 1)
        fixture.clock.advance(5)
        _ = await fixture.request("/v1/info")
        guard case .denied(let denied) = fixture.events.next() else { Issue.record("거부 사건 없음"); return }
        #expect(denied.suppressed == 3)
        _ = await fixture.request("/i/SECRET/app.ipa")
        guard case .denied(let redacted) = fixture.events.next() else { Issue.record("거부 사건 없음"); return }
        #expect(redacted.path == "/i/…/app.ipa")
        fixture.clock.advance(5)
        fixture.host.sweep()
        #expect(fixture.host.locked { fixture.host.denials.isEmpty })
    }
}
