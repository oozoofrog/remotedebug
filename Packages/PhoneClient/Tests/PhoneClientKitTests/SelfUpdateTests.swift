import Foundation
import RDModels
import Testing

@testable import PhoneClientKit

@Suite struct SelfUpdateTests {
    private let installedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func build(_ id: String, bundleID: String, publishedAfterInstall seconds: TimeInterval) throws -> BuildDescriptor {
        var build = try Examples.buildDescriptor()
        build.id = id
        build.bundleId = bundleID
        build.publishedAt = installedAt.addingTimeInterval(seconds)
        return build
    }

    @Test func offersBuildPublishedAfterInstall() throws {
        let newer = try build("b_new", bundleID: "app.self", publishedAfterInstall: 60)
        let other = try build("b_other", bundleID: "app.other", publishedAfterInstall: 600)
        #expect(SelfUpdate.candidate(in: [other, newer], bundleID: "app.self", installedAt: installedAt)?.id == "b_new")
    }

    @Test func ignoresBuildPublishedBeforeInstall() throws {
        let older = try build("b_old", bundleID: "app.self", publishedAfterInstall: -60)
        #expect(SelfUpdate.candidate(in: [older], bundleID: "app.self", installedAt: installedAt) == nil)
    }

    @Test func picksLatestOfSeveral() throws {
        let builds = [
            try build("b_1", bundleID: "app.self", publishedAfterInstall: 10),
            try build("b_3", bundleID: "app.self", publishedAfterInstall: 30),
            try build("b_2", bundleID: "app.self", publishedAfterInstall: 20),
        ]
        #expect(SelfUpdate.candidate(in: builds, bundleID: "app.self", installedAt: installedAt)?.id == "b_3")
    }

    @Test func installDateIsFirstLaunchOfThisBuild() throws {
        let suite = "selfupdate-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SelfUpdate.installDate(of: .main, defaults: defaults, now: first) == first)
        // 같은 빌드를 다시 실행하면 처음 시각을 그대로 쓴다.
        #expect(SelfUpdate.installDate(of: .main, defaults: defaults, now: first.addingTimeInterval(600)) == first)
        // 다른 빌드가 설치되면(지문이 다르면) 새로 저장한다.
        defaults.set("other", forKey: SelfUpdate.fingerprintKey)
        let later = first.addingTimeInterval(3600)
        #expect(SelfUpdate.installDate(of: .main, defaults: defaults, now: later) == later)
    }

    @Test func nothingWithoutIdentityOrInstallDate() throws {
        let newer = try build("b_new", bundleID: "app.self", publishedAfterInstall: 60)
        #expect(SelfUpdate.candidate(in: [newer], bundleID: nil, installedAt: installedAt) == nil)
        #expect(SelfUpdate.candidate(in: [newer], bundleID: "app.self", installedAt: nil) == nil)
        #expect(SelfUpdate.candidate(in: [], bundleID: "app.self", installedAt: installedAt) == nil)
    }
}
