#if os(macOS)
import Foundation

/// protocol §4.5 OTA 매니페스트(XML plist).
public enum OTAManifest {
    public static func make(bundleId: String, version: String, title: String, ipaURL: URL) -> Data {
        let plist: [String: Any] = [
            "items": [
                [
                    "assets": [
                        ["kind": "software-package", "url": ipaURL.absoluteString]
                    ],
                    "metadata": [
                        "bundle-identifier": bundleId,
                        "bundle-version": version,
                        "kind": "software",
                        "title": title,
                    ],
                ]
            ]
        ]
        // 문자열·배열·딕셔너리만 담으므로 직렬화는 실패하지 않는다.
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }
}
#endif
