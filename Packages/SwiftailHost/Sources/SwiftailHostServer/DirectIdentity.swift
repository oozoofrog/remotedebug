import CryptoKit
import Darwin
import Foundation
import Synchronization

/// 같은 네트워크 직접 연결 리스너의 저장된 신원(docs/protocol-addenda.md O). 예전 Go 코어의 직접 연결 신원을 옮겨 온 것이다.
///
/// 파일은 예전 Go 코어가 남긴 것과 같은 이름·모양이다: `direct.json`(`{"id","port","hostId"}`), `direct-cert.pem`(`CERTIFICATE`),
/// `direct-key.pem`(예전 Go 코어는 SEC1 `EC PRIVATE KEY`, 새로 만들 때는 PKCS#8 `PRIVATE KEY`. 둘 다 읽는다). 그래서 예전 Go 코어가
/// 남긴 신원을 그대로 읽어 같은 공개 키로 답한다(페어링한 iPhone의 고정 값이 그대로 맞는다).
///
/// 키와 인증서는 한 번 만들고 바꾸지 않는다: iPhone이 그 공개 키를 고정한다.
public final class DirectIdentity: Sendable {
    public static let stateFile = "direct.json"
    public static let keyFile = "direct-key.pem"
    public static let certificateFile = "direct-cert.pem"
    /// Bonjour 서비스 종류.
    public static let serviceType = "_remotedebug._tcp"

    struct Stored: Codable, Equatable {
        var id: String
        var port: Int
        var hostId: String?
    }

    public enum Failure: Error, Equatable {
        /// 폴더나 파일을 쓰지 못했다(errno 이름만).
        case storage(String)
        /// 새 인증서를 만들지 못했다.
        case certificate
    }

    private let directory: URL
    private let stored: Mutex<Stored>
    /// 인증서 DER.
    public let certificateDER: [UInt8]
    let privateKey: P256.Signing.PrivateKey
    /// 인증서의 SubjectPublicKeyInfo SHA-256(base64). iPhone이 고정하는 값이다(`SPKIPin`).
    public let spki: String

    /// `directory`에서 읽고, 없거나 깨진 것은 만든다.
    public init(directory: URL) throws(Failure) {
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw .storage("mkdir")
        }
        var value = (try? Data(contentsOf: directory.appending(path: Self.stateFile)))
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored(id: "", port: 0, hostId: nil)
        if !Self.isValidID(value.id) {
            var bytes = [UInt8](repeating: 0, count: 8)
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = generator.next() }
            value.id = bytes.map { String(format: "%02x", $0) }.joined()
            try Self.save(value, in: directory)
        }
        if value.port < 0 || value.port > 65_535 { value.port = 0 }
        stored = Mutex(value)

        if let (der, key) = Self.loadPair(directory: directory) {
            (certificateDER, privateKey) = (der, key)
        } else {
            let key = P256.Signing.PrivateKey()
            guard let der = try? SelfSignedCertificate.make(key: key, commonName: "RemoteDebug direct", now: Date()) else {
                throw .certificate
            }
            try Self.write(Array(key.pemRepresentation.utf8), to: directory.appending(path: Self.keyFile))
            try Self.write(Array(PEM.encode(der, label: "CERTIFICATE").utf8), to: directory.appending(path: Self.certificateFile))
            (certificateDER, privateKey) = (der, key)
        }
        spki = Data(SHA256.hash(data: privateKey.publicKey.derRepresentation)).base64EncodedString()
    }

    /// Bonjour 인스턴스 이름(16진 16자).
    public var id: String { stored.withLock { $0.id } }
    /// 저장한 포트. 처음 듣기 전에는 0.
    public var port: Int { stored.withLock { $0.port } }
    /// 마지막으로 안 `/v1/info`의 `hostId`. tailnet 노드가 뜨기 전에 직접 연결이 답할 때 쓴다.
    public var hostID: String { stored.withLock { $0.hostId ?? "" } }

    public func setHostID(_ hostID: String) {
        let changed = stored.withLock { value -> Stored? in
            guard !hostID.isEmpty, value.hostId != hostID else { return nil }
            value.hostId = hostID
            return value
        }
        if let changed { try? Self.save(changed, in: directory) }
    }

    func setPort(_ port: Int) throws(Failure) {
        let value = stored.withLock { value -> Stored in
            value.port = port
            return value
        }
        try Self.save(value, in: directory)
    }

    /// TLS 1.3 서버 신원(Go `MinVersion: tls.VersionTLS13`).
    public func tlsIdentity() throws(TLSServerIdentity.Failure) -> TLSServerIdentity {
        try TLSServerIdentity(chain: [certificateDER], privateKeyX963: Array(privateKey.x963Representation), minimumVersion: .TLSv13)
    }

    // MARK: - 파일

    static func isValidID(_ text: String) -> Bool {
        text.utf8.count == 16 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0) }
    }

    /// 인증서와 키가 모두 읽히고 짝이 맞을 때만.
    static func loadPair(directory: URL) -> ([UInt8], P256.Signing.PrivateKey)? {
        guard let certificateText = try? String(contentsOf: directory.appending(path: certificateFile), encoding: .utf8),
              let keyText = try? String(contentsOf: directory.appending(path: keyFile), encoding: .utf8),
              let der = (try? PEMCertificates.ders(from: certificateText))?.first,
              let key = try? P256.Signing.PrivateKey(pemRepresentation: keyText),
              let publicKey = SelfSignedCertificate.subjectPublicKeyInfo(of: der),
              publicKey == Array(key.publicKey.derRepresentation) else { return nil }
        return (der, key)
    }

    static func save(_ value: Stored, in directory: URL) throws(Failure) {
        guard let data = try? JSONEncoder().encode(value) else { throw .storage("encode") }
        try write(Array(data), to: directory.appending(path: stateFile))
    }

    /// 임시 파일에 0600으로 쓰고 이름을 바꾼다(Go `writeFile`과 같은 차례).
    static func write(_ bytes: [UInt8], to url: URL) throws(Failure) {
        let temporary = url.path + ".tmp"
        unlink(temporary)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw .storage(FileSource.errnoName(errno)) }
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard written == bytes.count, synced, rename(temporary, url.path) == 0 else {
            let code = errno
            unlink(temporary)
            throw .storage(FileSource.errnoName(code))
        }
    }
}

enum PEM {
    static func encode(_ der: [UInt8], label: String) -> String {
        let base64 = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }
}

/// 자체 서명 X.509 v3 인증서(DER). Go `direct.loadOrCreateCert`의 서식과 같다: ECDSA P-256 / SHA-256, 주체·발급자 CN,
/// 하루 전부터 30년, keyUsage digitalSignature(critical), extKeyUsage serverAuth, basicConstraints CA 아님(critical).
enum SelfSignedCertificate {
    static func make(key: P256.Signing.PrivateKey, commonName: String, now: Date) throws -> [UInt8] {
        var serial = [UInt8](repeating: 0, count: 15)
        var generator = SystemRandomNumberGenerator()
        for index in serial.indices { serial[index] = generator.next() }
        serial[0] &= 0x7F
        if serial[0] == 0 { serial[0] = 1 }
        let algorithm = DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])])
        let name = DER.sequence([DER.set([DER.sequence([DER.oid([2, 5, 4, 3]), DER.utf8String(commonName)])])])
        let notBefore = now.addingTimeInterval(-86_400)
        let notAfter = Calendar(identifier: .gregorian).date(byAdding: .year, value: 30, to: now) ?? now.addingTimeInterval(30 * 365 * 86_400)
        let validity = DER.sequence([DER.time(notBefore), DER.time(notAfter)])
        let keyUsage = DER.sequence([DER.oid([2, 5, 29, 15]), DER.boolean(true), DER.octetString(DER.bitString([0x80], unused: 7))])
        let extendedKeyUsage = DER.sequence([DER.oid([2, 5, 29, 37]), DER.octetString(DER.sequence([DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1])]))])
        let basicConstraints = DER.sequence([DER.oid([2, 5, 29, 19]), DER.boolean(true), DER.octetString(DER.sequence([]))])
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer([2])),
            DER.integer(serial),
            algorithm,
            name,
            validity,
            name,
            Array(key.publicKey.derRepresentation),
            DER.explicit(3, DER.sequence([keyUsage, extendedKeyUsage, basicConstraints])),
        ])
        let signature = try key.signature(for: tbs).derRepresentation
        return DER.sequence([tbs, algorithm, DER.bitString(Array(signature), unused: 0)])
    }

    /// 인증서 DER에서 SubjectPublicKeyInfo DER를 꺼낸다(tbsCertificate의 일곱째 원소, version이 있을 때).
    static func subjectPublicKeyInfo(of certificate: [UInt8]) -> [UInt8]? {
        guard let outer = DER.children(of: certificate), let tbsBytes = outer.first, let fields = DER.children(of: tbsBytes) else {
            return nil
        }
        // version([0])이 있으면 SPKI는 여섯째(0부터), 없으면 다섯째.
        let hasVersion = fields.first?.first == 0xA0
        let index = hasVersion ? 6 : 5
        return fields.count > index ? fields[index] : nil
    }
}

/// 인증서에 필요한 만큼의 DER 쓰기·읽기.
enum DER {
    static func encode(tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var bytes = [tag]
        if content.count < 0x80 {
            bytes.append(UInt8(content.count))
        } else {
            var length = content.count
            var lengthBytes: [UInt8] = []
            while length > 0 {
                lengthBytes.insert(UInt8(length & 0xFF), at: 0)
                length >>= 8
            }
            bytes.append(0x80 | UInt8(lengthBytes.count))
            bytes += lengthBytes
        }
        return bytes + content
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { encode(tag: 0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { encode(tag: 0x31, items.flatMap { $0 }) }
    static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] { encode(tag: 0xA0 | number, content) }
    static func boolean(_ value: Bool) -> [UInt8] { encode(tag: 0x01, [value ? 0xFF : 0x00]) }
    static func octetString(_ content: [UInt8]) -> [UInt8] { encode(tag: 0x04, content) }
    static func bitString(_ content: [UInt8], unused: UInt8) -> [UInt8] { encode(tag: 0x03, [unused] + content) }
    static func utf8String(_ text: String) -> [UInt8] { encode(tag: 0x0C, Array(text.utf8)) }

    /// 양의 정수(큰 끝 바이트). 맨 앞 비트가 서 있으면 0을 앞에 붙인다.
    static func integer(_ value: [UInt8]) -> [UInt8] {
        var bytes = Array(value.drop { $0 == 0 })
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return encode(tag: 0x02, bytes)
    }

    static func oid(_ components: [UInt64]) -> [UInt8] {
        var bytes = [UInt8(components[0] * 40 + components[1])]
        for component in components.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(component & 0x7F)]
            var rest = component >> 7
            while rest > 0 {
                chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                rest >>= 7
            }
            bytes += chunk
        }
        return encode(tag: 0x06, bytes)
    }

    /// 2049년까지는 UTCTime, 그 뒤는 GeneralizedTime(RFC 5280 4.1.2.5).
    static func time(_ date: Date) -> [UInt8] {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        let year = Int(parts.tm_year) + 1900
        let rest = String(format: "%02d%02d%02d%02d%02dZ", parts.tm_mon + 1, parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec)
        if year < 2050 {
            return encode(tag: 0x17, Array((String(format: "%02d", year % 100) + rest).utf8))
        }
        return encode(tag: 0x18, Array((String(format: "%04d", year) + rest).utf8))
    }

    /// SEQUENCE 하나의 자식들(각 TLV 전체). 길이 형식이 어긋나면 nil.
    static func children(of element: [UInt8]) -> [[UInt8]]? {
        guard let (contentStart, contentEnd) = bounds(element, at: 0), element[0] & 0x20 != 0 else { return nil }
        var result: [[UInt8]] = []
        var index = contentStart
        while index < contentEnd {
            guard let (start, end) = bounds(element, at: index), end <= contentEnd else { return nil }
            _ = start
            result.append(Array(element[index..<end]))
            index = end
        }
        return result
    }

    /// `index`의 TLV에서 내용의 시작과 TLV의 끝.
    private static func bounds(_ bytes: [UInt8], at index: Int) -> (Int, Int)? {
        guard index + 2 <= bytes.count else { return nil }
        let first = bytes[index + 1]
        var length = 0
        var start = index + 2
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, start + count <= bytes.count else { return nil }
            for byte in bytes[start..<(start + count)] { length = length << 8 | Int(byte) }
            start += count
        }
        guard start + length <= bytes.count else { return nil }
        return (start, start + length)
    }
}
