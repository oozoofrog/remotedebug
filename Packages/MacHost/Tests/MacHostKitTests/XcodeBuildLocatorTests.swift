import Foundation
import Testing
@testable import MacHostKit

@Suite struct XcodeBuildLocatorTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("rd-locator-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// `Debug-iphoneos/<이름>.app/<이름>`을 만든다.
    @discardableResult
    func makeApp(_ name: String, in products: URL, config: String = "Debug-iphoneos", modified: Date) throws -> URL {
        let app = products.appendingPathComponent("\(config)/\(name).app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let binary = app.appendingPathComponent(name)
        try Data("x".utf8).write(to: binary)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: binary.path)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: app.path)
        return app
    }

    func makeProject(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try fm.createDirectory(at: folder.appendingPathComponent("\(name).xcodeproj"), withIntermediateDirectories: true)
        return folder
    }

    func makeDerived(_ name: String, workspace: URL) throws -> URL {
        let entry = root.appendingPathComponent("DerivedData/\(name)")
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace.path], format: .xml, options: 0)
        try plist.write(to: entry.appendingPathComponent("info.plist"))
        return entry.appendingPathComponent("Build/Products")
    }

    @Test func findsTheBuildInDerivedDataByWorkspacePath() throws {
        let mine = try makeProject("Mine")
        let other = try makeProject("Other")
        let date = Date(timeIntervalSince1970: 1_000)
        try makeApp("Mine", in: makeDerived("Mine-abc", workspace: mine.appendingPathComponent("Mine.xcodeproj")), modified: date)
        try makeApp("Other", in: makeDerived("Other-def", workspace: other.appendingPathComponent("Other.xcodeproj")), modified: date)

        let found = XcodeBuildLocator.latestBuilds(for: mine, derivedData: root.appendingPathComponent("DerivedData"))
        #expect(found.map(\.app.lastPathComponent) == ["Mine.app"])
        #expect(found.first?.modified == date)
    }

    @Test func findsTheBuildInsideTheProjectFolderWithoutDerivedData() throws {
        let mine = try makeProject("Mine")
        try makeApp("Mine", in: mine.appendingPathComponent("Build/Products"), modified: Date(timeIntervalSince1970: 1_000))
        #expect(XcodeBuildLocator.latestBuilds(for: mine, derivedData: nil).map(\.app.lastPathComponent) == ["Mine.app"])
    }

    @Test func keepsOnlyTheNewestCopyAndSkipsOtherConfigurations() throws {
        let mine = try makeProject("Mine")
        let derived = try makeDerived("Mine-abc", workspace: mine.appendingPathComponent("Mine.xcodeproj"))
        try makeApp("Mine", in: mine.appendingPathComponent("Build/Products"), modified: Date(timeIntervalSince1970: 1_000))
        let newer = try makeApp("Mine", in: derived, modified: Date(timeIntervalSince1970: 2_000))
        try makeApp("Mine", in: derived, config: "Release-iphoneos", modified: Date(timeIntervalSince1970: 3_000))
        try makeApp("Mine", in: derived, config: "Debug-iphonesimulator", modified: Date(timeIntervalSince1970: 3_000))

        let found = XcodeBuildLocator.latestBuilds(for: mine, derivedData: root.appendingPathComponent("DerivedData"))
        #expect(found.map { $0.app.resolvingSymlinksInPath().path } == [newer.resolvingSymlinksInPath().path])
        #expect(found.first?.modified == Date(timeIntervalSince1970: 2_000))
    }

    @Test func aFolderWithoutAProjectFindsNothingInDerivedData() throws {
        let empty = root.appendingPathComponent("Empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(XcodeBuildLocator.containers(in: empty).isEmpty)
        #expect(XcodeBuildLocator.latestBuilds(for: empty, derivedData: root.appendingPathComponent("DerivedData")).isEmpty)
    }
}
