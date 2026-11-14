import Foundation

/// 등록한 프로젝트 폴더의 최근 기기용 Debug 빌드를 `xcodebuild` 없이 찾는다.
///
/// Xcode는 빌드 결과를 DerivedData의 `<이름>-<해시>/Build/Products`(기본)나 프로젝트 폴더 안 `Build/Products`
/// (빌드 위치를 프로젝트 기준 상대 경로로 둔 경우)에 둔다. DerivedData의 각 폴더는 `info.plist`의 `WorkspacePath`에
/// 프로젝트 경로를 적어 두므로 그 값으로 프로젝트의 폴더를 고른다.
public enum XcodeBuildLocator {
    /// 찾은 빌드 하나.
    public struct Found: Sendable, Hashable {
        public var app: URL
        public var modified: Date
    }

    /// 프로젝트 폴더 바로 아래의 `.xcworkspace`·`.xcodeproj`.
    public static func containers(in folder: URL, fileManager: FileManager = .default) -> [URL] {
        let items = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { ["xcworkspace", "xcodeproj"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `derivedData` 안에서 이 프로젝트 폴더의 프로젝트·워크스페이스를 빌드한 폴더들의 `Build/Products`.
    public static func derivedProducts(for folder: URL, derivedData: URL, fileManager: FileManager = .default) -> [URL] {
        let wanted = Set(containers(in: folder, fileManager: fileManager).map { $0.standardizedFileURL.path })
        guard !wanted.isEmpty else { return [] }
        let entries = (try? fileManager.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { entry in
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("info.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let path = plist["WorkspacePath"] as? String,
                  wanted.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
            else { return nil }
            return entry.appendingPathComponent("Build/Products")
        }
    }

    /// 프로젝트 폴더 안의 빌드 위치 후보.
    public static func localProducts(for folder: URL) -> [URL] {
        ["Build/Products", "build/Products", "DerivedData/Build/Products"].map { folder.appendingPathComponent($0) }
    }

    /// `products` 폴더들의 `Debug-iphoneos`에서 `.app`을 찾는다. 같은 이름의 앱이 여러 곳에 있으면 가장 최근 것만 남긴다.
    public static func debugDeviceApps(in products: [URL], fileManager: FileManager = .default) -> [Found] {
        var newest: [String: Found] = [:]
        for root in products {
            let folder = root.appendingPathComponent("Debug-iphoneos")
            let items = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for app in items where app.pathExtension == "app" {
                // 앱 폴더의 수정 시각은 안의 파일이 바뀌어도 그대로일 수 있어 실행 파일의 시각을 본다.
                let binary = app.appendingPathComponent(app.deletingPathExtension().lastPathComponent)
                let date = [binary, app].compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
                guard let date else { continue }
                let found = Found(app: app, modified: date)
                if let old = newest[app.lastPathComponent], old.modified >= date { continue }
                newest[app.lastPathComponent] = found
            }
        }
        return newest.values.sorted { $0.app.lastPathComponent < $1.app.lastPathComponent }
    }

    /// 프로젝트 폴더의 최근 기기용 Debug 빌드. `derivedData`가 nil이면 프로젝트 폴더 안만 본다.
    public static func latestBuilds(for folder: URL, derivedData: URL?, fileManager: FileManager = .default) -> [Found] {
        var products = localProducts(for: folder)
        if let derivedData { products += derivedProducts(for: folder, derivedData: derivedData, fileManager: fileManager) }
        return debugDeviceApps(in: products, fileManager: fileManager)
    }
}
