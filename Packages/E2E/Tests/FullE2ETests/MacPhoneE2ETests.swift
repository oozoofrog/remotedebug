import Foundation
import MacHostKit
import PhoneClientKit
import RDBuildInspection
import RDModels
import RDPackaging
import Testing

/// 실제 Mac(`HostModel` + `RDCoreHost` + Go 코어)과 실제 iPhone 로직(`ClientModel` + `HostAPI`)을 HTTP로 잇는다.
///
/// 경로: `ClientModel` → `HostAPI` → `TailnetTransport`(주소만 우회, `URLSessionTransport`로 실제 HTTP) →
/// 루프백 → `rdtestenv forward`(가짜 tailnet의 iPhone 노드) → tailnet → Mac 코어의 리스너.
///
/// 이 시험이 대신하는 것: TLS(코어는 평문 8080, protocol §11), 터널·NetworkExtension(`ConnectedTunnel`),
/// iOS 설치기(`InstallerPlayer`), 실제 제어 서버(`rdtestenv control`). 주소 우회는 `TailnetTransport`의 주석을 본다.
@MainActor
@Suite("Mac-iPhone E2E", .serialized)
struct MacPhoneE2ETests {
    @Test(.timeLimit(.minutes(10)))
    func macAndPhoneAgreeOverHTTP() async throws {
        HardLimit.arm(seconds: E2EEnv.hardLimitSeconds)
        let binary = try E2EEnv.rdtestenv()
        let tmp = try E2EEnv.directory("RD_E2E_TMPDIR")
        let logs = try E2EEnv.directory("RD_E2E_LOG_DIR")
        let report = ScenarioReport(directory: logs)
        defer { ChildRegistry.terminateAll() }

        let world = try await World.start(binary: binary, tmp: tmp, logs: logs)
        do {
            try await Flow(world: world, report: report).run()
        } catch is ScenarioReport.Aborted {
            Issue.record("시나리오가 중단되어 뒤 시나리오를 돌리지 않았다")
        } catch {
            Issue.record("예기치 못한 오류: \(error)")
        }
        await world.finish()
    }
}

/// 시나리오들이 차례로 쌓아 가는 상태.
@MainActor
final class Flow {
    let world: World
    let report: ScenarioReport
    let phoneA: Phone
    let phoneB: Phone
    var mac: HostModel { world.mac }
    var fqdn: String { world.fqdn }
    private var build: BuildDescriptor?
    private var rejectedApps: [URL] = []
    private var theftSessionID = ""
    private var theftManifest: URL?

    init(world: World, report: ScenarioReport) {
        self.world = world
        self.report = report
        phoneA = Phone(deviceName: "E2E iPhone", transport: world.transportA)
        phoneB = Phone(deviceName: "E2E Second iPhone", transport: world.transportB)
    }

    func run() async throws {
        try await report.run(1, "페어링 전 목록 요청은 403 not_paired") { try await beforePairing($0) }
        try await report.run(2, "페어링 승인") { try await pairingApproved($0) }
        try await report.run(3, "페어링 거절") { try await pairingDenied($0) }
        try await report.run(4, "빌드 목록") { try await buildList($0) }
        try await report.run(5, "설치와 설치 창 닫기") { try await install($0) }
        try await report.run(6, "다른 노드의 토큰 도용") { try await tokenTheft($0) }
        try await report.run(7, "기기 제거") { try await deviceRemoval($0) }
        try await report.run(8, "비디버그 빌드는 게시되지 않는다") { try await nonDebugBuilds($0) }
        try await report.run(9, "Mac 종료") { try await shutdown($0) }
    }

    private func descriptor() throws -> BuildDescriptor {
        guard let build else { throw E2EError("앞 시나리오에서 게시한 빌드가 없다") }
        return build
    }

    private func hasActivity(_ matches: (ActivityItem.Kind) -> Bool) -> Bool {
        mac.activity.contains { matches($0.kind) }
    }

    private func waitForDenied(path: String, reason: String, node: String) async throws {
        try await until("denied(\(reason), \(path), \(node))가 활동에 온다") {
            hasActivity {
                if case .denied(let event) = $0 { event.path == path && event.reason == reason && event.nodeName == node } else { false }
            }
        }
    }

    private func waitForSession(_ id: String, state: SessionState) async throws -> SessionEvent {
        var found: SessionEvent?
        try await until("세션 \(state)이 활동에 온다") {
            for item in mac.activity {
                if case .session(let event) = item.kind, event.sessionId == id, event.state == state {
                    found = event
                    return true
                }
            }
            return false
        }
        return found!
    }

    /// 다음 페어링 요청 하나가 Mac에 뜰 때까지 기다린다.
    private func waitForPairRequest(node: String) async throws -> PairRequestEvent {
        var found: PairRequestEvent?
        try await until("\(node)의 pair-request가 온다", timeout: .seconds(30)) {
            found = mac.pendingPairRequests.first { $0.nodeName == node }
            return found != nil
        }
        return found!
    }

    private func opener(_ phone: Phone, reaches count: Int) async throws {
        try await until("설치 창이 \(count)번 열린다") { phone.opener.opened.count >= count }
    }

    /// 세션 상태 조회 응답 중 `state`인 것이 `count`개가 될 때까지 기다린다. 폴링은 순서대로 도므로
    /// `count`번째 응답이 보이면 그 앞 응답은 모델이 이미 처리했다.
    private func waitForPolls(_ phone: Phone, session id: String, state: String, count: Int) async throws {
        try await until("세션 조회에서 \(state)을 \(count)번 받는다") {
            phone.transport.exchanges("GET") { $0 == "/v1/sessions/\(id)" }.filter { $0.json?["state"] as? String == state }.count >= count
        }
    }

    // MARK: 1

    private func beforePairing(_ s: Scenario) async throws {
        // 페어링을 모르는 iPhone이 목록을 요청한다.
        let api = try phoneA.api()
        do {
            _ = try await api.builds()
            s.fail("페어링 전 목록 요청이 성공했다")
        } catch let error as HostAPIError {
            s.equal(error.status, 403, "HostAPI 오류 상태")
            s.equal(error.code, "not_paired", "HostAPI 오류 코드")
            s.equal(error.userMessage, ProductText.notPaired, "안내 문장")
        }
        s.response(world.transportA.exchanges("GET") { $0 == "/v1/builds" }.last, status: 403, code: "not_paired", "GET /v1/builds")

        // 저장된 호스트가 있지만 Mac은 이 노드를 모른다(앱 복원 경로). 모델은 먼저 /v1/info를 부른다.
        let stale = Phone(deviceName: "E2E iPhone", transport: world.transportA,
                          savedHost: PairedHost(hostId: "h_unknown", hostName: "E2E Mac", fqdn: fqdn, pairedAt: Date()))
        await stale.model.restore()
        s.equal(stale.model.refreshError, ProductText.notPaired, "새로고침 안내")
        s.equal(stale.model.lastError, ProductText.notPaired, "마지막 오류")
        s.check(stale.model.builds.isEmpty, "목록이 비어 있다")
        s.check(stale.model.buildsLoadedAt == nil, "목록을 받았다고 표시하지 않는다")
        s.response(world.transportA.exchanges("GET") { $0 == "/v1/info" }.last, status: 403, code: "not_paired", "GET /v1/info")

        try await waitForDenied(path: "/v1/builds", reason: "not_paired", node: World.nodeA)
        try await waitForDenied(path: "/v1/info", reason: "not_paired", node: World.nodeA)
        s.check(true, "Mac 활동에 denied(not_paired)가 남았다")
        s.check(mac.devices.isEmpty, "Mac 허용 목록이 비어 있다")
    }

    // MARK: 2

    private func pairingApproved(_ s: Scenario) async throws {
        await mac.beginPairing()
        s.equal(mac.lastError, nil, "beginPairing 오류")
        let url = try world.link()
        let code = try #require(mac.pairingCode)
        s.equal(url.absoluteString, "remotedebug://pair?host=\(fqdn)&code=\(code.code)", "링크 꼴(protocol §2)")
        s.equal(code.code.count, 8, "코드 길이")

        // Mac이 만든 링크를 iPhone의 출하 정책으로 읽는다.
        let link = try PairingLink.parse(url: url, policy: .tailnetOnly)
        s.equal(link.host, fqdn, "링크 호스트")
        s.equal(link.code.normalized, code.code, "링크 코드")

        phoneA.model.pair(link: link)
        let request = try await waitForPairRequest(node: World.nodeA)
        s.equal(request.deviceName, phoneA.deviceName, "Mac의 기기 이름")
        s.equal(request.nodeName, World.nodeA, "Mac의 노드 이름")
        s.equal(mac.pairingState, .requestReceived(requestId: request.requestId), "Mac 페어링 단계")
        s.check(mac.pairingCode == nil, "쓰인 코드는 더 보이지 않는다")
        s.check(mac.devices.isEmpty, "승인 전 허용 목록이 비어 있다")
        try await until("iPhone이 승인 대기로 간다") { phoneA.model.phase == .waitingApproval(deviceName: phoneA.deviceName) }
        s.check(phoneA.model.host == nil, "승인 전 호스트가 저장되지 않는다")
        s.check(phoneA.store.host == nil, "승인 전 저장소가 비어 있다")
        // 양쪽의 시간 제한이 같다: iPhone의 마감은 호스트가 알린 요청 만료(protocol §4.3의 120초)다.
        s.equal(phoneA.model.pairingExpiresAt, request.expiresAt, "iPhone의 승인 마감과 Mac의 요청 만료")

        let requestExchange = world.transportA.exchanges("POST") { $0 == "/v1/pair/request" }.last
        s.response(requestExchange, status: 202, "POST /v1/pair/request")
        s.keys(requestExchange?.json, ["requestId", "state", "expiresAt"], "페어링 요청 응답")
        s.equal(requestExchange?.json?["state"] as? String, "pending", "페어링 요청 state")
        s.utcTimestamp(requestExchange?.json?["expiresAt"], "페어링 요청 expiresAt")
        s.keys(requestExchange?.requestJSON, ["code", "deviceName", "platform", "clientVersion"], "페어링 요청 본문")
        s.equal(requestExchange?.requestJSON?["code"] as? String, code.code, "보낸 코드")
        s.equal(requestExchange?.requestJSON?["platform"] as? String, "iOS 26.1", "보낸 플랫폼")
        s.equal(requestExchange?.requestJSON?["clientVersion"] as? String, "0.1.0", "보낸 앱 버전")
        s.equal(requestExchange?.requestHeaders["X-RD-Client"], "iOS/26.1", "X-RD-Client")
        s.equal(requestExchange?.requestHeaders["Content-Type"], "application/json", "요청 Content-Type")

        await mac.approve(request.requestId)
        s.equal(mac.lastError, nil, "approve 오류")
        try await until("iPhone이 페어링된다") { phoneA.model.phase == .paired }
        try await until("승인 뒤 첫 목록을 받는다") { phoneA.model.buildsLoadedAt != nil }
        s.equal(mac.devices.count, 1, "Mac 기기 수")
        s.equal(mac.devices.first?.name, phoneA.deviceName, "Mac 기기 이름")
        s.equal(mac.devices.first?.nodeName, World.nodeA, "Mac 기기 노드")
        s.equal(mac.lastPairingOutcome?.kind, .allowed, "Mac 결과")
        s.equal(phoneA.store.host?.fqdn, fqdn, "저장한 호스트 주소")
        s.equal(phoneA.model.host?.hostName, "E2E Mac", "호스트 이름")
        s.equal(phoneA.model.lastError, nil, "iPhone 오류")

        let approved = world.transportA.exchanges("GET") { $0 == "/v1/pair/request/\(request.requestId)" }.last
        s.response(approved, status: 200, "GET /v1/pair/request/{id}")
        s.keys(approved?.json, ["requestId", "state", "host"], "승인 상태 응답")
        s.equal(approved?.json?["state"] as? String, "approved", "승인 state")
        s.keys(approved?.json?["host"] as? [String: Any], ["hostId", "hostName", "fqdn"], "승인 host")
        s.equal((approved?.json?["host"] as? [String: Any])?["fqdn"] as? String, fqdn, "승인 fqdn")

        let info = world.transportA.exchanges("GET") { $0 == "/v1/info" }.last
        s.response(info, status: 200, "GET /v1/info")
        s.keys(info?.json, ["hostId", "hostName", "fqdn", "protocol", "appVersion", "buildCount"], "/v1/info")
        s.equal(info?.json?["protocol"] as? Int, 1, "protocol")
        s.equal(info?.json?["appVersion"] as? String, "0.1.0", "appVersion")
        s.equal(info?.json?["hostId"] as? String, phoneA.store.host?.hostId, "저장한 hostId")
        s.equal(info?.json?["buildCount"] as? Int, 0, "게시 전 buildCount")

        // 같은 코드를 다른 노드가 다시 쓴다.
        phoneB.model.pair(link: link)
        try await until("다른 노드의 재사용이 거부된다") { phoneB.model.lastError != nil }
        s.equal(phoneB.model.lastError, ProductText.pairCodeInvalid, "재사용 안내")
        s.equal(phoneB.model.phase, .unpaired, "재사용한 노드 단계")
        s.response(world.transportB.exchanges("POST") { $0 == "/v1/pair/request" }.last, status: 403, code: "pair_code_invalid", "재사용 POST /v1/pair/request")
        s.equal(mac.devices.count, 1, "재사용 뒤 Mac 기기 수")
        try await waitForDenied(path: "/v1/pair/request", reason: "pair_code_invalid", node: World.nodeB)
        s.check(true, "Mac 활동에 denied(pair_code_invalid)가 남았다")
    }

    // MARK: 3

    private func pairingDenied(_ s: Scenario) async throws {
        try await wrongCodes(s)
        phoneB.model.clearError()
        await mac.beginPairing()
        let link = try PairingLink.parse(url: try world.link(), policy: .tailnetOnly)
        phoneB.model.pair(link: link)
        let request = try await waitForPairRequest(node: World.nodeB)
        s.equal(request.deviceName, phoneB.deviceName, "Mac의 기기 이름")
        try await until("iPhone이 승인 대기로 간다") { phoneB.model.phase == .waitingApproval(deviceName: phoneB.deviceName) }

        await mac.deny(request.requestId)
        s.equal(mac.lastError, nil, "deny 오류")
        try await until("거절이 iPhone에 닿는다") { phoneB.model.lastError != nil }
        s.equal(phoneB.model.lastError, ClientModel.pairingDeniedMessage, "거절 안내")
        s.equal(phoneB.model.phase, .unpaired, "거절된 노드 단계")
        s.check(phoneB.model.host == nil, "호스트가 저장되지 않는다")
        s.check(phoneB.store.host == nil, "저장소가 비어 있다")
        s.equal(mac.devices.map(\.nodeName), [World.nodeA], "거절 뒤 허용 목록")
        s.equal(mac.lastPairingOutcome?.kind, .denied, "Mac 결과")

        let denied = world.transportB.exchanges("GET") { $0 == "/v1/pair/request/\(request.requestId)" }.last
        s.response(denied, status: 200, "GET /v1/pair/request/{id}")
        s.keys(denied?.json, ["requestId", "state"], "거절 상태 응답")
        s.equal(denied?.json?["state"] as? String, "denied", "거절 state")

        do {
            _ = try await phoneB.api().builds()
            s.fail("거절된 노드의 목록 요청이 성공했다")
        } catch let error as HostAPIError {
            s.equal(error.code, "not_paired", "거절된 노드의 오류 코드")
        }
        try await until("거절 결과가 활동에 남는다") {
            hasActivity {
                if case .pairDecided(let event) = $0 { event.requestId == request.requestId && event.state == .denied } else { false }
            }
        }
    }

    /// 틀린 코드 5번이면 코드를 폐기하고 그 뒤로 429다(protocol §2, addenda B.3).
    private func wrongCodes(_ s: Scenario) async throws {
        await mac.beginPairing()
        let open = try #require(mac.pairingCode)
        let wrongText = (open.code.first == "0" ? "1" : "0") + open.code.dropFirst()
        guard let wrong = PhoneClientKit.PairingCode(wrongText) else { throw E2EError("틀린 코드를 만들지 못했다") }
        let api = try phoneB.api()
        for attempt in 1...5 {
            do {
                _ = try await api.requestPairing(code: wrong, deviceName: phoneB.deviceName)
                s.fail("틀린 코드 \(attempt)번째가 받아들여졌다")
            } catch let error as HostAPIError {
                s.equal(error.status, 403, "틀린 코드 \(attempt)번째 상태")
                s.equal(error.code, "pair_code_invalid", "틀린 코드 \(attempt)번째 코드")
            }
        }
        // 폐기 뒤에는 맞는 코드를 사람이 입력해도 받지 않는다.
        phoneB.model.clearError()
        phoneB.model.pair(code: open.displayCode, host: fqdn)
        try await until("폐기된 코드가 거부된다") { phoneB.model.lastError != nil }
        s.equal(phoneB.model.lastError, ProductText.api("too_many_attempts"), "폐기 뒤 안내")
        s.equal(phoneB.model.phase, .unpaired, "폐기 뒤 단계")
        s.response(world.transportB.exchanges("POST") { $0 == "/v1/pair/request" }.last, status: 429, code: "too_many_attempts", "폐기 뒤 POST /v1/pair/request")
        // 판정에 쓰지 않는 관찰: `denied` 이벤트 속도 제한(addenda D.1) 때문에 Mac이 폐기를 모를 수 있다.
        try? await until("Mac이 폐기된 코드를 내린다", timeout: .seconds(2)) { mac.pairingCode == nil }
        report.write("S3 관찰: 폐기 뒤 Mac의 pairingState = \(mac.pairingCode == nil ? "코드 없음" : "코드를 계속 보여 줌")")
    }

    // MARK: 4

    private func buildList(_ s: Scenario) async throws {
        s.check(phoneA.model.builds.isEmpty, "가져오기 전 목록은 비어 있다")
        let fixtures = E2EEnv.fixtures.appendingPathComponent("Debug-iphoneos", isDirectory: true)
        let source = fixtures.appendingPathComponent("AcceptedDev.app")
        guard case .accepted(let accepted) = await mac.importBuild(source) else {
            throw E2EError("AcceptedDev가 수락되지 않았다: \(mac.rejected), \(mac.lastError ?? "")")
        }
        build = accepted.descriptor

        let release = world.tmp.appendingPathComponent("Release-iphoneos/AcceptedDev.app")
        try FileManager.default.createDirectory(at: release.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: release)
        let refused: [(URL, RejectionCode)] = [
            (release, .configurationNotDebug),
            (fixtures.appendingPathComponent("AdHocDist.app"), .notDevelopmentProfile),
            (fixtures.appendingPathComponent("Expired.app"), .profileExpired),
            (fixtures.appendingPathComponent("Unsigned.app"), .unsigned),
        ]
        for (url, code) in refused {
            guard case .rejected(let rejected) = await mac.importBuild(url) else {
                s.fail("\(url.lastPathComponent)가 거부되지 않았다")
                continue
            }
            s.check(rejected.codes.contains(code), "\(url.lastPathComponent)의 거부 사유 \(code)")
        }
        rejectedApps = refused.map(\.0).filter { $0 != release }
        s.equal(mac.builds.map(\.id), [accepted.id], "Mac의 게시 목록")
        s.equal(mac.rejected.count, refused.count, "Mac의 거부 목록")

        await phoneA.model.refresh()
        s.equal(phoneA.model.refreshError, nil, "새로고침 오류")
        let listed = phoneA.model.builds
        s.equal(listed.map(\.id), [accepted.id], "iPhone 목록")
        let macBuild = accepted.descriptor
        s.equal(listed.first?.displayName, macBuild.displayName, "이름")
        s.equal(listed.first?.version, macBuild.version, "버전")
        s.equal(listed.first?.buildNumber, macBuild.buildNumber, "빌드 번호")
        s.equal(listed.first?.signing, macBuild.signing, "서명 요약")
        s.equal(listed.first?.ipa.size, macBuild.ipa.size, "IPA 크기")
        s.equal(listed.first?.ipa.sha256, macBuild.ipa.sha256, "IPA SHA-256")
        // 전송 형식(protocol 머리말: 초 단위 시각)으로 비교한다. Mac의 메모리 값은 소수 초를 갖고 있다.
        s.equal(try listed.first.map { try RDJSON.encoder().encode($0) }, try RDJSON.encoder().encode(macBuild), "빌드 설명 전체(전송 형식)")
        s.equal(macBuild.id, BuildDescriptor.makeID(bundleId: macBuild.bundleId, ipaSHA256: macBuild.ipa.sha256), "id 규칙(protocol §4.1)")

        let raw = world.transportA.exchanges("GET") { $0 == "/v1/builds" }.last
        s.response(raw, status: 200, "GET /v1/builds")
        s.keys(raw?.json, ["builds"], "/v1/builds")
        let first = (raw?.json?["builds"] as? [[String: Any]])?.first
        s.keys(first, ["id", "bundleId", "displayName", "version", "buildNumber", "minOS", "debug", "configuration",
                       "configurationEvidence", "signing", "ipa", "publishedAt"], "BuildDescriptor")
        s.keys(first?["signing"] as? [String: Any], ["teamId", "profileName", "profileExpires", "provisionedDeviceCount", "getTaskAllow"], "signing")
        s.keys(first?["ipa"] as? [String: Any], ["size", "sha256"], "ipa")
        s.utcTimestamp(first?["publishedAt"], "publishedAt")
        s.utcTimestamp((first?["signing"] as? [String: Any])?["profileExpires"], "profileExpires")
        s.equal(first?["configuration"] as? String, "Debug", "configuration")
        s.equal(first?["configurationEvidence"] as? String, "path", "configurationEvidence")
        s.equal(first?["debug"] as? Bool, true, "debug")
        s.equal(world.transportA.exchanges("GET") { $0 == "/v1/info" }.last?.json?["buildCount"] as? Int, 1, "게시 뒤 buildCount")
        await mac.refreshStatus()
        s.equal(mac.status?.publishedBuilds, 1, "코어의 게시 수")
        s.equal(mac.status?.pairedDevices, 1, "코어의 기기 수")
    }

    // MARK: 5

    private func install(_ s: Scenario) async throws {
        let build = try descriptor()
        let id = build.id
        let opener = phoneA.opener

        // 5-1. 끝까지 설치한다.
        phoneA.model.install(build)
        try await self.opener(phoneA, reaches: 1)
        try await until("설치기를 기다리는 상태가 된다") { phoneA.model.installs[id] == .waitingForInstaller }
        let created = world.transportA.exchanges("POST") { $0 == "/v1/builds/\(id)/sessions" }.last
        s.response(created, status: 201, "POST /v1/builds/{id}/sessions")
        s.keys(created?.json, ["sessionId", "state", "manifestUrl", "installUrl", "expiresAt"], "세션 생성 응답")
        s.equal(created?.json?["state"] as? String, "created", "세션 state")
        s.utcTimestamp(created?.json?["expiresAt"], "세션 expiresAt")
        let sessionExpiry = (created?.json?["expiresAt"] as? String).flatMap(RDTimestamp.parse)?.timeIntervalSinceNow ?? 0
        s.check((165...181).contains(sessionExpiry), "세션 만료는 생성 후 180초다: \(sessionExpiry)")
        let sessionID = try #require(created?.json?["sessionId"] as? String)

        let installURL = try #require(opener.opened.first)
        s.equal(installURL.scheme, "itms-services", "설치 주소 스킴")
        let manifestURL = try InstallerPlayer.manifestURL(fromInstallURL: installURL)
        let token = try tokenOf(manifestURL)
        s.equal(token.count, 43, "토큰 길이(protocol §4.4)")
        s.equal(created?.json?["manifestUrl"] as? String, "\(world.transportA.plainBase)/i/\(token)/manifest.plist", "평문 시험 호스트의 manifestUrl")

        let manifestReply = try await phoneA.installer.fetch(manifestURL)
        s.equal(manifestReply.status, 200, "매니페스트 상태")
        s.equal(manifestReply.contentType, "text/xml", "매니페스트 Content-Type")
        let manifestRaw = world.transportA.exchanges("GET") { $0 == "/i/\(token)/manifest.plist" }.last
        s.response(manifestRaw, status: 200, "GET /i/{token}/manifest.plist")
        let manifest = try InstallerPlayer.parseManifest(manifestReply.body)
        s.equal(manifest.bundleID, build.bundleId, "매니페스트 bundle-identifier")
        s.equal(manifest.version, build.version, "매니페스트 bundle-version")
        s.equal(manifest.title, build.displayName, "매니페스트 title")
        s.equal(manifest.kind, "software", "매니페스트 kind")
        s.equal(manifest.ipaURL.absoluteString, "\(world.transportA.tlsBase)/i/\(token)/app.ipa", "매니페스트의 IPA 주소")
        let rawManifest = try InstallerPlayer.parseManifest(try #require(manifestRaw?.rawBody))
        s.equal(rawManifest.ipaURL.absoluteString, "\(world.transportA.plainBase)/i/\(token)/app.ipa", "평문 시험 호스트의 IPA 주소")

        // manifest_served는 아직 설치기를 기다리는 상태다. 그 응답을 모델이 처리한 뒤에 본다.
        _ = try await waitForSession(sessionID, state: .manifestServed)
        try await waitForPolls(phoneA, session: sessionID, state: "manifest_served", count: 2)
        s.equal(phoneA.model.installs[id], .waitingForInstaller, "매니페스트만 받은 뒤의 상태")

        // HEAD는 세션 상태를 바꾸지 않는다(addenda B.4).
        let size = build.ipa.size
        let half = size / 2
        let probe = try await phoneA.installer.fetch(manifest.ipaURL, method: "HEAD")
        s.equal(probe.status, 200, "HEAD 상태")
        s.equal(probe.contentLength, String(size), "HEAD Content-Length")
        s.equal(probe.acceptRanges, "bytes", "HEAD Accept-Ranges")
        let pollsAfterHead = phoneA.transport.exchanges("GET") { $0 == "/v1/sessions/\(sessionID)" }.filter { $0.json?["state"] as? String == "manifest_served" }.count
        try await waitForPolls(phoneA, session: sessionID, state: "manifest_served", count: pollsAfterHead + 1)
        s.equal(phoneA.model.installs[id], .waitingForInstaller, "HEAD 뒤의 상태")

        // IPA 앞 절반만 받으면 전송 중이다(addenda C.2: 범위를 합쳐 전체를 덮어야 완료).
        let head = try await phoneA.installer.fetch(manifest.ipaURL, range: 0...(half - 1))
        s.equal(head.status, 206, "앞 절반 상태")
        s.equal(head.contentType, "application/octet-stream", "IPA Content-Type")
        s.equal(head.contentRange, "bytes 0-\(half - 1)/\(size)", "앞 절반 Content-Range")
        try await until("iPhone이 전송 중을 보여 준다") { phoneA.model.installs[id] == .transferring(bytesServed: half, size: size) }
        s.equal(phoneA.model.installProgress(for: id), InstallProgress(bytesServed: half, size: size), "전송 진행")
        let downloading = try await waitForSession(sessionID, state: .downloading)
        s.equal(downloading.buildId, id, "Mac 활동의 빌드")
        s.equal(downloading.nodeName, World.nodeA, "Mac 활동의 노드")

        let tail = try await phoneA.installer.fetch(manifest.ipaURL, range: half...(size - 1))
        s.equal(tail.status, 206, "뒤 절반 상태")
        let ipa = head.body + tail.body
        do {
            try InstallerPlayer.verify(ipa: ipa, against: build)
            s.check(true, "받은 IPA의 크기·SHA-256이 빌드 설명과 같다")
        } catch {
            s.fail("받은 IPA 검증 실패: \(error)")
        }
        // 음성 대조: 바이트 하나가 다르면 검증이 실패해야 한다.
        var tampered = ipa
        tampered[tampered.startIndex] ^= 0xFF
        s.check((try? InstallerPlayer.verify(ipa: tampered, against: build)) == nil, "내용이 다른 IPA를 받지 않는다")
        s.check((try? InstallerPlayer.verify(ipa: Data(ipa.dropLast()), against: build)) == nil, "크기가 다른 IPA를 받지 않는다")

        try await until("iPhone이 완료를 보여 준다") { phoneA.model.installs[id] == .completed }
        s.equal(phoneA.model.installs[id]?.message, InstallState.completedMessage, "완료 안내")
        let completed = try await waitForSession(sessionID, state: .completed)
        s.equal(completed.bytesServed, size, "Mac 활동의 보낸 바이트")
        s.equal(completed.userAgent, InstallerPlayer.userAgent, "Mac 활동의 User-Agent(protocol §4.4)")
        let statusRaw = world.transportA.exchanges("GET") { $0 == "/v1/sessions/\(sessionID)" }.last
        s.response(statusRaw, status: 200, "GET /v1/sessions/{id}")
        s.keys(statusRaw?.json, ["sessionId", "buildId", "state", "bytesServed", "size", "expiresAt"], "세션 상태 응답")
        s.equal(statusRaw?.json?["buildId"] as? String, id, "세션 buildId")
        s.equal(statusRaw?.json?["size"] as? Int, Int(size), "세션 size")

        // 완료된 토큰은 바로 무효다.
        let afterDone = try await phoneA.installer.fetch(manifestURL)
        s.equal(afterDone.status, 410, "완료 뒤 매니페스트 상태")
        s.response(world.transportA.exchanges("GET") { $0 == "/i/\(token)/manifest.plist" }.last, status: 410, code: "session_expired", "완료 뒤 매니페스트")

        // 5-2. 설치 창을 닫는다: 매니페스트만 받고 멈춘다.
        phoneA.model.clearInstall(id)
        s.check(phoneA.model.installs[id] == nil, "끝난 설치 행을 지운다")
        phoneA.model.install(build)
        try await self.opener(phoneA, reaches: 2)
        try await until("다시 설치기를 기다린다") { phoneA.model.installs[id] == .waitingForInstaller }
        let dismissedRaw = world.transportA.exchanges("POST") { $0 == "/v1/builds/\(id)/sessions" }.last
        let dismissedID = try #require(dismissedRaw?.json?["sessionId"] as? String)
        let dismissedURL = opener.opened[1]
        s.check(dismissedURL != installURL, "새 세션은 새 설치 주소를 쓴다")
        let dismissedManifest = try InstallerPlayer.manifestURL(fromInstallURL: dismissedURL)
        let dismissedReply = try await phoneA.installer.fetch(dismissedManifest)
        s.equal(dismissedReply.status, 200, "닫기 전 매니페스트 상태")
        try await waitForPolls(phoneA, session: dismissedID, state: "manifest_served", count: 2)
        s.equal(phoneA.model.installs[id], .waitingForInstaller, "창을 닫은 뒤의 상태")

        await phoneA.model.reopenInstaller(id)
        s.equal(opener.opened.count, 3, "다시 열기 횟수")
        s.equal(opener.opened.last, dismissedURL, "다시 열 때 같은 주소를 쓴다")
        phoneA.model.cancelInstall(id)
        s.check(phoneA.model.installs[id] == nil, "취소하면 행을 지운다")

        // Mac의 세션은 그대로이고 매니페스트는 5번까지 받을 수 있다(protocol §4.4).
        for attempt in 2...5 {
            let again = try await phoneA.installer.fetch(dismissedManifest)
            s.equal(again.status, 200, "매니페스트 \(attempt)번째 상태")
        }
        let sixth = try await phoneA.installer.fetch(dismissedManifest)
        s.equal(sixth.status, 410, "매니페스트 6번째 상태")
    }

    private func tokenOf(_ manifest: URL) throws -> String {
        let parts = manifest.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "i", parts[2] == "manifest.plist" else { throw E2EError("매니페스트 경로 꼴이 다르다") }
        return String(parts[1])
    }

    // MARK: 6

    private func tokenTheft(_ s: Scenario) async throws {
        let build = try descriptor()
        let id = build.id
        let opened = phoneA.opener.opened.count
        phoneA.model.install(build)
        try await opener(phoneA, reaches: opened + 1)
        try await until("설치기를 기다린다") { phoneA.model.installs[id] == .waitingForInstaller }
        let created = world.transportA.exchanges("POST") { $0 == "/v1/builds/\(id)/sessions" }.last
        theftSessionID = try #require(created?.json?["sessionId"] as? String)
        let manifestURL = try InstallerPlayer.manifestURL(fromInstallURL: try #require(phoneA.opener.opened.last))
        theftManifest = manifestURL
        let token = try tokenOf(manifestURL)
        let ipaURL = manifestURL.deletingLastPathComponent().appendingPathComponent("app.ipa")

        // 허용 목록 밖의 노드.
        let outsider = try await phoneB.installer.fetch(manifestURL)
        s.equal(outsider.status, 403, "허용 목록 밖 노드의 상태")
        s.response(world.transportB.exchanges("GET") { $0 == "/i/\(token)/manifest.plist" }.last, status: 403, code: "not_paired", "허용 목록 밖 노드의 매니페스트")
        try await waitForDenied(path: "/i/…/manifest.plist", reason: "not_paired", node: World.nodeB)
        s.check(!mac.activity.contains { $0.text.contains(token) }, "Mac 활동 문장에 토큰이 없다")

        // 허용 목록에 있어도 다른 노드의 토큰은 쓸 수 없다(세션은 만든 노드에 묶인다).
        phoneB.model.clearError()
        await mac.beginPairing()
        // 화면의 표시 형식(`K7M2-9QXD`)을 사람이 소문자로 입력해도 호스트가 같은 코드로 받는다(protocol §2).
        let shown = try #require(mac.pairingCode).displayCode
        s.check(shown.contains("-"), "Mac이 코드를 하이픈으로 표시한다")
        phoneB.model.pair(code: shown.lowercased(), host: fqdn)
        let request = try await waitForPairRequest(node: World.nodeB)
        await mac.approve(request.requestId)
        try await until("두 번째 iPhone이 페어링된다") { phoneB.model.phase == .paired }
        s.equal(Set(mac.devices.map(\.nodeName)), [World.nodeA, World.nodeB], "허용 목록")

        let stolenManifest = try await phoneB.installer.fetch(manifestURL)
        s.equal(stolenManifest.status, 403, "도용 매니페스트 상태")
        s.response(world.transportB.exchanges("GET") { $0 == "/i/\(token)/manifest.plist" }.last, status: 403, code: "token_invalid", "도용 매니페스트")
        let stolenIPA = try await phoneB.installer.fetch(ipaURL)
        s.equal(stolenIPA.status, 403, "도용 IPA 상태")
        s.response(world.transportB.exchanges("GET") { $0 == "/i/\(token)/app.ipa" }.last, status: 403, code: "token_invalid", "도용 IPA")
        do {
            _ = try await phoneB.api().sessionStatus(sessionID: theftSessionID)
            s.fail("다른 노드의 세션 상태를 읽었다")
        } catch let error as HostAPIError {
            s.equal(error.status, 403, "다른 노드의 세션 조회 상태")
            s.equal(error.code, "token_invalid", "다른 노드의 세션 조회 코드")
        }
        try await waitForDenied(path: "/i/…/app.ipa", reason: "token_invalid", node: World.nodeB)
        s.check(!mac.activity.contains { $0.text.contains(token) }, "거부 뒤에도 Mac 활동 문장에 토큰이 없다")

        // 도용 시도가 원래 노드의 세션을 망가뜨리지 않는다.
        let owner = try await phoneA.installer.fetch(manifestURL)
        s.equal(owner.status, 200, "원래 노드의 매니페스트 상태")

        // 두 번째 기기를 빼서 다음 시나리오를 한 기기로 시작한다.
        let second = try #require(mac.devices.first { $0.nodeName == World.nodeB })
        await mac.removeDevice(second.id)
        s.equal(mac.lastError, nil, "두 번째 기기 제거 오류")
        s.equal(mac.devices.map(\.nodeName), [World.nodeA], "제거 뒤 허용 목록")
    }

    // MARK: 7

    private func deviceRemoval(_ s: Scenario) async throws {
        let build = try descriptor()
        let id = build.id
        let device = try #require(mac.devices.first { $0.nodeName == World.nodeA })
        let manifestURL = try #require(theftManifest)
        let token = try tokenOf(manifestURL)

        await mac.removeDevice(device.id)
        s.equal(mac.lastError, nil, "기기 제거 오류")
        s.check(mac.devices.isEmpty, "허용 목록이 비었다")
        _ = try await waitForSession(theftSessionID, state: .failed)
        s.check(true, "Mac 활동에서 열린 세션이 실패로 바뀐다(addenda C.3)")

        // 진행 확인 중이던 설치: 호스트는 세션 인증 전에 허용 목록을 본다.
        let expectedFailure = InstallState.failed(message: ProductText.notPaired)
        try await until("진행 확인이 not_paired로 끝난다") { phoneA.model.installs[id] == expectedFailure }
        s.response(world.transportA.exchanges("GET") { $0 == "/v1/sessions/\(theftSessionID)" }.last, status: 403, code: "not_paired", "제거 뒤 세션 조회")

        await phoneA.model.refresh()
        s.equal(phoneA.model.refreshError, ProductText.notPaired, "제거 뒤 새로고침 안내")
        s.equal(phoneA.model.lastError, ProductText.notPaired, "제거 뒤 마지막 오류")
        s.response(world.transportA.exchanges("GET") { $0 == "/v1/info" }.last, status: 403, code: "not_paired", "제거 뒤 GET /v1/info")
        // 제품은 저장한 Mac을 지우지 않고 다시 페어링하라고 안내한다.
        s.equal(phoneA.model.phase, .paired, "제거 뒤 iPhone 단계")
        s.equal(phoneA.store.host?.fqdn, fqdn, "제거 뒤 저장한 호스트")

        // 이미 발급한 토큰도 거부한다(addenda B.2: /i/*는 허용 목록 인증을 거친다).
        let refused = try await phoneA.installer.fetch(manifestURL)
        s.equal(refused.status, 403, "제거 뒤 토큰 상태")
        s.response(world.transportA.exchanges("GET") { $0 == "/i/\(token)/manifest.plist" }.last, status: 403, code: "not_paired", "제거 뒤 매니페스트")

        // 안내대로 다시 페어링하면 동작한다. 실패한 세션은 살아나지 않는다(addenda C.3).
        phoneA.model.clearInstall(id)
        await mac.beginPairing()
        phoneA.model.pair(link: try PairingLink.parse(url: try world.link(), policy: .tailnetOnly))
        let request = try await waitForPairRequest(node: World.nodeA)
        await mac.approve(request.requestId)
        try await until("다시 페어링 뒤 새로고침 안내가 사라진다") { phoneA.model.phase == .paired && phoneA.model.refreshError == nil }
        s.equal(phoneA.model.builds.map(\.id), [id], "다시 페어링 뒤 목록")
        s.equal(mac.devices.map(\.nodeName), [World.nodeA], "다시 페어링 뒤 허용 목록")
        let revived = try await phoneA.installer.fetch(manifestURL)
        s.equal(revived.status, 410, "다시 페어링 뒤 옛 토큰 상태")
        s.response(world.transportA.exchanges("GET") { $0 == "/i/\(token)/manifest.plist" }.last, status: 410, code: "session_expired", "다시 페어링 뒤 옛 토큰")
    }

    // MARK: 8

    private func nonDebugBuilds(_ s: Scenario) async throws {
        let build = try descriptor()
        await phoneA.model.refresh()
        s.equal(phoneA.model.builds.map(\.id), [build.id], "목록에는 수락된 빌드뿐이다")
        s.check(!rejectedApps.isEmpty, "거부한 빌드가 있다")

        for app in rejectedApps {
            // 거부된 빌드가 받았을 id를 protocol §4.1 규칙으로 만든다.
            let rejected = try #require(mac.rejected.first { $0.sourcePath == app.path }, "거부 기록: \(app.lastPathComponent)")
            let bundleID = try #require(rejected.bundleId)
            let ipa = world.tmp.appendingPathComponent("rejected-\(app.deletingPathExtension().lastPathComponent).ipa")
            let digest = try await IPABuilder.package(appAt: app, to: ipa)
            let refusedID = BuildDescriptor.makeID(bundleId: bundleID, ipaSHA256: digest.sha256)
            s.check(refusedID != build.id, "\(app.lastPathComponent)의 id는 수락된 빌드와 다르다")
            s.check(!FileManager.default.fileExists(atPath: world.paths.ipaURL(forBuildID: refusedID).path), "\(app.lastPathComponent)의 IPA가 게시 폴더에 없다")

            var fake = build
            fake.id = refusedID
            phoneA.model.install(fake)
            let expected = InstallState.failed(message: ProductText.buildNotFound)
            try await until("\(app.lastPathComponent) 설치가 build_not_found로 끝난다") { phoneA.model.installs[refusedID] == expected }
            s.response(world.transportA.exchanges("POST") { $0 == "/v1/builds/\(refusedID)/sessions" }.last, status: 404, code: "build_not_found", "\(app.lastPathComponent)의 세션 생성")
            phoneA.model.clearInstall(refusedID)
        }
    }

    // MARK: 9

    private func shutdown(_ s: Scenario) async throws {
        // 종료 전에 같은 경로가 살아 있음을 먼저 증명한다.
        await phoneA.model.refresh()
        s.equal(phoneA.model.refreshError, nil, "종료 전 새로고침 오류")
        s.response(world.transportA.exchanges("GET") { $0 == "/v1/builds" }.last, status: 200, "종료 전 GET /v1/builds")
        try await World.proveRoute(world.forwarderA)
        let before = world.transportA.exchanges.count

        await mac.shutdown()
        s.check(!mac.isRunning, "공유가 멈췄다")
        s.check(mac.status == nil, "상태가 비었다")

        // 리스너가 닫혔는지는 TCP 단계에서 본다. forward는 tailnet 연결을 끝내 못 맺으면 "forward: dial"을 남기고 닫는다(약 210초).
        let port = world.forwarderA.port
        let closed = Task.detached { await rawHTTPProbe(port: port, timeout: .seconds(300)) }

        await phoneA.model.refresh()
        s.equal(phoneA.model.refreshError, ProductText.cannotReachMac, "종료 뒤 새로고침 안내")
        s.equal(phoneA.model.lastError, ProductText.cannotReachMac, "종료 뒤 마지막 오류")
        let attempts = Array(world.transportA.exchanges.dropFirst(before))
        s.check(!attempts.isEmpty, "종료 뒤 iPhone이 요청을 보냈다")
        s.check(attempts.allSatisfy { $0.failure != nil && $0.status == nil }, "종료 뒤 요청은 HTTP 응답 없이 끝난다: \(attempts.map(\.summary))")

        do {
            _ = try await phoneA.api().builds()
            s.fail("종료 뒤 요청이 성공했다")
        } catch let error as HostAPIError {
            s.check(error.isConnectionFailure, "종료 뒤 HostAPI 오류는 연결 실패다: \(error.code)")
            s.equal(error.status, 0, "연결 실패에는 HTTP 상태가 없다")
        }

        let probe = await closed.value
        s.equal(probe, .closed, "종료 뒤 forward 연결이 닫힌다")
        s.check(world.forwarderA.child.isRunning, "forward는 살아 있다(하네스가 죽어서 닫힌 것이 아니다)")
        let forwardLog = world.forwarderA.child.err.string
        s.check(forwardLog.contains("forward: dial"), "tailnet 연결이 실패했다: \(forwardLog.suffix(800))")
        // `context canceled`는 forward가 신호로 끝날 때만 나온다. 그때의 닫힘은 Mac이 멈췄다는 증거가 아니다.
        s.check(!forwardLog.contains("context canceled"), "forward가 도중에 끝나지 않았다: \(forwardLog.suffix(800))")

        s.equal(world.transportA.offRouteRequests, [], "노드 A의 요청은 페어링한 Mac으로만 갔다")
        s.equal(world.transportB.offRouteRequests, [], "노드 B의 요청은 페어링한 Mac으로만 갔다")
    }
}
