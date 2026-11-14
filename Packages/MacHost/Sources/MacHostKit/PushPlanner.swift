import Foundation
import RDModels

/// 빌드·보낸 파일 목록의 변화에서 새 항목을 가린다. 부작용이 없다.
///
/// 첫 관찰은 기준선으로만 삼는다(앱을 켤 때 이미 있던 항목은 알리지 않는다). 목록을 다시 읽기만 했거나
/// 항목이 빠지기만 했으면 아무것도 내지 않는다. 리소스 id는 이름과 내용의 해시로 정해지므로(`ResourceDescriptor.makeID`)
/// 같은 이름으로 내용을 바꿔 다시 보내면 새 항목이고, 같은 파일을 그대로 다시 보내면 새 항목이 아니다.
public struct PushTracker: Sendable, Hashable {
    private var buildIDs: Set<String>?
    private var resourceIDs: Set<String>?

    public init() {}

    public struct Changes: Sendable, Hashable {
        public var builds: [BuildDescriptor] = []
        public var resources: [ResourceDescriptor] = []
        public var isEmpty: Bool { builds.isEmpty && resources.isEmpty }
    }

    /// 지금 목록을 보고 새 항목을 돌려준다. 기준선은 지금 목록으로 바뀐다.
    public mutating func observe(builds: [BuildDescriptor], resources: [ResourceDescriptor]) -> Changes {
        var changes = Changes()
        let nowBuilds = Set(builds.map(\.id))
        let nowResources = Set(resources.map(\.id))
        if let seen = buildIDs { changes.builds = builds.filter { !seen.contains($0.id) } }
        if let seen = resourceIDs { changes.resources = resources.filter { !seen.contains($0.id) } }
        buildIDs = nowBuilds
        resourceIDs = nowResources
        return changes
    }
}

/// 묶는 동안 쌓인 새 항목. 빌드는 bundleId마다 가장 최근 것 하나, 파일·링크는 모두.
public struct PushBatch: Sendable, Hashable {
    public private(set) var builds: [String: BuildDescriptor] = [:]
    public private(set) var resources: [ResourceDescriptor] = []

    public init() {}

    public var isEmpty: Bool { builds.isEmpty && resources.isEmpty }

    public mutating func add(_ changes: PushTracker.Changes) {
        for build in changes.builds {
            if let held = builds[build.bundleId], held.publishedAt > build.publishedAt { continue }
            builds[build.bundleId] = build
        }
        for resource in changes.resources where !resources.contains(where: { $0.id == resource.id }) {
            resources.append(resource)
        }
    }
}

/// 알림 문구(docs/protocol-addenda.md P). 부작용이 없다.
public enum PushPlanner {
    /// 마지막 변화 뒤 이만큼 조용하면 보낸다.
    public static let quietPeriod: Duration = .seconds(5)

    /// 알림 문구 키(docs/protocol-addenda.md P.5). iPhone은 자기 언어로 이 키를 찾아 보이고, 못 찾으면 title·body를 그대로 보인다.
    /// 키마다 아래에서 같은 글자의 `String(localized:)`로 대체 문구를 만들므로 문자열 추출이 키를 카탈로그에 넣는다.
    enum Key {
        static let newBuildTitle = "새 빌드"
        static let newFileTitle = "새 파일"
        static let newLinkTitle = "새 링크"
        static let newBuildsHidden = "새 빌드가 있습니다"
        static let newFilesHidden = "새 파일이 있습니다"
        static let test = "시험 알림입니다"
        static let fileCount = "파일 %@개"
        static let linkCount = "링크 %@개"
    }

    public static let test = APNsNotification(title: "RemoteDebug", body: String(localized: "시험 알림입니다"), kind: .test,
                                              bodyLocKey: Key.test)

    /// 묶음을 보낼 알림으로 바꾼다. 빌드는 앱마다 하나(이름을 숨기면 하나로 합친다), 파일·링크는 하나.
    public static func notifications(for batch: PushBatch, hideNames: Bool) -> [APNsNotification] {
        var list: [APNsNotification] = []
        if !batch.builds.isEmpty {
            if hideNames {
                list.append(APNsNotification(title: "RemoteDebug", body: String(localized: "새 빌드가 있습니다"), kind: .build,
                                             bodyLocKey: Key.newBuildsHidden))
            } else {
                list += batch.builds.values.sorted { ($0.publishedAt, $0.bundleId) < ($1.publishedAt, $1.bundleId) }.map(buildNotification)
            }
        }
        if let files = resourceNotification(batch.resources, hideNames: hideNames) { list.append(files) }
        return list
    }

    public static func buildNotification(_ build: BuildDescriptor) -> APNsNotification {
        APNsNotification(title: String(localized: "새 빌드"), body: "\(build.displayName) \(build.version) (\(build.buildNumber))", kind: .build,
                         id: build.id, category: .build, titleLocKey: Key.newBuildTitle)
    }

    public static func resourceNotification(_ items: [ResourceDescriptor], hideNames: Bool) -> APNsNotification? {
        guard let first = items.first else { return nil }
        if hideNames {
            return APNsNotification(title: "RemoteDebug", body: String(localized: "새 파일이 있습니다"), kind: .resource,
                                    bodyLocKey: Key.newFilesHidden)
        }
        let allLinks = items.allSatisfy(\.isLink)
        let title = allLinks ? String(localized: "새 링크") : String(localized: "새 파일")
        let titleKey = allLinks ? Key.newLinkTitle : Key.newFileTitle
        if items.count == 1 {
            return APNsNotification(title: title, body: first.name, kind: .resource, id: first.id,
                                    category: first.isLink ? .link : .file, titleLocKey: titleKey)
        }
        // 개수는 문자열로 넘긴다(loc-args는 문자열만, 자릿수 묶음 없이).
        let count = String(items.count)
        let body = allLinks ? String(localized: "링크 \(count)개") : String(localized: "파일 \(count)개")
        return APNsNotification(title: title, body: body, kind: .resource, titleLocKey: titleKey,
                                bodyLocKey: allLinks ? Key.linkCount : Key.fileCount, bodyLocArgs: [count])
    }
}
