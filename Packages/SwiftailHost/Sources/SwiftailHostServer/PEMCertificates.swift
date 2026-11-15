import Foundation

/// PEM 파일의 `CERTIFICATE` 블록들을 DER로 읽는다(ACME 시험 루트용).
public enum PEMCertificates {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// `CERTIFICATE`가 아닌 블록이 있다.
        case unexpectedBlock
        /// BEGIN·END가 맞지 않거나 base64가 깨졌다.
        case malformed
        /// 인증서 블록이 하나도 없다.
        case empty

        public var description: String {
            switch self {
            case .unexpectedBlock: "PEM에 CERTIFICATE가 아닌 블록이 있다"
            case .malformed: "PEM 블록이 깨졌다"
            case .empty: "PEM에 CERTIFICATE 블록이 없다"
            }
        }
    }

    private static let begin = "-----BEGIN CERTIFICATE-----"
    private static let end = "-----END CERTIFICATE-----"

    /// 나온 차례대로 DER. 블록 밖의 글은 무시한다(설명 줄이 붙은 번들을 받는다).
    public static func ders(from pem: String) throws(Failure) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var rest = Substring(pem)
        while let marker = rest.range(of: "-----BEGIN ") {
            guard rest[marker.lowerBound...].hasPrefix(begin) else { throw .unexpectedBlock }
            let bodyStart = rest.index(marker.lowerBound, offsetBy: begin.count)
            guard let close = rest[bodyStart...].range(of: end) else { throw .malformed }
            let body = rest[bodyStart..<close.lowerBound].filter { !$0.isWhitespace }
            guard !body.contains("-"), let data = Data(base64Encoded: String(body)), !data.isEmpty else { throw .malformed }
            result.append([UInt8](data))
            rest = rest[close.upperBound...]
        }
        guard !result.isEmpty else { throw .empty }
        return result
    }
}
