import Foundation

/// 앱 페어링 링크의 앞부분(docs/protocol-addenda.md B.5).
///
/// 기본은 사용자 지정 스킴 `remotedebug://pair`다. 빌드 설정 `RD_PAIR_LINK_HOST`(와 `RD_PAIR_LINK_PATH`)를 채워 빌드하면
/// 두 앱의 Info.plist `RDPairLinkBase`에 `https://<호스트><경로>`가 들어가고, 이 형식이 그것을 연결 도메인(universal link)
/// 주소로 읽는다. 값이 비었거나 올바르지 않으면 없는 것으로 다룬다.
public struct PairingLinkBase: Sendable, Hashable, CustomStringConvertible {
    /// Info.plist 키.
    public static let infoKey = "RDPairLinkBase"
    /// 사용자 지정 스킴 링크의 앞부분.
    public static let customScheme = "remotedebug://pair"

    /// `https://<호스트><경로>`. 호스트는 소문자, 경로는 `/`로 시작하고 `/`로 끝나지 않는다.
    public let url: URL
    /// 소문자 호스트(연결 도메인 권한의 `applinks:` 뒤 값).
    public let host: String
    /// `/`로 시작하고 `/`로 끝나지 않는 경로. 루트(`/`)는 받지 않는다.
    public let path: String

    /// 설정 글자를 읽는다. https이고, 호스트가 DNS 이름이고, 루트가 아닌 경로가 있고, 포트·사용자 정보·쿼리·조각이 없어야 한다.
    public init?(_ text: String?) {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              // 퍼센트 인코딩과 공백은 받지 않는다(받는 쪽이 같은 글자로 견준다).
              !raw.contains("%"), !raw.contains(where: \.isWhitespace),
              let parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              let rawHost = parts.host, Self.isDNSName(rawHost.lowercased())
        else { return nil }
        var path = parts.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/"), path != "/", !path.contains("//") else { return nil }
        let host = rawHost.lowercased()
        guard let url = URL(string: "https://\(host)\(path)") else { return nil }
        (self.url, self.host, self.path) = (url, host, path)
    }

    /// 앱 번들의 Info.plist에서 읽는다. 키가 없거나 값이 올바르지 않으면 nil.
    public static func fromInfo(_ info: [String: Any]?) -> PairingLinkBase? {
        PairingLinkBase(info?[infoKey] as? String)
    }

    /// 받은 URL 글자가 이 주소의 링크인가: https, 같은 호스트(대소문자 무시)와 같은 경로(끝의 `/` 하나는 받는다),
    /// 포트·사용자 정보·쿼리 없음. 조각(`#` 뒤)은 보지 않는다.
    public func matches(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        guard !head.contains("%"), let parts = URLComponents(string: head),
              parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil,
              parts.host?.lowercased() == host
        else { return false }
        return parts.path == path || parts.path == path + "/"
    }

    public var description: String { url.absoluteString }

    /// 라벨 1~63자(`a-z0-9-`, 하이픈으로 시작·끝나지 않음), 라벨 둘 이상, 전체 253자 이하, 끝 라벨이 숫자뿐이 아님.
    static func isDNSName(_ name: String) -> Bool {
        guard name.utf8.count <= 253 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-",
                  label.utf8.allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D })
            else { return false }
        }
        return !(labels.last?.allSatisfy(\.isNumber) ?? true)
    }
}
