import Foundation
import SwiftailCertificates
import SwiftailHostServer

/// ACME 디렉터리와 인증서 검증 앵커를 `CertificateConfiguration`으로 잇는 유일한 곳.
enum CertificateTrust {
    enum Refusal: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    /// 앵커 PEM 파일의 크기 한도.
    static let maximumPEMBytes = 262_144

    /// 운영은 시스템 루트로만 검증한다(앵커를 주면 Swiftail이 시스템 루트를 쓰지 않아 운영 사슬이 거절된다).
    /// 스테이징·시험 디렉터리는 그 디렉터리의 루트를 앵커로 줘야 한다. 앵커는 발급받은 사슬의 검증에만 쓰인다.
    static func configuration(for options: Options) throws(Refusal) -> CertificateConfiguration {
        if options.isProduction {
            guard options.acmeRoots == nil else {
                throw .message("운영 디렉터리는 시스템 루트로만 검증한다. --acme-roots를 빼고 다시 실행한다")
            }
            return CertificateConfiguration(directoryURL: CertificateConfiguration.letsEncryptDirectoryURL)
        }
        guard let roots = options.acmeRoots else {
            throw .message("스테이징·시험 디렉터리에는 --acme-roots(그 디렉터리의 루트 PEM)가 필요하다. 운영 발급은 --acme-production으로 한다")
        }
        let anchors = try readAnchors(roots)
        guard !anchors.isEmpty else { throw .message("--acme-roots: CERTIFICATE 블록이 없다") }
        return CertificateConfiguration(directoryURL: options.acmeDirectory, trustAnchors: anchors)
    }

    static func readAnchors(_ url: URL) throws(Refusal) -> [[UInt8]] {
        guard let data = try? Data(contentsOf: url), data.count <= maximumPEMBytes else {
            throw .message("--acme-roots 파일을 읽지 못함(256KiB까지)")
        }
        do {
            return try PEMCertificates.ders(from: String(decoding: data, as: UTF8.self))
        } catch {
            throw .message("--acme-roots: \(error)")
        }
    }
}
