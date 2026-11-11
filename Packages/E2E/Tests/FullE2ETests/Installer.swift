import CryptoKit
import Foundation
import PhoneClientKit
import RDModels

/// iOS 설치기 역할. 실제 `itms-services` 처리와 앱 설치는 하지 않는다. 설치기가 호스트에 보내는 요청만 재연한다.
struct InstallerPlayer {
    static let userAgent = "RDE2EInstaller/1.0"

    let transport: any HTTPTransport

    struct Manifest: Equatable {
        var ipaURL: URL
        var bundleID: String
        var version: String
        var title: String
        var kind: String
    }

    struct Reply {
        var status: Int
        var body: Data
        var contentType: String?
        var contentLength: String?
        var contentRange: String?
        var acceptRanges: String?
    }

    /// `itms-services://?action=download-manifest&url=…`에서 매니페스트 주소를 꺼낸다.
    static func manifestURL(fromInstallURL url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "itms-services",
              components.queryItems?.first(where: { $0.name == "action" })?.value == "download-manifest",
              let text = components.queryItems?.first(where: { $0.name == "url" })?.value, let manifest = URL(string: text)
        else { throw E2EError("설치 주소의 꼴이 다릅니다") }
        return manifest
    }

    func fetch(_ url: URL, method: String = "GET", range: ClosedRange<Int64>? = nil) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        let (data, response) = try await transport.send(request)
        return Reply(status: response.statusCode, body: data,
                     contentType: response.value(forHTTPHeaderField: "Content-Type"),
                     contentLength: response.value(forHTTPHeaderField: "Content-Length"),
                     contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                     acceptRanges: response.value(forHTTPHeaderField: "Accept-Ranges"))
    }

    static func parseManifest(_ data: Data) throws -> Manifest {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = plist["items"] as? [[String: Any]], items.count == 1,
              let assets = items[0]["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["kind"] as? String == "software-package" }),
              let text = asset["url"] as? String, let url = URL(string: text),
              let metadata = items[0]["metadata"] as? [String: Any],
              let bundleID = metadata["bundle-identifier"] as? String,
              let version = metadata["bundle-version"] as? String,
              let title = metadata["title"] as? String,
              let kind = metadata["kind"] as? String
        else { throw E2EError("매니페스트 구조가 protocol §4.5와 다릅니다") }
        return Manifest(ipaURL: url, bundleID: bundleID, version: version, title: title, kind: kind)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 받은 IPA가 빌드 설명의 크기·SHA-256과 같은지 확인한다. 다르면 던진다.
    static func verify(ipa: Data, against descriptor: BuildDescriptor) throws {
        guard Int64(ipa.count) == descriptor.ipa.size else {
            throw E2EError("IPA 크기가 다릅니다: \(ipa.count) ≠ \(descriptor.ipa.size)")
        }
        guard sha256Hex(ipa) == descriptor.ipa.sha256 else {
            throw E2EError("IPA SHA-256이 다릅니다")
        }
    }
}
