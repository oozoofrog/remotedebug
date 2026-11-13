import Foundation

/// 같은 네트워크 직접 연결 리스너를 Bonjour로 알린다(docs/protocol-addenda.md O).
///
/// 광고에는 무작위 식별자(인스턴스 이름)와 포트, TXT `v=1`만 싣는다.
/// Mac 이름, tailnet 주소, 호스트 id는 싣지 않는다.
@MainActor
public protocol DirectAdvertising: AnyObject {
    /// 이 식별자와 포트로 광고한다. 이미 같은 값으로 광고 중이면 아무것도 하지 않는다.
    func advertise(id: String, port: Int)
    func stop()
}

/// `NetService`로 `_remotedebug._tcp`를 광고한다. 포트는 코어가 열고 있고, 여기서는 이름만 알린다.
@MainActor
public final class BonjourAdvertiser: NSObject, DirectAdvertising {
    public static let serviceType = "_remotedebug._tcp."
    public static let txtRecord: [String: Data] = ["v": Data("1".utf8)]

    private var service: NetService?
    private var current: (id: String, port: Int)?

    public override init() {}

    public func advertise(id: String, port: Int) {
        guard !id.isEmpty, (1...65535).contains(port) else { return stop() }
        if let current, current.id == id, current.port == port { return }
        stop()
        let made = NetService(domain: "", type: Self.serviceType, name: id, port: Int32(port))
        made.setTXTRecord(NetService.data(fromTXTRecord: Self.txtRecord))
        // 포트는 코어가 이미 열었다. 이름이 겹쳐도 바꾸지 않는다(iPhone은 저장한 식별자만 찾는다).
        made.publish(options: [.noAutoRename])
        service = made
        current = (id, port)
    }

    public func stop() {
        service?.stop()
        service = nil
        current = nil
    }
}
