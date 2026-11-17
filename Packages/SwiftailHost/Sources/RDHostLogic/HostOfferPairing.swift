import Foundation
import RDModels

// QR·링크 페어링(protocol-addenda B.5)의 로직 쪽 접점. 짝 맺기 절차는 Mac 코어의 `PairingHost`(SwiftailPairing)가 하고,
// 로직은 그 결과를 코드 페어링과 같은 허용 목록·사건으로 옮긴다. 허용 목록이 권한 판정의 유일한 기준이다.
extension HostLogic {
    /// 제안으로 들어온 승인 요청을 알린다(`pair-request`). 코드 페어링과 같은 사건이고 확인 숫자만 더 실린다.
    /// 열린 코드는 닫는다: 페어링은 한 번에 하나다.
    public func noteOfferPairingRequest(_ event: PairRequestEvent) {
        locked {
            pairCode = nil
            emit(.pairRequest(event))
        }
    }

    /// 제안으로 들어온 요청이 허용 없이 끝났다(`pair-decided`의 `denied`·`expired`).
    public func finishOfferPairingRequest(requestID: String, state: PairState) {
        locked { emit(.pairDecided(.init(requestId: requestID, state: state))) }
    }

    /// `PairingHost`가 짝으로 저장한 기기를 허용 목록에 넣는다. 코드 페어링의 허용과 같은 항목·사건(`device-added`, 그다음
    /// `pair-decided`의 `approved`)이다. 같은 노드가 이미 있으면 그 항목의 id를 이어 쓴다.
    @discardableResult
    public func admitOfferPairedDevice(requestID: String, peer: HostPeer, name: String) -> DeviceEntry {
        locked {
            let entry = DeviceEntry(id: devices[peer.stableID]?.id ?? HostIDs.newID("d_"), name: name,
                                    nodeStableId: peer.stableID, nodeName: peer.nodeName, loginName: peer.loginName,
                                    pairedAt: options.now())
            devices[entry.nodeStableId] = entry
            deviceWireDates.removeValue(forKey: entry.nodeStableId)
            emit(.deviceAdded(entry))
            emit(.pairDecided(.init(requestId: requestID, state: .approved)))
            return entry
        }
    }

    /// 열린 페어링 코드를 닫는다(제안으로 요청이 왔을 때, 또는 화면이 페어링을 그만둘 때).
    public func closePairingCode() {
        locked { pairCode = nil }
    }
}
