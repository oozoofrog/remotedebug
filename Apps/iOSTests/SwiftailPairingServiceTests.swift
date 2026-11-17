import Foundation
import PhoneClientKit
import SwiftailPairing
import Testing
@testable import RemoteDebug

/// `SwiftailPairing`을 `PairingService`로 잇는 어댑터. 실제 링크 읽기와 오류 옮기기를 본다.
/// 짝 맺기 자체(`PairingJoiner`)는 실제 tailnet이 필요해 여기서 돌리지 않는다.
@Suite("SwiftailPairingService") struct SwiftailPairingServiceTests {
    private let host = "rd-mac-ab12cd34.example-tailnet.ts.net"
    private let authKey = "tskey-auth-kTest1CNTRL-abc123"

    /// 32바이트 비밀(0, 1, 2 …)의 채움 없는 base64url 43자.
    private var secret: String {
        Data((0..<32).map { UInt8($0) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func link(key: String? = nil, port: Int = 7443, expires: Int = 1_794_390_000) -> String {
        var text = "remotedebug://pair#v=1&h=\(host)&p=\(port)&s=\(secret)&e=\(expires)"
        if let key { text += "&k=\(key)" }
        return text
    }

    @Test func 새_링크를_읽는다() throws {
        let proposal = try SwiftailPairingService().read(link: link(key: authKey))
        #expect(proposal.host == host)
        #expect(proposal.expires == Date(timeIntervalSince1970: 1_794_390_000))
        #expect(proposal.authKey == authKey)
        #expect(proposal.payload is PairingOffer)
        let withoutKey = try SwiftailPairingService().read(link: link())
        #expect(withoutKey.authKey == nil)
    }

    @Test func 앱의_입구를_거쳐도_읽는다() throws {
        let proposal = try PairingInput.read(link(key: authKey), with: SwiftailPairingService(), policy: .tailnetOnly)
        #expect(proposal.host == host)
        // 같은 글자는 같은 제안이고 다른 글자는 다른 제안이다(비밀을 견주지 않고 지문으로).
        let again = try PairingInput.read(link(key: authKey), with: SwiftailPairingService(), policy: .tailnetOnly)
        let other = try PairingInput.read(link(key: authKey, port: 7444), with: SwiftailPairingService(), policy: .tailnetOnly)
        #expect(proposal == again)
        #expect(proposal != other)
    }

    @Test func 예전_링크와_잘못된_링크의_안내() {
        let service = SwiftailPairingService()
        #expect(throws: PairingOfferIssue.legacyLink) {
            try PairingInput.read("remotedebug://pair?host=\(host)&code=K7M29QXD", with: service, policy: .tailnetOnly)
        }
        #expect(throws: PairingOfferIssue.notAnOffer) {
            try PairingInput.read("https://example.com/pair#v=1", with: service, policy: .tailnetOnly)
        }
        // 라이브러리가 거절한 것: 모르는 판, 짧은 비밀, 감싼 키.
        #expect(throws: PairingOfferIssue.notAnOffer) {
            try PairingInput.read(link().replacingOccurrences(of: "v=1", with: "v=2"), with: service, policy: .tailnetOnly)
        }
        #expect(throws: PairingOfferIssue.invalidSecret) {
            try PairingInput.read(link().replacingOccurrences(of: secret, with: "AAAA"), with: service, policy: .tailnetOnly)
        }
        #expect(throws: PairingOfferIssue.wrappedAuthKey) {
            try PairingInput.read(link(key: "tskey-auth-kTest1CNTRL-abc--TLtail"), with: service, policy: .tailnetOnly)
        }
        #expect(throws: PairingOfferIssue.invalidAuthKey) {
            try PairingInput.read(link(key: "tskey-api-nope"), with: service, policy: .tailnetOnly)
        }
        // .ts.net 밖의 주소는 앱의 정책이 거른다.
        #expect(throws: PairingOfferIssue.hostNotAllowed) {
            try PairingInput.read(link().replacingOccurrences(of: host, with: "mac.example.com"), with: service, policy: .tailnetOnly)
        }
    }

    @Test func 제안은_비밀과_인증_키를_드러내지_않는다() throws {
        let proposal = try SwiftailPairingService().read(link: link(key: authKey))
        var dumped = ""
        dump(proposal, to: &dumped)
        for text in [String(describing: proposal), String(reflecting: proposal), dumped] {
            #expect(!text.contains(authKey))
            #expect(!text.contains("tskey"))
            #expect(!text.contains(secret))
        }
        if let offer = proposal.payload as? PairingOffer {
            var offerDump = ""
            dump(offer, to: &offerDump)
            #expect(!offerDump.contains(secret) && !offerDump.contains(authKey))
            #expect(!String(describing: offer).contains(secret))
        }
    }

    @Test func 제안_오류를_앱_쪽_이유로_옮긴다() {
        let pairs: [(PairingOfferError, PairingOfferIssue)] = [
            (.notAnOffer, .notAnOffer), (.invalidHost, .invalidHost), (.invalidPort, .invalidPort),
            (.invalidSecret, .invalidSecret), (.invalidExpiry, .invalidExpiry),
            (.invalidAuthKey, .invalidAuthKey), (.wrappedAuthKey, .wrappedAuthKey),
        ]
        for (error, issue) in pairs { #expect(SwiftailPairingService.issue(for: error) == issue) }
    }

    @Test func 짝_맺기_오류를_앱_쪽_이유로_옮긴다() {
        let pairs: [(PairingError, PairingFailure)] = [
            (.unreachable, .unreachable), (.notOnTailnet, .notOnTailnet), (.rejected, .rejected), (.denied, .denied),
            (.timedOut, .timedOut), (.hostNotVerified, .hostNotVerified), (.protocolViolation, .protocolViolation),
            (.cancelled, .cancelled),
            // 들어오는 쪽에서 나오지 않는 것
            (.invalidConfiguration("x"), .unexpected), (.invalidAuthKey, .unexpected), (.notRunning, .unexpected),
            (.storeUnreadable, .unexpected), (.storeInUse, .unexpected), (.storeWriteFailed, .unexpected),
        ]
        for (error, failure) in pairs { #expect(SwiftailPairingService.failure(for: error) == failure) }
        // 사용자가 그만둔 것만 문구가 없다.
        #expect(PairingFailure.cancelled.userMessage == nil)
        #expect(PairingFailure.rejected.userMessage?.isEmpty == false)
    }

    @Test func 다른_제안으로_짝을_맺지_않는다() async {
        let foreign = PairingProposal(link: "x", host: host, expires: .now, authKey: nil, payload: "not an offer")
        await #expect(throws: PairingFailure.unexpected) {
            try await SwiftailPairingService().join(foreign, deviceName: "iPhone") { _ in }
        }
    }
}
