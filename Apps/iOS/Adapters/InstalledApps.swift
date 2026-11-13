import Foundation

/// 이 iPhone에 설치된 앱의 버전.
struct InstalledApp: Hashable, Sendable {
    var version: String
    var buildNumber: String
}

/// 번들 ID로 설치된 앱의 버전을 읽는다.
///
/// iOS에는 이 값을 주는 공개 API가 없어 시스템의 비공개 클래스를 이름으로 찾아 쓴다. 클래스나 값이 없으면 `nil`을 돌려주므로
/// `nil`은 "설치되어 있지 않다"가 아니라 "알 수 없다"로 다룬다.
enum InstalledApps {
    struct Lookup {
        var app: InstalledApp?
        /// 진단 로그에 남기는 조회 경과.
        var trace: String
    }

    static func lookup(_ bundleID: String) -> Lookup {
        var trace: [String] = []
        if let app = viaProxy(bundleID, trace: &trace) { return Lookup(app: app, trace: trace.joined(separator: ", ")) }
        if let app = viaRecord(bundleID, trace: &trace) { return Lookup(app: app, trace: trace.joined(separator: ", ")) }
        return Lookup(app: nil, trace: trace.joined(separator: ", "))
    }

    private static func viaProxy(_ bundleID: String, trace: inout [String]) -> InstalledApp? {
        let selector = NSSelectorFromString("applicationProxyForIdentifier:")
        guard let type = NSClassFromString("LSApplicationProxy") as? NSObject.Type, type.responds(to: selector) else {
            trace.append("proxy: 클래스 없음")
            return nil
        }
        guard let proxy = type.perform(selector, with: bundleID)?.takeUnretainedValue() as? NSObject else {
            trace.append("proxy: 결과 없음")
            return nil
        }
        let installed = bool(proxy, "isInstalled")
        let app = app(from: proxy)
        trace.append("proxy: installed=\(installed.map(String.init) ?? "?") \(describe(app))")
        return installed == false ? nil : app
    }

    private static func viaRecord(_ bundleID: String, trace: inout [String]) -> InstalledApp? {
        typealias Initializer = @convention(c) (AnyObject, Selector, NSString, Bool, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
        let selector = NSSelectorFromString("initWithBundleIdentifier:allowPlaceholder:error:")
        guard let type = NSClassFromString("LSApplicationRecord") as? NSObject.Type,
              type.instancesRespond(to: selector),
              let method = class_getInstanceMethod(type, selector),
              let allocated = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else {
            trace.append("record: 클래스 없음")
            return nil
        }
        let initialize = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        var error: NSError?
        guard let record = initialize(allocated, selector, bundleID as NSString, false, &error)?.takeRetainedValue() as? NSObject else {
            trace.append("record: \(error.map { "\($0.domain) \($0.code)" } ?? "결과 없음")")
            return nil
        }
        let app = app(from: record)
        trace.append("record: \(describe(app))")
        return app
    }

    private static func app(from object: NSObject) -> InstalledApp? {
        guard let version = string(object, "shortVersionString"), let build = string(object, "bundleVersion") else { return nil }
        return InstalledApp(version: version, buildNumber: build)
    }

    private static func describe(_ app: InstalledApp?) -> String {
        app.map { "\($0.version) (\($0.buildNumber))" } ?? "버전 없음"
    }

    private static func string(_ object: NSObject, _ key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }

    private static func bool(_ object: NSObject, _ key: String) -> Bool? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? Bool
    }
}
