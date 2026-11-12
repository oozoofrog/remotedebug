import Foundation

/// 같은 앱(번들 ID)의 빌드 묶음. 가장 늦게 게시된 것이 `latest`, 나머지는 늦은 순서로 `older`.
public struct AppBuildGroup<Item> {
    public let bundleId: String
    public let latest: Item
    public let older: [Item]
}

extension AppBuildGroup: Identifiable {
    public var id: String { bundleId }
}

extension AppBuildGroup: Sendable where Item: Sendable {}

public enum AppBuildGrouping {
    /// 빌드를 번들 ID로 묶는다. 묶음은 최신 빌드의 게시 시각이 늦은 순서로 놓는다.
    public static func groups<Item>(_ items: [Item], descriptor: (Item) -> BuildDescriptor) -> [AppBuildGroup<Item>] {
        var order: [String] = []
        var byBundle: [String: [Item]] = [:]
        for item in items {
            let key = descriptor(item).bundleId
            if byBundle[key] == nil { order.append(key) }
            byBundle[key, default: []].append(item)
        }
        let groups: [AppBuildGroup<Item>] = order.compactMap { key in
            let sorted = (byBundle[key] ?? []).sorted { descriptor($0).publishedAt > descriptor($1).publishedAt }
            guard let latest = sorted.first else { return nil }
            return AppBuildGroup(bundleId: key, latest: latest, older: Array(sorted.dropFirst()))
        }
        return groups.sorted { descriptor($0.latest).publishedAt > descriptor($1.latest).publishedAt }
    }

    public static func groups(_ builds: [BuildDescriptor]) -> [AppBuildGroup<BuildDescriptor>] {
        groups(builds) { $0 }
    }
}
