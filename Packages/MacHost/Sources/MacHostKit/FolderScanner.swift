import Foundation

/// 실행 파일의 수정 시각과 크기. 같으면 같은 빌드로 보고 다시 검사하지 않는다.
public struct BuildFingerprint: Codable, Sendable, Hashable {
    public var executableModified: Date
    public var executableSize: Int64

    public init(executableModified: Date, executableSize: Int64) {
        self.executableModified = executableModified
        self.executableSize = executableSize
    }
}

/// 폴더에서 iOS 기기용 `.app`을 찾는다.
///
/// 찾는 위치: `<폴더>/*-iphoneos/*.app`, `<폴더>/**/Build/Products/*-iphoneos/*.app`,
/// `<폴더>/**/Products/*-iphoneos/*.app`(깊이 제한). 그래서 DerivedData, 프로젝트의 `Build`, `Products` 중 무엇을 골라도 된다.
/// `*-Runner.app`(UI 테스트 러너)은 뺀다.
public struct FolderScanner: Sendable {
    public enum BundleState: Sendable, Hashable {
        case ready(BuildFingerprint)
        /// Info.plist나 실행 파일이 아직 없다(빌드 중).
        case building
    }

    /// `<폴더>`에서 `Build` 폴더까지 내려갈 최대 깊이.
    public var maxDepth: Int

    public init(maxDepth: Int = 8) {
        self.maxDepth = maxDepth
    }

    /// 찾은 `.app` 경로(정렬됨).
    public func findApps(in root: URL) -> [URL] {
        var found: [URL] = []
        let root = root.standardizedFileURL
        for child in subdirectories(of: root) where isConfigurationFolder(child) {
            found += apps(in: child)
        }
        walk(root, depth: 0, into: &found)
        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
    }

    /// 번들 상태와 지문.
    public static func state(of app: URL) -> BundleState {
        let fm = FileManager.default
        let plistURL = app.appendingPathComponent("Info.plist")
        guard let data = fm.contents(atPath: plistURL.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty
        else { return .building }
        let exe = app.appendingPathComponent(executable)
        guard let values = try? exe.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let modified = values.contentModificationDate,
              let size = values.fileSize
        else { return .building }
        return .ready(BuildFingerprint(executableModified: modified, executableSize: Int64(size)))
    }

    // MARK: 내부

    private func walk(_ dir: URL, depth: Int, into found: inout [URL]) {
        guard depth <= maxDepth else { return }
        for child in subdirectories(of: dir) {
            let name = child.lastPathComponent
            // `Build/Products/*-iphoneos`. 사용자가 `Build`나 `Products` 폴더 자체를 골라도 여기서 찾는다.
            if name == "Products" {
                for config in subdirectories(of: child) where isConfigurationFolder(config) {
                    found += apps(in: config)
                }
                continue
            }
            if name == "Build" {
                let products = child.appendingPathComponent("Products", isDirectory: true)
                for config in subdirectories(of: products) where isConfigurationFolder(config) {
                    found += apps(in: config)
                }
                continue
            }
            if shouldSkip(name) { continue }
            walk(child, depth: depth + 1, into: &found)
        }
    }

    private func isConfigurationFolder(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix("-iphoneos")
    }

    private func apps(in configFolder: URL) -> [URL] {
        subdirectories(of: configFolder).filter {
            $0.pathExtension == "app" && !$0.deletingPathExtension().lastPathComponent.hasSuffix("-Runner")
        }
    }

    private func shouldSkip(_ name: String) -> Bool {
        name.hasPrefix(".")
            || name.hasSuffix(".app") || name.hasSuffix("-iphoneos") || name.hasSuffix(".noindex") || name.hasSuffix(".xcarchive")
            || name.hasSuffix(".framework") || name.hasSuffix(".bundle") || name.hasSuffix(".xcassets")
            || name == "node_modules" || name == "SourcePackages" || name == "Pods"
    }

    /// 심볼릭 링크는 따라가지 않는다.
    private func subdirectories(of dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return [] }
        return items.filter {
            guard let v = try? $0.resourceValues(forKeys: Set(keys)) else { return false }
            return v.isDirectory == true && v.isSymbolicLink != true
        }
    }
}
