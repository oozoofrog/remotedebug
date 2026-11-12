import Foundation

/// iPhone 노드와 Mac이 같은 tailnet에 있는지. MagicDNS 이름은 `<기기>.<tailnet>.ts.net`이라
/// 첫 라벨을 뺀 나머지가 tailnet이다.
public enum TailnetMatch {
    /// `rd-mac-1.tail0001.ts.net` → `tail0001.ts.net`. MagicDNS 이름이 아니면 `nil`.
    public static func tailnet(of fqdn: String?) -> String? {
        guard var name = fqdn?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 4, labels.last == "net", labels[labels.count - 2] == "ts" else { return nil }
        return labels.dropFirst().joined(separator: ".")
    }

    /// 둘 다 알 수 있고 tailnet이 다르면 `true`. 하나라도 모르면 `false`(판단하지 않는다).
    public static func isDifferent(phone: String?, host: String?) -> Bool {
        guard let a = tailnet(of: phone), let b = tailnet(of: host) else { return false }
        return a != b
    }
}
