import CryptoKit
import Darwin.C.string
import Foundation
import RDModels

public enum HostIDs {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static func newPairCode() -> String {
        String((0..<8).map { _ in alphabet[Int(UInt8.random(in: .min ... .max) & 31)] })
    }
    public static func displayPairCode(_ code: String) -> String {
        code.utf8.count == 8 ? String(code.prefix(4)) + "-" + code.suffix(4) : code
    }
    public static func normalizePairCode(_ input: String) -> String {
        var result = ""
        for scalar in input.unicodeScalars {
            let upper = String(scalar).uppercased()
            guard upper.unicodeScalars.count == 1, let character = upper.first else { return "" }
            switch character {
            case "-", " ": continue
            case "O": result.append("0")
            case "I", "L": result.append("1")
            default:
                guard alphabet.contains(character) else { return "" }
                result.append(character)
            }
        }
        return result.utf8.count == 8 ? result : ""
    }
    public static func pairCodeEqual(_ stored: String, _ input: String) -> Bool {
        let normalized = normalizePairCode(input)
        return !normalized.isEmpty && constantEqual(stored, normalized)
    }
    public static func newToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func newID(_ prefix: String) -> String {
        prefix + (0..<4).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
    public static func buildID(bundleID: String, sha256: String) -> String { BuildDescriptor.makeID(bundleId: bundleID, ipaSHA256: sha256) }
    public static func resourceID(name: String, sha256: String) -> String { ResourceDescriptor.makeID(name: name, sha256: sha256) }
    public static func hostID(stableID: String) -> String { "h_" + sha256(Data(("rd-host\n" + stableID).utf8)).prefix(8) }
    public static func directTokenHash(_ token: String) -> String {
        let cleaned = token.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        guard cleaned.utf8.count == 43, cleaned.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let raw = Data(base64Encoded: cleaned.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), raw.count == 32 else { return "" }
        return sha256(raw)
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func constantEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        if x.isEmpty { return true }
        return x.withUnsafeBufferPointer { left in
            y.withUnsafeBufferPointer { right in
                timingsafe_bcmp(left.baseAddress!, right.baseAddress!, x.count) == 0
            }
        }
    }
}

public enum HostErrors {
    public static func make(_ code: String, _ message: String? = nil) -> APIErrorBody {
        APIErrorBody(code: code, message: message ?? messages[code] ?? "내부 오류입니다.")
    }
    public static func status(_ error: APIErrorBody) -> Int {
        switch error.error.code {
        case "bad_request": 400
        case "not_paired", "pair_code_invalid", "token_invalid", "agent_disabled", "origin_not_allowed", "node_login_mismatch": 403
        case "unsupported_media_type": 415
        case "not_found", "build_not_found", "resource_not_found", "direct_off": 404
        case "method_not_allowed": 405
        case "build_changed", "cable_required", "cable_device_mismatch", "cable_busy": 409
        case "session_expired": 410
        case "not_debug_build": 422
        case "too_many_attempts": 429
        default: 500
        }
    }
    public static func from(_ error: any Error) -> APIErrorBody {
        (error as? APIErrorBody) ?? make("internal", String(describing: error))
    }
    static let messages = [
        "not_paired": "허용 목록에 없는 기기입니다.",
        "node_login_mismatch": "이 tailnet 노드의 로그인 계정이 페어링한 기기의 계정과 다릅니다.",
        "pair_code_invalid": "페어링 코드가 없거나 맞지 않거나 만료되었습니다.",
        "token_invalid": "세션 토큰이 맞지 않습니다.", "build_not_found": "빌드가 없습니다.",
        "resource_not_found": "파일이 없습니다.", "build_changed": "게시 후 빌드 파일이 바뀌었습니다.",
        "session_expired": "세션이 만료되었거나 완료되었습니다.",
        "too_many_attempts": "코드 시도 횟수를 넘었습니다. 새 코드를 여세요.",
        "not_found": "알 수 없는 경로입니다.", "method_not_allowed": "이 경로에서 지원하지 않는 메서드입니다.",
        "unknown_handle": "알 수 없는 핸들입니다.", "path_outside_publish_dir": "IPA가 게시 폴더 안의 일반 파일이 아닙니다.",
        "direct_off": "이 Mac은 같은 네트워크 직접 연결을 받지 않습니다.",
        "cable_required": "USB 케이블로 이 Mac에 꽂은 iPhone의 요청이 아닙니다.",
        "cable_device_mismatch": "이 기기의 USB 케이블 설치는 처음 설치한 iPhone에 묶여 있는데, 지금 케이블에는 다른 iPhone이 꽂혀 있습니다. iPhone을 바꿨다면 Mac 앱의 기기 목록에서 이 기기를 빼고 다시 페어링하세요.",
        "cable_busy": "이 iPhone에는 USB 케이블 설치가 이미 진행 중입니다. 끝난 뒤에 다시 설치하세요.",
        "agent_disabled": "이 Mac은 iPhone의 에이전트 요청을 받지 않습니다. Mac 앱의 에이전트 화면에서 켭니다."
    ]
}

// Go의 구조체 JSON 읽기처럼 빠진 값과 null은 기본값, 알 수 없는 키는 무시한다.
struct HostJSON {
    let fields: [String: Any]
    init(value: Any) throws {
        if value is NSNull { fields = [:] }
        else if let object = value as? [String: Any] { fields = object }
        else { throw HostErrors.make("bad_request", "요청 본문이 올바른 JSON이 아닙니다.") }
    }
    init(data: Data, singleValue: Bool = false) throws {
        let bytes = Array(data)
        guard let end = Self.valueEnd(bytes) else { throw HostErrors.make("bad_request", "요청 본문이 올바른 JSON이 아닙니다.") }
        if singleValue && bytes[end...].contains(where: { !Self.whitespace($0) }) {
            throw HostErrors.make("bad_request", "요청 본문이 올바른 JSON이 아닙니다.")
        }
        let validUTF8 = Data(String(decoding: bytes[..<end], as: UTF8.self).utf8)
        try self.init(value: JSONSerialization.jsonObject(with: validUTF8, options: [.fragmentsAllowed]))
    }
    func value(_ name: String) -> Any? {
        fields[name] ?? fields.first { $0.key.lowercased() == name.lowercased() }?.value
    }
    func string(_ name: String) throws -> String {
        guard let value = value(name), !(value is NSNull) else { return "" }
        guard let string = value as? String else { throw HostErrors.make("bad_request", "필드가 문자열이 아닙니다: " + name) }
        return string
    }
    func bool(_ name: String) throws -> Bool {
        guard let value = value(name), !(value is NSNull) else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw HostErrors.make("bad_request", "필드가 불리언이 아닙니다: " + name)
        }
        return number.boolValue
    }
    func integer(_ name: String) throws -> Int64 {
        guard let value = value(name), !(value is NSNull) else { return 0 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int64(number.stringValue) else { throw HostErrors.make("bad_request", "필드가 정수가 아닙니다: " + name) }
        return integer
    }
    func array(_ name: String) throws -> [Any] {
        guard let value = value(name), !(value is NSNull) else { return [] }
        guard let array = value as? [Any] else { throw HostErrors.make("bad_request", "필드가 배열이 아닙니다: " + name) }
        return array
    }
    static func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
    static func valueEnd(_ bytes: [UInt8]) -> Int? {
        guard let start = bytes.firstIndex(where: { !whitespace($0) }) else { return nil }
        if bytes[start] == 110 { return bytes.count >= start + 4 ? start + 4 : nil }
        guard bytes[start] == 123 || bytes[start] == 91 else { return nil }
        var depth = 0, string = false, escape = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if string {
                if escape { escape = false }
                else if byte == 92 { escape = true }
                else if byte == 34 { string = false }
            } else {
                if byte == 34 { string = true }
                else if byte == 123 || byte == 91 { depth += 1 }
                else if byte == 125 || byte == 93 {
                    depth -= 1
                    if depth == 0 { return index + 1 }
                }
            }
        }
        return nil
    }
}

func hostTimestamp(_ date: Date) -> String { RDTimestamp.string(date) }
func hostTruncate(_ string: String, bytes: Int) -> String {
    var end = string.utf8.startIndex
    for scalar in string.unicodeScalars {
        let next = string.utf8.index(end, offsetBy: scalar.utf8.count)
        if string.utf8.distance(from: string.utf8.startIndex, to: next) > bytes { break }
        end = next
    }
    return String(string[..<end])
}

extension HostLogic {
    public static func baseURL(tls: Bool, fqDN: String, port: Int) -> String {
        let name = fqDN.hasSuffix(".") ? String(fqDN.dropLast()) : fqDN
        return (tls ? "https://" : "http://") + name + (tls && (port == 0 || port == 443) ? "" : ":\(port)")
    }
    static func redactPath(_ path: String) -> String {
        guard path.hasPrefix("/i/"), path.count > 3 else { return path }
        let rest = path.dropFirst(3)
        return "/i/…" + (rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "")
    }
    func json<T: Encodable>(_ value: T, status: Int = 200) -> HostResponse {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var bytes = Array(try encoder.encode(value))
            bytes.append(10)
            return HostResponse(status: status, headers: [("Content-Type", "application/json")], body: .bytes(bytes))
        } catch { return failure(HostErrors.from(error)) }
    }
    func object(_ value: [String: Any], status: Int = 200) -> HostResponse {
        do {
            var bytes = Array(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
            bytes.append(10)
            return HostResponse(status: status, headers: [("Content-Type", "application/json")], body: .bytes(bytes))
        } catch { return failure(HostErrors.from(error)) }
    }
    func wireObject<T: Encodable>(_ wire: Data?, fallback: T) throws -> Any {
        try JSONSerialization.jsonObject(with: wire ?? JSONEncoder().encode(fallback))
    }
    func failure(_ error: APIErrorBody) -> HostResponse {
        let bytes = (try? JSONEncoder().encode(error)) ?? Data()
        return HostResponse(status: HostErrors.status(error), headers: [("Content-Type", "application/json")], body: .bytes(Array(bytes)))
    }
    func deny(_ code: String, peer: HostPeer?, path: String) -> HostResponse {
        let redacted = Self.redactPath(path)
        let node = peer?.nodeName ?? ""
        var key = node + "\0" + redacted
        if denials[key] == nil && denials.count >= 1024 { key = node + "\0*" }
        let now = options.now()
        if var denial = denials[key] {
            if now.timeIntervalSince(denial.last) < 5 {
                denial.suppressed += 1
                denials[key] = denial
                return failure(HostErrors.make(code))
            }
            emit(.denied(.init(path: redacted, reason: code, nodeName: node.isEmpty ? nil : node,
                               suppressed: denial.suppressed == 0 ? nil : denial.suppressed)))
        } else { emit(.denied(.init(path: redacted, reason: code, nodeName: node.isEmpty ? nil : node))) }
        denials[key] = Denial(last: now)
        return failure(HostErrors.make(code))
    }
}

func hostPercentDecode(_ text: String) -> String? {
    let bytes = Array(text.utf8)
    var output: [UInt8] = [], index = 0
    func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
    while index < bytes.count {
        if bytes[index] == 37 {
            guard index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) else { return nil }
            output.append(high * 16 + low)
            index += 3
        } else { output.append(bytes[index]); index += 1 }
    }
    return String(decoding: output, as: UTF8.self)
}
