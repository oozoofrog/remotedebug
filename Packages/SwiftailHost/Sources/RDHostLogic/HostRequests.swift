import Foundation
import RDModels

extension HostLogic {
    func dispatch(_ route: Route, request: HostRequest, peer: HostPeer, body: HostJSON?, agentDevice: DeviceEntry?, path: String) throws -> HostResponse {
        let input = try body ?? HostJSON(value: NSNull())
        switch route.name {
        case "info":
            let info = options.info()
            let update = options.updatePageURL()
            return json(InfoResponse(hostId: info.hostID, hostName: info.hostName, fqdn: info.fqDN, protocolVersion: 1,
                                     appVersion: info.appVersion, buildCount: builds.count, updatePage: update.isEmpty ? nil : update))
        case "builds":
            let sorted = builds.values.sorted {
                let a = $0.sortTimestamp ?? hostTimestamp($0.descriptor.publishedAt), b = $1.sortTimestamp ?? hostTimestamp($1.descriptor.publishedAt)
                return a == b ? $0.descriptor.id < $1.descriptor.id : a > b
            }
            return object(["builds": try sorted.map { try wireObject($0.wire, fallback: $0.descriptor) }])
        case "updates":
            // 한 앱(번들 ID)의 가장 최근 게시 빌드 메타데이터만 돌려준다(아이콘 제외). 다른 `/v1/*`처럼 페어링한 기기만 받는다.
            guard FeedbackChecklist.isValidBundleID(route.parameter) else { throw HostErrors.make("bad_request", "bundleId가 올바르지 않습니다.") }
            let matching = builds.values.filter { $0.descriptor.bundleId == route.parameter }.sorted {
                let a = $0.sortTimestamp ?? hostTimestamp($0.descriptor.publishedAt), b = $1.sortTimestamp ?? hostTimestamp($1.descriptor.publishedAt)
                return a == b ? $0.descriptor.id < $1.descriptor.id : a > b
            }
            guard let latest = matching.first else {
                return object(["bundleId": route.parameter, "latest": NSNull()])
            }
            let d = latest.descriptor
            var summary: [String: Any] = [
                "id": d.id,
                "bundleId": d.bundleId,
                "displayName": d.displayName,
                "version": d.version,
                "buildNumber": d.buildNumber,
                "minOS": d.minOS,
                "publishedAt": latest.sortTimestamp ?? hostTimestamp(d.publishedAt),
                "ipaSize": d.ipa.size,
            ]
            if let notes = d.releaseNotes { summary["releaseNotes"] = notes }
            return object(["bundleId": route.parameter, "latest": summary])
        case "resources":
            let sorted = resources.values.sorted {
                let a = $0.sortTimestamp ?? hostTimestamp($0.descriptor.publishedAt), b = $1.sortTimestamp ?? hostTimestamp($1.descriptor.publishedAt)
                return a == b ? $0.descriptor.id < $1.descriptor.id : a > b
            }
            return object(["resources": try sorted.map { try wireObject($0.wire, fallback: $0.descriptor) }])
        case "resource":
            guard let resource = resources[route.parameter], let file = resource.file, file.unchanged(checkTime: false) else {
                throw HostErrors.make("resource_not_found")
            }
            return serveFile(file, request: request, headers: [
                ("Content-Disposition", Self.contentDisposition(resource.descriptor.name)),
                ("X-Content-Type-Options", "nosniff"), ("Cache-Control", "no-store"), ("ETag", "\"" + resource.descriptor.sha256 + "\"")
            ])
        case "agent":
            return HostResponse(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store")], body: .bytes(Array(agentBoard)))
        case "agentRequest": return try submitAgent(input, peer: peer, device: agentDevice, path: path)
        case "agentCancel":
            guard let device = agentDevice else { return deny("not_paired", peer: peer, path: path) }
            emit(.agentCancel(.init(requestId: route.parameter, deviceName: device.name)), deviceID: device.id)
            return object(["ok": true], status: 202)
        case "checklist":
            // 앱(번들 ID)의 확인 목록. 없으면 빈 목록을 준다. 다른 `/v1/*`처럼 페어링한 기기만 받는다.
            guard FeedbackChecklist.isValidBundleID(route.parameter) else { throw HostErrors.make("bad_request", "bundleId가 올바르지 않습니다.") }
            let stored = options.feedbackChecklist(route.parameter).flatMap { data in
                // Mac 앱이 저장할 때 지키는 한도(`FeedbackChecklist.maxEncodedBytes`)까지 준다. 더 큰 파일은 손댄 것이므로 없는 것으로 본다.
                data.count <= FeedbackChecklist.maxEncodedBytes && (try? JSONSerialization.jsonObject(with: data)) is [String: Any] ? data : nil
            }
            return HostResponse(status: 200, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store")],
                                body: .bytes(stored.map(Array.init) ?? Array(("{\"bundleId\":\"" + route.parameter + "\",\"items\":[]}").utf8)))
        case "logs": return try receiveLogs(input, peer: peer, path: path)
        case "crashes": return try receiveCrash(input, peer: peer, path: path)
        case "push": return try registerPush(input, deleting: request.method == "DELETE", peer: peer, path: path)
        case "enroll":
            guard let info = options.direct() else { throw HostErrors.make("direct_off") }
            guard var device = devices[peer.stableID] else { return deny("not_paired", peer: peer, path: path) }
            let token = HostIDs.newToken()
            device.directTokenHash = HostIDs.directTokenHash(token)
            devices[peer.stableID] = device
            emit(.deviceUpdated(device))
            var response = json(DirectEnrollment(directId: info.id, port: info.port, tlsSPKI: info.spki, deviceId: device.id, token: token))
            response.headers.append(("Cache-Control", "no-store"))
            return response
        case "linkNode": return try linkNode(request, peer: peer, path: path)
        case "pair": return try requestPair(input, peer: peer, path: path)
        case "pairStatus":
            guard let pairing = pairRequests[route.parameter], pairing.peer.stableID == peer.stableID else {
                return deny("not_paired", peer: peer, path: path)
            }
            expirePair(pairing, now: options.now())
            var summary: HostSummary?
            if pairing.state == .approved {
                let info = options.info()
                summary = HostSummary(hostId: info.hostID, hostName: info.hostName, fqdn: info.fqDN)
            }
            return json(PairRequestState(requestId: pairing.id, state: pairing.state, host: summary))
        case "createSession": return try createSession(buildID: route.parameter, peer: peer, request: request)
        case "cableInstall": return try startCableInstall(buildID: route.parameter, peer: peer, request: request)
        case "sessionStatus":
            guard let session = sessions[route.parameter], session.peer.stableID == peer.stableID else {
                return deny("token_invalid", peer: peer, path: path)
            }
            expireSession(session, now: options.now())
            return json(SessionStatus(sessionId: session.id, buildId: session.buildID, state: session.state,
                                      bytesServed: Int64(session.bytesServed), size: Int64(session.size), expiresAt: session.expires,
                                      message: session.message))
        case "manifest", "ipa":
            guard let session = tokens[route.parameter], session.peer.stableID == peer.stableID else {
                return deny("token_invalid", peer: peer, path: path)
            }
            expireSession(session, now: options.now())
            guard !session.terminal else { throw HostErrors.make("session_expired") }
            guard let build = builds[session.buildID] else { failSession(session); throw HostErrors.make("build_not_found") }
            if route.name == "manifest" { return try serveManifest(session, build: build, request: request) }
            return try serveIPA(session, build: build, request: request)
        default: throw HostErrors.make("not_found")
        }
    }

    func requestPair(_ input: HostJSON, peer: HostPeer, path: String) throws -> HostResponse {
        let code = try input.string("code"), name = try input.string("deviceName")
        let platform = try input.string("platform"), version = try input.string("clientVersion")
        guard name.utf8.count <= 200 && platform.utf8.count <= 200 && version.utf8.count <= 100 else {
            throw HostErrors.make("bad_request", "필드가 너무 깁니다.")
        }
        let now = options.now()
        guard let pairing = pairCode else { return deny("pair_code_invalid", peer: peer, path: path) }
        if now >= pairing.value.expiresAt { pairCode = nil; return deny("pair_code_invalid", peer: peer, path: path) }
        if pairing.burned { return deny("too_many_attempts", peer: peer, path: path) }
        if !HostIDs.pairCodeEqual(pairing.value.code, code) {
            pairing.failures += 1
            if pairing.failures >= options.limits.pairMaxFailures { pairing.burned = true }
            return deny("pair_code_invalid", peer: peer, path: path)
        }
        pairCode = nil
        let pairingRequest = PairRequest(id: HostIDs.newID("pr_"), peer: peer, name: name, expires: now.addingTimeInterval(options.limits.pairRequestTTL))
        pairRequests[pairingRequest.id] = pairingRequest
        emit(.pairRequest(.init(requestId: pairingRequest.id, deviceName: name, nodeName: peer.nodeName,
                                loginName: peer.loginName, expiresAt: pairingRequest.expires)))
        return json(PairRequestState(requestId: pairingRequest.id, state: .pending, expiresAt: pairingRequest.expires), status: 202)
    }

    func submitAgent(_ input: HostJSON, peer: HostPeer, device: DeviceEntry?, path: String) throws -> HostResponse {
        guard let device else { return deny("not_paired", peer: peer, path: path) }
        let text = try input.string("text").trimmingCharacters(in: .whitespacesAndNewlines)
        let project = try input.string("project"), agent = try input.string("agent"), continues = try input.string("continues")
        guard !text.isEmpty && text.utf8.count <= 16 << 10 else { throw HostErrors.make("bad_request", "text는 1바이트 이상 16KiB 이하의 UTF-8이어야 합니다.") }
        guard [project, agent, continues].allSatisfy({ $0.utf8.count <= 128 }) else {
            throw HostErrors.make("bad_request", "project, agent, continues는 128바이트 이하여야 합니다.")
        }
        let id = HostIDs.newID("a_")
        emit(.agentRequest(.init(requestId: id, deviceId: device.id, deviceName: device.name, text: text,
                                 project: project, agent: agent, continues: continues)), nodeName: device.nodeName)
        return object(["id": id], status: 202)
    }

    func receiveLogs(_ input: HostJSON, peer: HostPeer, path: String) throws -> HostResponse {
        let raw = try input.array("entries")
        guard !raw.isEmpty && raw.count <= 200 else { throw HostErrors.make("bad_request", "entries는 1~200개여야 합니다.") }
        let entries = try raw.map { value -> DeviceLogEntry in
            let entry = try HostJSON(value: value)
            return try DeviceLogEntry(at: RDTimestamp.parse(entry.string("at")) ?? options.now(),
                                      level: DeviceLogEntry.Level(rawValue: entry.string("level")) ?? .info,
                                      source: hostTruncate(entry.string("source"), bytes: 40),
                                      message: hostTruncate(entry.string("message"), bytes: 4096))
        }
        guard let device = devices[peer.stableID] else { return deny("not_paired", peer: peer, path: path) }
        emit(.deviceLog(.init(deviceId: device.id, deviceName: device.name, nodeName: device.nodeName, entries: entries)))
        return object(["accepted": entries.count], status: 202)
    }

    func receiveCrash(_ input: HostJSON, peer: HostPeer, path: String) throws -> HostResponse {
        let receivedAt = options.now()
        guard let kind = try CrashReport.Kind(rawValue: input.string("kind")) else {
            throw HostErrors.make("bad_request", "kind는 ips, metrickit, feedback 가운데 하나여야 합니다.")
        }
        let text = try input.string("text")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 1536 << 10 else {
            throw HostErrors.make("bad_request", "text는 비어 있지 않고 1536KB 이하여야 합니다.")
        }
        let encodedImage = try input.string("image")
        var image: Data?
        if !encodedImage.isEmpty {
            image = Data(base64Encoded: encodedImage.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))
            guard let image, !image.isEmpty, image.count <= 1 << 20, kind == .feedback else {
                throw HostErrors.make("bad_request", "image는 feedback에만 붙일 수 있고 base64로 1MB 이하여야 합니다.")
            }
        }
        // 사용자가 붙인 사진과 파일. 옛 클라이언트는 `image`만 보낸다.
        let rawAttachments = try input.array("attachments")
        guard rawAttachments.isEmpty || (kind == .feedback && rawAttachments.count <= CrashReport.maxAttachments) else {
            throw HostErrors.make("bad_request", "attachments는 feedback에만 붙일 수 있고 \(CrashReport.maxAttachments)개 이하여야 합니다.")
        }
        var attachments: [CrashReport.Attachment] = []
        for value in rawAttachments {
            let entry = try HostJSON(value: value)
            let encoded = try entry.string("base64").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            guard let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= CrashReport.maxAttachmentBytes else {
                throw HostErrors.make("bad_request", "첨부는 base64로 1MB 이하여야 합니다.")
            }
            let type = try hostTruncate(entry.string("type"), bytes: 100)
            attachments.append(.init(name: CrashReport.Attachment.safeName(try entry.string("name")),
                                     type: type.isEmpty ? "application/octet-stream" : type, data: data))
        }
        guard attachments.reduce(0, { $0 + $1.data.count }) <= CrashReport.maxAttachmentTotalBytes else {
            throw HostErrors.make("bad_request", "첨부는 모두 합쳐 1536KB 이하여야 합니다.")
        }
        // 확인 목록의 답. 개발 빌드의 피드백에만 온다.
        let rawChecks = try input.array("checks")
        guard rawChecks.isEmpty || (kind == .feedback && rawChecks.count <= FeedbackChecklist.maxItems) else {
            throw HostErrors.make("bad_request", "checks는 feedback에만 붙일 수 있고 \(FeedbackChecklist.maxItems)개 이하여야 합니다.")
        }
        let checks = try rawChecks.map { value -> CrashReport.Check in
            let entry = try HostJSON(value: value)
            let id = try hostTruncate(entry.string("id"), bytes: 64)
            guard !id.isEmpty else { throw HostErrors.make("bad_request", "checks의 id가 비어 있습니다.") }
            return try CrashReport.Check(id: id, title: hostTruncate(entry.string("title"), bytes: 600),
                                         answer: hostTruncate(entry.string("answer"), bytes: 120),
                                         note: hostTruncate(entry.string("note"), bytes: 800),
                                         build: hostTruncate(entry.string("build"), bytes: 40),
                                         answeredAt: hostTruncate(entry.string("answeredAt"), bytes: 40))
        }
        var report = try CrashReport(kind: kind, name: hostTruncate(input.string("name"), bytes: 200),
                                     bundleId: hostTruncate(input.string("bundleId"), bytes: 200),
                                     appVersion: hostTruncate(input.string("appVersion"), bytes: 200),
                                     crashedAt: min(RDTimestamp.parse(input.string("crashedAt")) ?? receivedAt, receivedAt), text: text, image: image, attachments: attachments)
        report.checks = checks
        // 사용자가 쓴 글만 따로 적은 값. 새 클라이언트가 피드백에 붙인다(빈 글자도 값이다). 받는 Mac이 글과 로그를 가르는 데 쓴다.
        if kind == .feedback, input.value("message") is String {
            report.message = try hostTruncate(input.string("message"), bytes: CrashReport.maxMessageBytes)
        }
        guard let device = devices[peer.stableID] else { return deny("not_paired", peer: peer, path: path) }
        emit(.deviceCrash(.init(deviceId: device.id, deviceName: device.name, nodeName: device.nodeName, report: report)), receivedAt: receivedAt)
        return object(["accepted": 1], status: 202)
    }

    func registerPush(_ input: HostJSON, deleting: Bool, peer: HostPeer, path: String) throws -> HostResponse {
        var registration: PushRegistration?
        if !deleting {
            let token = try input.string("token"), bundle = try input.string("bundleId"), environment = try input.string("environment")
            guard token.utf8.count >= 64 && token.utf8.count <= 512 && token.utf8.count % 2 == 0 && token.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { throw HostErrors.make("bad_request", "token은 64~512자의 짝수 길이 16진수여야 합니다.") }
            guard !bundle.isEmpty && bundle.utf8.count <= 255 && bundle.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45
            }) else { throw HostErrors.make("bad_request", "bundleId가 올바르지 않습니다.") }
            guard environment == "development" else { throw HostErrors.make("bad_request", "environment는 development만 받습니다.") }
            registration = PushRegistration(token: token.lowercased(), bundleId: bundle, environment: environment)
        }
        guard var device = devices[peer.stableID] else { return deny("not_paired", peer: peer, path: path) }
        if device.push != registration {
            device.push = registration
            devices[peer.stableID] = device
            emit(.deviceUpdated(device))
        }
        return object(["registered": registration != nil])
    }
}
