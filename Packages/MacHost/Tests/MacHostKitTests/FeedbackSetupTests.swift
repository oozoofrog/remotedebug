import Foundation
import Testing
@testable import MacHostKit

@Suite struct FeedbackSetupTests {
    @Test func 프로젝트_파일에_패키지_이름이_있으면_넣은_것으로_본다() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rd-feedback-\(UUID().uuidString)")
        let container = folder.appendingPathComponent("Sample.xcodeproj")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = ConnectedProject(container: container.path, addedAt: Date())
        try Data("/* no packages */".utf8).write(to: container.appendingPathComponent("project.pbxproj"))
        #expect(!FeedbackSetup.isAdded(to: project))
        try Data("productName = RemoteDebugFeedback;".utf8).write(to: container.appendingPathComponent("project.pbxproj"))
        #expect(FeedbackSetup.isAdded(to: project))
    }

    @Test func 안내_코드에_Mac_주소가_들어간다() {
        #expect(FeedbackSetup.snippet(host: "rd-mac-1a2b3c4d.tail0001.ts.net").contains(#"macHost: "rd-mac-1a2b3c4d.tail0001.ts.net""#))
        let full = FeedbackSetup.snippet(host: "mac.example", email: "dev@example.com", publicKey: "QUJD")
        #expect(full.contains(#"email: "dev@example.com""#) && full.contains(#"publicKeyBase64: "QUJD""#))
        #expect(!FeedbackSetup.snippet(host: "mac.example").contains("email:"))
        #expect(FeedbackSetup.snippet(host: "").contains("<이 Mac의 주소>"))
    }
}
