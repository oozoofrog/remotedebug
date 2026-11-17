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

    /// 시트의 설치 페이지 부분과 네트워크 화면의 줄은 페어링할 수 있을 때만 있다(앱이 없는 iPhone 동선).
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

    /// 시트는 iPhone의 상황을 먼저 고르게 하고, 고르기 전에는 코드도 QR도 열지 않는다.
    @Test(.timeLimit(.minutes(1)))
    func pairingSheetStartsWithTheRouteChoice() async throws {
        let tmp = try UITempDir("routechoice")
        let model = await PreviewFactory.makeModel(.sharing, root: tmp.url.appendingPathComponent("host", isDirectory: true))
        // 미리보기의 허용 대기 요청이 먼저 오면 시트는 그 요청을 보인다. 그 요청을 끝내 둔다.
        try #require(try await until { !model.pendingPairRequests.isEmpty })
        for request in model.pendingPairRequests {
            model.handle(.pairDecided(PairDecidedEvent(requestId: request.requestId, state: .denied)))
        }
        let window = host(PairingSheet().environment(model).environment(AuthKeyDraft()).environment(\.linkCopier, CopyLog().copier))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { !AXTree.buttons(PairingSheet.routeTitle(.browser), in: view).isEmpty })
        #expect(!AXTree.buttons(PairingSheet.routeTitle(.app), in: view).isEmpty)
        #expect(model.pairingCode == nil && model.openInvite == nil)

        // 앱이 없는 iPhone을 고르면 그때 코드를 연다.
        AXTree.press(try #require(AXTree.buttons(PairingSheet.routeTitle(.browser), in: view).first))
        #expect(try await until { model.pairingCode != nil })
        #expect(model.openInvite == nil)
        await model.shutdown()
    }

    /// 이미 열린 코드(에이전트가 연 것 등)가 있으면 시트는 고르기 화면 대신 그 동선으로 열린다.
    @Test(.timeLimit(.minutes(1)))
    func pairingSheetOpensOnTheRouteThatIsAlreadyOpen() async throws {
        let tmp = try UITempDir("routeopen")
        let model = await pairingModel(.sharing, tmp)
        let window = host(PairingSheet().environment(model).environment(AuthKeyDraft()).environment(\.linkCopier, CopyLog().copier))
        defer { window.close() }
        let view = try root(window)
        #expect(try await until { !AXTree.buttons(BrowserPairingPanel.copyTitle, in: view).isEmpty })
        await model.shutdown()
    }

    /// 앱이 없는 iPhone: 할 일 순서, 주소(코드 없음), 코드, "링크 복사"는 코드를 넣은 링크만 클립보드에 넣고 알린다.
    @Test(.timeLimit(.minutes(1)))
    func browserRouteShowsTheStepsAndCopiesTheInstallPageLink() async throws {
        let tmp = try UITempDir("installsheet")
        let model = await pairingModel(.sharing, tmp)
        let log = CopyLog()
        let window = host(PairingSheet(route: .browser).environment(model).environment(AuthKeyDraft()).environment(\.linkCopier, log.copier))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { !AXTree.buttons(BrowserPairingPanel.copyTitle, in: view).isEmpty })
        let texts = AXTree.texts(in: view)
        #expect(BrowserPairingPanel.steps.allSatisfy(texts.contains), "\(texts)")
        #expect(texts.contains(Self.pageAddress) && texts.contains("K7M2-9QXD"))
        #expect(!texts.contains { $0.contains("remotedebug://") }, "앱용 링크는 없다")

        AXTree.press(try #require(AXTree.buttons(BrowserPairingPanel.copyTitle, in: view).first))
        try #require(try await until { !log.writes.isEmpty })
        #expect(log.writes == [Self.pageLink])
        #expect(log.announcements == [BrowserPairingPanel.copyAnnouncement])
        #expect(try await until { !AXTree.buttons(CopyLinkButton.copiedTitle, in: view).isEmpty }, "복사됨 표시")
        await model.shutdown()
    }

    /// 앱이 있는 iPhone: QR과 할 일 순서. 링크 복사는 제안의 링크를 넣는다. 설치 페이지 코드는 보이지 않는다.
    @Test(.timeLimit(.minutes(1)))
    func appRouteShowsTheQRSteps() async throws {
        let tmp = try UITempDir("appsheet")
        let model = await PreviewFactory.makePairingModel(.sharing, route: .app, root: tmp.url.appendingPathComponent("host", isDirectory: true))
        let log = CopyLog()
        let window = host(PairingSheet(route: .app).environment(model).environment(AuthKeyDraft()).environment(\.linkCopier, log.copier))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { !AXTree.buttons(AppPairingPanel.copyTitle, in: view).isEmpty })
        let texts = AXTree.texts(in: view)
        #expect(AppPairingPanel.steps.allSatisfy(texts.contains), "\(texts)")
        #expect(!texts.contains("K7M2-9QXD") && model.pairingCode == nil)
        AXTree.press(try #require(AXTree.buttons(AppPairingPanel.copyTitle, in: view).first))
        try #require(try await until { !log.writes.isEmpty })
        #expect(log.writes.first?.hasPrefix("remotedebug://pair#v=1&") == true)
        await model.shutdown()
    }

    /// 1회용 Tailscale 키를 실은 QR은 링크 복사 없이 QR만 보이고, 앱 안 카메라로 읽으라고 한다. 키가 없으면 링크 복사가 있다.
    @Test(.timeLimit(.minutes(1)))
    func appQRWithATailscaleKeyHasNoCopyButton() async throws {
        let tmp = try UITempDir("appsheetkey")
        let model = await pairingModel(.sharing, tmp)
        let link = URL(string: "remotedebug://pair#v=1&h=rd-mac-test.example.ts.net&p=4747&s=FAKE&e=1")!
        func invite(_ authKey: PairingInvite.AuthKey, link: URL?) -> PairingInvite {
            PairingInvite(link: link, qrImage: QRCodeView.makeImage(link?.absoluteString ?? "qr"), expiresAt: Date().addingTimeInterval(300),
                          authKey: authKey, tailnetLockEnabled: false)
        }

        let keyed = host(AppPairingPanel(invite: invite(.included(expires: Date().addingTimeInterval(300)), link: nil), dismiss: {})
            .environment(model).environment(\.linkCopier, CopyLog().copier))
        defer { keyed.close() }
        let keyedView = try root(keyed)
        try #require(try await until { AXTree.texts(in: keyedView).contains(AppPairingPanel.cameraOnlyNote) })
        #expect(AXTree.buttons(AppPairingPanel.copyTitle, in: keyedView).isEmpty)

        let plain = host(AppPairingPanel(invite: invite(.none, link: link), dismiss: {})
            .environment(model).environment(\.linkCopier, CopyLog().copier))
        defer { plain.close() }
        let plainView = try root(plain)
        #expect(try await until { !AXTree.buttons(AppPairingPanel.copyTitle, in: plainView).isEmpty })
        #expect(!AXTree.texts(in: plainView).contains(AppPairingPanel.cameraOnlyNote))
        await model.shutdown()
    }

    /// 코드가 쓰이면 시트에서 설치 페이지 부분이 사라지고 요청 줄이 나온다. 요청 줄은 어느 동선으로 왔는지 보이고,
    /// 확인 숫자는 앱 QR 요청에만 있다.
    @Test(.timeLimit(.minutes(1)))
    func pairingSheetShowsTheRequestRouteWhenTheCodeIsUsed() async throws {
        let tmp = try UITempDir("installused")
        let model = await pairingModel(.sharing, tmp)
        let window = host(PairingSheet(route: .browser).environment(model).environment(AuthKeyDraft()).environment(\.linkCopier, CopyLog().copier))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { !AXTree.buttons(BrowserPairingPanel.copyTitle, in: view).isEmpty })
        let web = PairRequestEvent(requestId: "pr_used", deviceName: "Safari iPhone", nodeName: "rd-phone-web", loginName: "",
                                   expiresAt: Date().addingTimeInterval(120))
        model.handle(.pairRequest(web))
        #expect(try await until { AXTree.buttons(BrowserPairingPanel.copyTitle, in: view).isEmpty })
        #expect(!AXTree.texts(in: view).contains(Self.pageAddress))
        #expect(try await until { AXTree.texts(in: view).contains(PairRequestRow.routeText(web)) })
        #expect(PairRequestRow.confirmationDigits(web) == nil)

        var qr = web
        qr.confirmationCode = "042917"
        #expect(PairRequestRow.routeText(qr) != PairRequestRow.routeText(web))
        #expect(PairRequestRow.confirmationDigits(qr) == "042 917")
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
