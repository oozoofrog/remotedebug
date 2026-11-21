import Foundation
import RDModels

// docs/protocol-addenda.md S: 같은 iPhone의 다른 tailnet 노드(다른 앱이 켠 VPN, 예: 공식 Tailscale 앱)를 기기 항목에 묶는다.
// 묶은 노드에서 온 요청은 라우터가 그 기기 항목의 신원으로 바꾼 뒤 처리한다. 그래서 세션·설치·알림 처리기는 그대로다.
extension HostLogic {
    /// 기기 하나에 묶어 두는 노드 수. 넘으면 가장 오래전에 묶은 것부터 뺀다.
    static let maxLinkedNodes = 4
    /// 한 노드가 1분 안에 토큰을 이만큼 틀리면 그 1분이 끝날 때까지 묶기 요청에 `429`로 답한다.
    static let maxLinkFailures = 10

    /// 이 노드를 묶은 기기 항목. 묶지 않았으면 `nil`.
    func linkedDevice(_ stableID: String) -> DeviceEntry? {
        nodeLinks[stableID].flatMap { devices[$0] }
    }

    /// `devices`에서 `nodeLinks`를 다시 만든다. 허용 목록에 따로 있는 노드는 넣지 않는다(그 항목이 먼저다).
    /// 저장 값에서 한 노드가 두 기기에 묶여 있으면 나중에 묶은 쪽을 쓴다.
    func rebuildNodeLinks() {
        var index: [String: (device: String, at: Date)] = [:]
        for device in devices.values.sorted(by: { $0.id < $1.id }) {
            for node in device.linkedNodes where !node.nodeStableId.isEmpty && devices[node.nodeStableId] == nil {
                if let existing = index[node.nodeStableId], existing.at >= node.linkedAt { continue }
                index[node.nodeStableId] = (device.nodeStableId, node.linkedAt)
            }
        }
        nodeLinks = index.mapValues(\.device)
    }

    /// `stableID` 노드를 `keeping`이 아닌 모든 기기 항목에서 뺀다. 바뀐 항목마다 `device-updated`를 낸다.
    func unlinkNode(_ stableID: String, keeping: String?) {
        for device in devices.values.sorted(by: { $0.id < $1.id })
        where device.nodeStableId != keeping && device.linkedNodes.contains(where: { $0.nodeStableId == stableID }) {
            var changed = device
            changed.linkedNodes.removeAll { $0.nodeStableId == stableID }
            devices[device.nodeStableId] = changed
            emit(.deviceUpdated(changed))
        }
    }

    /// `Authorization: RD-Device <deviceId>.<token>`이 가리키는 기기 항목. 머리말이 없거나 토큰이 틀리면 `nil`.
    /// 토큰은 해시끼리 시간 차 없이 비교한다(docs/protocol-addenda.md O.3).
    func deviceForToken(_ request: HostRequest) -> DeviceEntry? {
        let header = request.header("authorization") ?? ""
        guard header.hasPrefix("RD-Device ") else { return nil }
        let credentials = header.dropFirst(10).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = credentials.firstIndex(of: ".") else { return nil }
        let id = String(credentials[..<dot]), token = String(credentials[credentials.index(after: dot)...])
        let hash = HostIDs.directTokenHash(token)
        guard !id.isEmpty, !hash.isEmpty,
              let device = devices.values.first(where: { $0.id == id }),
              let expected = device.directTokenHash, !expected.isEmpty, HostIDs.constantEqual(hash, expected) else { return nil }
        return device
    }

    /// `POST /v1/devices/self/nodes`: 요청을 보낸 tailnet 노드를 기기 토큰의 기기 항목에 묶는다.
    /// 라우터는 이 경로에서 노드를 허용 목록과 대조하지 않는다. 대신 여기서 토큰과 로그인 계정을 본다.
    func linkNode(_ request: HostRequest, peer: HostPeer, path: String) throws -> HostResponse {
        let now = options.now()
        let key = peer.stableID
        if let failure = linkFailures[key], now.timeIntervalSince(failure.first) >= 60 { linkFailures.removeValue(forKey: key) }
        if let failure = linkFailures[key], failure.count >= Self.maxLinkFailures { throw HostErrors.make("too_many_attempts") }
        guard let device = deviceForToken(request) else {
            if var failure = linkFailures[key] { failure.count += 1; linkFailures[key] = failure }
            else { linkFailures[key] = DirectFailure(first: now, count: 1) }
            return deny("not_paired", peer: peer, path: path)
        }
        linkFailures.removeValue(forKey: key)
        // 이 노드가 이미 허용 목록에 있다(그 기기 자신이거나 따로 페어링한 기기). 묶을 것이 없다.
        if let allowed = devices[peer.stableID] {
            return linkResponse(NodeLinkResponse(deviceId: allowed.id, nodeName: peer.nodeName))
        }
        // 같은 Tailscale 계정의 노드만 묶는다. 토큰이 새어도 다른 계정의 노드는 이 기기가 될 수 없다.
        guard !peer.loginName.isEmpty, peer.loginName == device.loginName else {
            return deny("node_login_mismatch", peer: peer, path: path)
        }
        let known = device.linkedNodes.first { $0.nodeStableId == peer.stableID }
        if let known, known.nodeName == peer.nodeName, known.loginName == peer.loginName, nodeLinks[peer.stableID] == device.nodeStableId {
            return linkResponse(NodeLinkResponse(deviceId: device.id, nodeName: peer.nodeName))
        }
        unlinkNode(peer.stableID, keeping: device.nodeStableId)
        var updated = devices[device.nodeStableId] ?? device
        updated.linkedNodes.removeAll { $0.nodeStableId == peer.stableID }
        updated.linkedNodes.append(LinkedNode(nodeStableId: peer.stableID, nodeName: peer.nodeName, loginName: peer.loginName, linkedAt: now))
        if updated.linkedNodes.count > Self.maxLinkedNodes {
            updated.linkedNodes.sort { $0.linkedAt < $1.linkedAt }
            updated.linkedNodes.removeFirst(updated.linkedNodes.count - Self.maxLinkedNodes)
        }
        devices[updated.nodeStableId] = updated
        rebuildNodeLinks()
        emit(.deviceUpdated(updated))
        return linkResponse(NodeLinkResponse(deviceId: updated.id, nodeName: peer.nodeName))
    }

    private func linkResponse(_ value: NodeLinkResponse) -> HostResponse {
        var response = json(value)
        response.headers.append(("Cache-Control", "no-store"))
        return response
    }
}

extension DeviceEntry {
    /// 이 기기 항목의 tailnet 신원. 직접 연결과 묶인 노드의 요청을 이 신원으로 처리한다.
    var hostPeer: HostPeer { HostPeer(stableID: nodeStableId, nodeName: nodeName, loginName: loginName) }
}
