import Foundation
import RDModels
import Testing

@testable import RDBuildInspection
@testable import RDPackaging

@Suite struct PackagingTests {
    private func sha256(_ url: URL) throws -> String {
        let out = try runTool("/usr/bin/shasum", ["-a", "256", url.path]).output
        return String(out.split(separator: " ")[0])
    }

    @Test func ipaFromFixturePassesUnzipAndHasPayloadLayout() throws {
        let tmp = try TempDir("ipa")
        let ipa = tmp.path("AcceptedDev.ipa")
        let (size, sha) = try IPABuilder.package(appAt: Fixtures.app("Debug-iphoneos/AcceptedDev.app"), to: ipa)

        let t = try runTool("/usr/bin/unzip", ["-t", ipa.path])
        #expect(t.status == 0, "\(t.output)")
        #expect((try FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? NSNumber)?.int64Value == size)
        #expect(sha == (try sha256(ipa)))

        let names = try ZipReader(url: ipa).entries.map(\.name)
        #expect(names.first == "Payload/")
        #expect(names.contains("Payload/AcceptedDev.app/"))
        #expect(names.contains("Payload/AcceptedDev.app/Info.plist"))
        #expect(names.contains("Payload/AcceptedDev.app/_CodeSignature/CodeResources"))
        #expect(names.contains("Payload/AcceptedDev.app/embedded.mobileprovision"))
        #expect(names.allSatisfy { $0.hasPrefix("Payload/") })
        // 실행 파일의 실행 권한이 기록된다.
        let exe = try #require(try ZipReader(url: ipa).entries.first { $0.name == "Payload/AcceptedDev.app/AcceptedDev" })
        #expect(exe.permissions.map { $0 & 0o111 != 0 } == true)
    }

    @Test func packagingIsDeterministic() throws {
        let tmp = try TempDir("det")
        let a = try IPABuilder.package(appAt: Fixtures.app("loose/DebugDylib.app"), to: tmp.path("a.ipa"))
        let b = try IPABuilder.package(appAt: Fixtures.app("loose/DebugDylib.app"), to: tmp.path("b.ipa"))
        #expect(a.sha256 == b.sha256 && a.size == b.size)
        let names = try ZipReader(url: tmp.path("a.ipa")).entries.map(\.name)
        // 정확한 순서: Payload/, 앱 폴더, 그다음 깊이 우선·이름 오름차순(UTF-8 바이트). 폴더 항목 바로 뒤에 그 내용.
        let app = Fixtures.app("loose/DebugDylib.app")
        let expected = ["Payload/", "Payload/DebugDylib.app/"] + (try expectedOrder(app, prefix: "Payload/DebugDylib.app"))
        #expect(names == expected)
    }

    /// 테스트 쪽에서 따로 계산한 기대 순서.
    private func expectedOrder(_ dir: URL, prefix: String) throws -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        let names = try fm.contentsOfDirectory(atPath: dir.path).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        for name in names {
            let url = dir.appendingPathComponent(name)
            let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeDirectory {
                out.append("\(prefix)/\(name)/")
                out += try expectedOrder(url, prefix: "\(prefix)/\(name)")
            } else {
                out.append("\(prefix)/\(name)")
            }
        }
        return out
    }

    @Test func extractedIPAKeepsSignatureValidAndIsAccepted() throws {
        let tmp = try TempDir("ipa-inspect")
        let ipa = tmp.path("x.ipa")
        let packaged = try IPABuilder.package(appAt: Fixtures.app("loose/DebugDylib.app"), to: ipa)
        let work = tmp.path("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let result = try BuildInspector.inspect(ipaAt: ipa, options: .init(), workDirectory: work)
        #expect(result.accepted, "\(result.reasons)")
        let d = try #require(result.descriptor)
        #expect(d.configurationEvidence == .debugDylib)
        #expect(d.ipa.size == packaged.size && d.ipa.sha256 == packaged.sha256)
        #expect(d.id == BuildDescriptor.makeID(bundleId: d.bundleId, ipaSHA256: packaged.sha256))
        #expect((try FileManager.default.contentsOfDirectory(atPath: work.path)).isEmpty, "풀어 낸 폴더가 남았습니다")
    }

    @Test func ipaHasNoFolderConfigurationSoRuleOneNeedsEvidence() throws {
        let tmp = try TempDir("ipa-config")
        let ipa = tmp.path("dev.ipa")
        // AcceptedDev는 Debug-iphoneos 폴더에 있지만 IPA에는 그 정보가 없다.
        _ = try IPABuilder.package(appAt: Fixtures.app("Debug-iphoneos/AcceptedDev.app"), to: ipa)
        let work = tmp.path("w")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let rejected = try BuildInspector.inspect(ipaAt: ipa, options: .init(), workDirectory: work)
        #expect(rejected.reasons.map(\.code) == [.configurationUnverified])
        let ok = try BuildInspector.inspect(ipaAt: ipa, options: .init(confirmedDebug: true), workDirectory: work)
        #expect(ok.accepted && ok.descriptor?.configurationEvidence == .userConfirmed)
    }

    @Test func maliciousIPAThrowsUnreadable() throws {
        let tmp = try TempDir("ipa-evil")
        let evil = tmp.path("evil.ipa")
        // Info.plist는 유효하게 둬서, 던지는 이유가 경로 검사뿐이게 한다.
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.evil"], format: .xml, options: 0)
        let w = try ZipWriter(url: evil)
        try w.addData(info, name: "Payload/A.app/Info.plist", modified: Date())
        // 추출 폴더(work/rd-ipa-UUID)에서 Payload/A.app → ../../ = 추출 폴더, ../../../ = work, ../../../../ = tmp.
        // 경로 검사가 없으면 tmp/escape에 쓰인다.
        try w.addData(Data("x".utf8), name: "Payload/A.app/../../../../escape", modified: Date())
        try w.finish()
        let work = tmp.path("w")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        #expect(throws: InspectionError.unreadable("IPA에 안전하지 않은 경로가 있습니다")) {
            try BuildInspector.inspect(ipaAt: evil, options: .init(), workDirectory: work)
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.path("escape").path))
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("escape").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
        // 리더 단계의 검사도 같은 항목을 거부한다(이중 방어).
        #expect(throws: ZipError.unsafePath("Payload/A.app/../../../../escape")) {
            try ZipReader(url: evil).extractAll(to: work.appendingPathComponent("direct"))
        }
    }

    @Test func ipaWithoutExactlyOneAppIsUnreadable() throws {
        let tmp = try TempDir("ipa-shape")
        let none = tmp.path("none.ipa")
        let w = try ZipWriter(url: none)
        try w.addData(Data("x".utf8), name: "Payload/readme.txt", modified: Date())
        try w.finish()
        #expect(throws: InspectionError.self) { try BuildInspector.inspect(ipaAt: none, options: .init(), workDirectory: tmp.url) }
    }

    @Test func manifestIsValidPlistWithExpectedStructure() throws {
        let tmp = try TempDir("manifest")
        let ipaURL = URL(string: "https://rd-mac-ab12cd34.example-tailnet.ts.net/i/TOKEN/app.ipa")!
        let data = OTAManifest.make(bundleId: "com.example.app.Sample", version: "1.4.0", title: "Sample", ipaURL: ipaURL)
        let file = tmp.path("manifest.plist")
        try data.write(to: file)
        let lint = try runTool("/usr/bin/plutil", ["-lint", file.path])
        #expect(lint.status == 0, "\(lint.output)")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(text.contains("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\""))

        let root = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        let item = try #require((root["items"] as? [[String: Any]])?.first)
        let asset = try #require((item["assets"] as? [[String: Any]])?.first)
        #expect(asset["kind"] as? String == "software-package")
        #expect(asset["url"] as? String == ipaURL.absoluteString)
        let meta = try #require(item["metadata"] as? [String: Any])
        #expect(meta["bundle-identifier"] as? String == "com.example.app.Sample")
        #expect(meta["bundle-version"] as? String == "1.4.0")
        #expect(meta["kind"] as? String == "software")
        #expect(meta["title"] as? String == "Sample")
        #expect(Set(meta.keys).count == 4)
    }

    @Test func manifestEscapesXMLSpecialCharacters() throws {
        let data = OTAManifest.make(bundleId: "a.b", version: "1", title: "A & <B>", ipaURL: URL(string: "https://h/i/t/app.ipa?x=1&y=2")!)
        let root = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        let meta = try #require(((root["items"] as? [[String: Any]])?.first)?["metadata"] as? [String: Any])
        #expect(meta["title"] as? String == "A & <B>")
    }
}
