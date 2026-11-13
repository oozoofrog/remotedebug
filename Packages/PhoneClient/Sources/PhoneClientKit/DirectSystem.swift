import CryptoKit
import Foundation
import Network
import Security

// 같은 네트워크 직접 연결(docs/protocol-addenda.md O)이 시스템에 닿는 부분:
// Keychain 보관, Bonjour 찾기, 네트워크 경로, 공개 키를 고정한 TLS 전송.

// MARK: 공개 키 고정

/// 인증서의 SubjectPublicKeyInfo SHA-256(base64). Mac의 직접 연결 키는 P-256이다.
public enum SPKIPin {
    /// P-256 공개 키의 SubjectPublicKeyInfo 머리(뒤에 65바이트 점이 붙는다).
    private static let p256Header: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]

    /// P-256 키가 아니면 `nil`(고정 값과 맞을 수 없다).
    public static func hash(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? String == (kSecAttrKeyTypeECSECPrimeRandom as String),
              attributes[kSecAttrKeySizeInBits] as? Int == 256,
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?, point.count == 65
        else { return nil }
        return Data(SHA256.hash(data: Data(p256Header) + point)).base64EncodedString()
    }

    /// 서버가 낸 인증서(체인의 첫째)의 공개 키가 `pin`과 같은가. 이름·만료·시스템 신뢰는 보지 않는다.
    public static func matches(_ trust: SecTrust, pin: String) -> Bool {
        guard !pin.isEmpty, let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let found = hash(of: leaf) else { return false }
        // 길이가 같은 두 base64 문자열을 시간 차 없이 비교한다.
        let a = Array(found.utf8), b = Array(pin.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// 공개 키가 고정 값과 같을 때만 TLS 연결을 받아들인다. 다르면 연결 단계에서 끊으므로 요청 헤더(토큰)는 나가지 않는다.
private final class PinnedDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let pin: String
    private let lock = NSLock()
    private var progress: [Int: FileDownloader.Progress] = [:]

    init(pin: String) { self.pin = pin }

    func setProgress(_ handler: FileDownloader.Progress?, for task: URLSessionTask) {
        lock.withLock { progress[task.taskIdentifier] = handler }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, SPKIPin.matches(trust, pin: pin)
        else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.withLock { progress[downloadTask.taskIdentifier] }?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// 직접 연결용 전송. `https://<LAN IP>:<포트>`에 연결하고 공개 키 고정만으로 서버를 확인한다(TLS 1.3).
///
/// 파일은 앱이 떠 있는 동안만 받는 세션으로 받는다. 시스템 백그라운드 세션은 앱이 멈춘 사이의
/// 서버 신뢰 확인을 이 고정 값으로 처리한다고 보장할 수 없어서 쓰지 않는다. 끊긴 전송은 같은 `key`로
/// 다시 받을 때 이어 받는다(Range).
public final class PinnedURLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate: PinnedDelegate
    private let maximumTimeout: TimeInterval
    private let lock = NSLock()
    private var resumeData: [String: Data] = [:]

    public init(pin: String, maximumTimeout: TimeInterval = 120) {
        self.maximumTimeout = maximumTimeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = maximumTimeout
        config.timeoutIntervalForResource = 6 * 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        // 직접 연결은 같은 네트워크에서만 쓴다. 셀룰러로 사설 주소에 나가지 않는다.
        config.allowsCellularAccess = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        // 시스템 프록시(다른 VPN 앱의 프록시 설정 등)로 토큰이 나가지 않게 한다.
        config.connectionProxyDictionary = [:]
        delegate = PinnedDelegate(pin: pin)
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let limit = min(max(request.timeoutInterval, 0.2), maximumTimeout)
        let session = self.session
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask {
                do {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    return (data, http)
                } catch let error as URLError where error.code == .cancelled && !Task.isCancelled {
                    // 부른 쪽이 취소하지 않았는데 취소로 끝났다: 공개 키가 고정 값과 달라 연결을 끊은 것이다.
                    // 취소가 아니라 연결 실패로 알려야 VPN 경로로 넘어간다.
                    throw URLError(.serverCertificateUntrusted)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.unknown) }
            return first
        }
    }

    public func download(_ request: URLRequest, key: String, context: Data?, progress: @escaping FileDownloader.Progress) async throws -> (URL, HTTPURLResponse) {
        let resume = lock.withLock { resumeData.removeValue(forKey: key) }
        let task = resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        delegate.setProgress(progress, for: task)
        defer { delegate.setProgress(nil, for: task) }
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, HTTPURLResponse), any Error>) in
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent("rd-download-\(UUID().uuidString)")
                let box = DownloadBox(kept: kept, cancelled: cancelled, continuation: continuation) { [weak self] data in
                    guard let self, let data else { return }
                    self.lock.withLock { self.resumeData[key] = data }
                }
                task.delegate = box
                task.resume()
            }
        } onCancel: {
            cancelled.set()
            task.cancel { [weak self] data in
                guard let self, let data else { return }
                self.lock.withLock { self.resumeData[key] = data }
            }
        }
    }
}

/// 부른 쪽이 내려받기를 취소했는가. 공개 키가 달라 끊긴 것(이것도 "취소"로 온다)과 구분한다.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// 내려받기 하나의 끝을 기다린다. 파일은 완료 콜백 안에서 옮겨야 남는다.
private final class DownloadBox: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let kept: URL
    private let keepResume: @Sendable (Data?) -> Void
    private let cancelled: CancelFlag
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), any Error>?
    private var moved = false

    init(kept: URL, cancelled: CancelFlag, continuation: CheckedContinuation<(URL, HTTPURLResponse), any Error>,
         keepResume: @escaping @Sendable (Data?) -> Void) {
        self.kept = kept
        self.cancelled = cancelled
        self.continuation = continuation
        self.keepResume = keepResume
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let ok = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        lock.withLock { moved = ok }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        (session.delegate as? PinnedDelegate)?.urlSession(session, downloadTask: downloadTask, didWriteData: bytesWritten,
                                                          totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // 작업별 대리자가 있어도 고정 값 확인은 세션 대리자와 같아야 한다.
        guard let pinned = session.delegate as? PinnedDelegate else { return (.cancelAuthenticationChallenge, nil) }
        return await pinned.urlSession(session, didReceive: challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let pinned = session.delegate as? PinnedDelegate else { return (.cancelAuthenticationChallenge, nil) }
        return await pinned.urlSession(session, didReceive: challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, moved) = lock.withLock { () -> (CheckedContinuation<(URL, HTTPURLResponse), any Error>?, Bool) in
            defer { self.continuation = nil }
            return (self.continuation, self.moved)
        }
        guard let continuation else { return }
        if let error {
            if moved { try? FileManager.default.removeItem(at: kept) }
            keepResume((error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
            if (error as? URLError)?.code == .cancelled {
                // 부른 쪽의 취소가 아니면 공개 키가 달라 끊은 것이다(연결 실패로 알린다).
                continuation.resume(throwing: cancelled.isSet ? CancellationError() : URLError(.serverCertificateUntrusted))
            } else {
                continuation.resume(throwing: error)
            }
        } else if moved, let response = task.response as? HTTPURLResponse {
            continuation.resume(returning: (kept, response))
        } else {
            if moved { try? FileManager.default.removeItem(at: kept) }
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

/// 공개 키를 고정한 `URLSession` 전송을 만든다.
public struct PinnedTransportFactory: DirectTransportMaking {
    public init() {}
    public func transport(pin: String) -> any HTTPTransport { PinnedURLSessionTransport(pin: pin) }
}

// MARK: Keychain

/// 등록 값을 Keychain에 둔다(`AfterFirstUnlockThisDeviceOnly`: 백업·다른 기기로 옮겨지지 않는다).
///
/// `accessGroup`(App Group 이름)을 주면 두 iPhone 앱이 같은 항목을 쓴다. 그 그룹을 쓸 수 없는 빌드
/// (권한 없음, 시뮬레이터)에서는 이 앱만의 항목으로 저장한다.
public struct KeychainDirectCredentialStore: DirectCredentialStoring {
    public static let service = "RemoteDebug.direct"
    private static let account = "credential"
    private let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    private func query(group: String?) -> [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecUseDataProtectionKeychain: true,
        ]
        if let group { q[kSecAttrAccessGroup] = group }
        return q
    }

    /// 공용 그룹을 먼저, 없으면 이 앱만의 항목을 본다.
    private var groups: [String?] { accessGroup == nil ? [nil] : [accessGroup, nil] }

    public func load() -> DirectCredential? {
        for group in groups {
            var q = query(group: group)
            q[kSecReturnData] = true
            q[kSecMatchLimit] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
                  let value = try? JSONDecoder().decode(DirectCredential.self, from: data) else { continue }
            return value
        }
        return nil
    }

    public func save(_ credential: DirectCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        for group in groups {
            let q = query(group: group)
            let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(q.merging(attributes) { $1 } as CFDictionary, nil)
            }
            if status == errSecSuccess { return }
        }
    }

    public func clear() {
        for group in groups { SecItemDelete(query(group: group) as CFDictionary) }
    }
}

// MARK: 네트워크 경로

/// Wi-Fi(또는 유선)에 붙어 있는지 지켜본다. 경로가 바뀌면 `onChange`를 부른다.
public final class LocalNetworkMonitor: LocalNetworkChecking, @unchecked Sendable {
    private let wifi = NWPathMonitor(requiredInterfaceType: .wifi)
    private let wired = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private let lock = NSLock()
    private var wifiUp = false
    private var wiredUp = false
    private var started = false
    private var handler: (@Sendable () -> Void)?

    public init() {}

    deinit {
        wifi.cancel()
        wired.cancel()
    }

    public var isOnLocalNetwork: Bool { lock.withLock { !started || wifiUp || wiredUp } }

    /// 지켜보기 시작한다. 첫 결과가 오기 전에는 붙어 있다고 본다(찾아보고 없으면 VPN 경로로 간다).
    public func start(onChange: @escaping @Sendable () -> Void) {
        lock.withLock { handler = onChange }
        let queue = DispatchQueue(label: "RemoteDebug.direct.path")
        wifi.pathUpdateHandler = { [weak self] path in self?.update(wifi: path.status == .satisfied, wired: nil) }
        wired.pathUpdateHandler = { [weak self] path in self?.update(wifi: nil, wired: path.status == .satisfied) }
        wifi.start(queue: queue)
        wired.start(queue: queue)
    }

    private func update(wifi: Bool?, wired: Bool?) {
        // 붙어 있는지가 바뀔 때만 알린다(같은 상태의 반복 알림으로 찾은 경로를 버리지 않는다).
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            let before = started ? (wifiUp || wiredUp) : nil
            started = true
            if let wifi { wifiUp = wifi }
            if let wired { wiredUp = wired }
            return before == (wifiUp || wiredUp) ? nil : self.handler
        }
        handler?()
    }
}

// MARK: Bonjour

/// `_remotedebug._tcp`에서 저장해 둔 식별자의 광고만 찾는다. 로컬 네트워크 권한이 없으면 조용히 `nil`.
public struct BonjourDirectBrowser: DirectBrowsing {
    public static let serviceType = "_remotedebug._tcp"

    public init() {}

    public func find(directId: String, timeout: Duration) async -> DirectEndpoint? {
        let search = BonjourSearch(directId: directId)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                search.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            search.finish(nil)
        }
    }
}

private final class BonjourSearch: @unchecked Sendable {
    private let directId: String
    private let queue = DispatchQueue(label: "RemoteDebug.direct.browse")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<DirectEndpoint?, Never>?
    private var done = false

    init(directId: String) { self.directId = directId }

    func start(timeout: Duration, continuation: CheckedContinuation<DirectEndpoint?, Never>) {
        queue.async {
            if self.done { return continuation.resume(returning: nil) }
            self.continuation = continuation
            let browser = NWBrowser(for: .bonjour(type: BonjourDirectBrowser.serviceType, domain: nil), using: .tcp)
            self.browser = browser
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.complete(nil)
                // 권한이 없으면(정책 거부) 기다려도 결과가 오지 않는다.
                case .waiting: self?.complete(nil)
                default: break
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self, self.connection == nil else { return }
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint, name == self.directId {
                        self.resolve(result.endpoint)
                        return
                    }
                }
            }
            browser.start(queue: self.queue)
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            self.queue.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.complete(nil) }
        }
    }

    /// 서비스 이름을 IPv4 주소와 포트로 바꾼다(TCP 연결만 열었다 닫는다. 아무것도 보내지 않는다).
    private func resolve(_ endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint, case .ipv4(let address) = host {
                    // "192.168.0.10%en0"처럼 인터페이스가 붙으면 뗀다.
                    let text = "\(address)".split(separator: "%").first.map(String.init) ?? ""
                    self.complete(text.isEmpty ? nil : DirectEndpoint(host: text, port: Int(port.rawValue)))
                } else {
                    self.complete(nil)
                }
            case .failed, .cancelled:
                self.complete(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func finish(_ value: DirectEndpoint?) {
        queue.async { self.complete(value) }
    }

    private func complete(_ value: DirectEndpoint?) {
        guard !done else { return }
        done = true
        browser?.cancel()
        connection?.cancel()
        browser = nil
        connection = nil
        continuation?.resume(returning: value)
        continuation = nil
    }
}
