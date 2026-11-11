import AppKit
import Foundation
@testable import MacHostKit
import RDModels
import SwiftUI
import Testing
@testable import MacHostUI

/// 복사 버튼이 클립보드·VoiceOver에 보낸 것을 기록한다(실제 클립보드를 건드리지 않는다).
@MainActor
final class CopyLog {
    var writes: [String] = []
    var announcements: [String] = []

    var copier: LinkCopier {
        LinkCopier(write: { [self] in writes.append($0) }, announce: { [self] in announcements.append($0) })
    }
}

extension ScreenTests {
    static let pageAddress = "https://\(PreviewFactory.fqdn)/"
    static let pageLink = "https://\(PreviewFactory.fqdn)/#code=K7M29QXD"

    func pairingModel(_ scenario: PreviewScenario, _ tmp: UITempDir) async -> HostModel {
        await PreviewFactory.makePairingModel(scenario, root: tmp.url.appendingPathComponent("host", isDirectory: true))
    }

    /// 시트의 설치 페이지 부분과 네트워크 화면의 줄은 페어링할 수 있을 때만 있다.
    @Test func installPageShowsOnlyWhenPairingIsAvailable() async throws {
        let tmp = try UITempDir("installdecide")
        let sharing = await pairingModel(.sharing, tmp)
        #expect(PairingSheet.installPageLink(sharing)?.absoluteString == Self.pageLink)
        #expect(NetworkView.installPageAddress(sharing)?.absoluteString == Self.pageAddress, "주소 줄에는 코드를 넣지 않는다")
        sharing.handle(.denied(DeniedEvent(path: "/v1/pair/request", reason: "too_many_attempts")))
        #expect(PairingSheet.installPageLink(sharing) == nil, "폐기된 코드")
        #expect(NetworkView.installPageAddress(sharing) != nil)
        await sharing.shutdown()
        #expect(NetworkView.installPageAddress(sharing) == nil)

        for scenario in [PreviewScenario.empty, .needsLogin, .certificatesOff, .error, .pairingUnavailable] {
            let model = await pairingModel(scenario, tmp)
            #expect(PairingSheet.installPageLink(model) == nil, "\(scenario)")
            #expect(NetworkView.installPageAddress(model) == nil, "\(scenario)")
            await model.shutdown()
        }
    }

    /// 시트: 두 번째 QR·링크 글자·사실 문장이 보이고, "링크 복사"는 링크만 클립보드에 넣고 알린다.
    @Test(.timeLimit(.minutes(1)))
    func pairingSheetCopiesTheInstallPageLink() async throws {
        let tmp = try UITempDir("installsheet")
        let model = await pairingModel(.sharing, tmp)
        let log = CopyLog()
        let window = host(PairingSheet().environment(model).environment(AuthKeyDraft()).environment(\.linkCopier, log.copier))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { !AXTree.buttons(BrowserInstallPanel.copyTitle, in: view).isEmpty })
        let texts = AXTree.texts(in: view)
        #expect(texts.contains(Self.pageLink))
        #expect(texts.contains(BrowserInstallPanel.facts))
        #expect(texts.contains(BrowserInstallPanel.heading))
        #expect(texts.contains { $0.contains("RemoteDebug에서 QR을 찍거나") }, "앱 페어링 안내는 그대로")

        AXTree.press(try #require(AXTree.buttons(BrowserInstallPanel.copyTitle, in: view).first))
        try #require(try await until { !log.writes.isEmpty })
        #expect(log.writes == [Self.pageLink])
        #expect(log.announcements == [BrowserInstallPanel.copyAnnouncement])
        #expect(try await until { !AXTree.buttons(CopyLinkButton.copiedTitle, in: view).isEmpty }, "복사됨 표시")

        // 앱 페어링 링크 복사는 예전처럼 앱 링크만 넣는다.
        AXTree.press(try #require(AXTree.buttons("페어링 링크 복사", in: view).first))
        try #require(try await until { log.writes.count == 2 })
        #expect(log.writes.last == "remotedebug://pair?host=\(PreviewFactory.fqdn)&code=K7M29QXD")
        #expect(log.announcements.count == 1)
        await model.shutdown()
    }

    /// 코드가 쓰이면 시트에서 설치 페이지 부분이 사라진다.
    @Test(.timeLimit(.minutes(1)))
    func pairingSheetDropsTheInstallPageWhenTheCodeIsUsed() async throws {
        let tmp = try UITempDir("installused")
        let model = await pairingModel(.sharing, tmp)
        let window = host(PairingSheet().environment(model).environment(AuthKeyDraft()).environment(\.linkCopier, CopyLog().copier))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { !AXTree.buttons(BrowserInstallPanel.copyTitle, in: view).isEmpty })
        model.handle(.pairRequest(PairRequestEvent(requestId: "pr_used", deviceName: "Safari iPhone", nodeName: "rd-phone-web", loginName: "",
                                                   expiresAt: Date().addingTimeInterval(120))))
        #expect(try await until { AXTree.buttons(BrowserInstallPanel.copyTitle, in: view).isEmpty })
        #expect(!AXTree.texts(in: view).contains(Self.pageLink))
        await model.shutdown()
    }

    /// 네트워크 화면: 공유 중이면 주소와 복사 버튼, 아니면 "아직 없음".
    @Test(.timeLimit(.minutes(1)))
    func networkScreenShowsAndCopiesTheInstallPageAddress() async throws {
        let tmp = try UITempDir("installnet")
        let sharing = await pairingModel(.sharing, tmp)
        let log = CopyLog()
        let window = host(RootView(selection: .network).environment(sharing).environment(\.linkCopier, log.copier))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { !AXTree.buttons(NetworkView.copyAddressTitle, in: view).isEmpty })
        #expect(AXTree.texts(in: view).contains(Self.pageAddress))
        #expect(!AXTree.texts(in: view).contains(Self.pageLink), "네트워크 화면에는 코드를 넣지 않는다")
        AXTree.press(try #require(AXTree.buttons(NetworkView.copyAddressTitle, in: view).first))
        try #require(try await until { !log.writes.isEmpty })
        #expect(log.writes == [Self.pageAddress])
        #expect(log.announcements == [NetworkView.copyAddressAnnouncement])
        await sharing.shutdown()

        let certs = await model(.certificatesOff, tmp)
        let offWindow = host(RootView(selection: .network).environment(certs).environment(\.linkCopier, log.copier))
        defer { offWindow.close() }
        let offView = try root(offWindow)
        try #require(await until { AXTree.texts(in: offView).contains("설치 페이지") })
        #expect(AXTree.buttons(NetworkView.copyAddressTitle, in: offView).isEmpty)
        #expect(AXTree.texts(in: offView).contains("아직 없음"))
        await certs.shutdown()
    }

    @Test func installPageQRCodeRenders() {
        #expect(QRCodeView.makeImage(Self.pageLink) != nil)
    }
}
