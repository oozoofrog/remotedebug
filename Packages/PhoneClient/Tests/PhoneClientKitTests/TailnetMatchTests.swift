import Testing

@testable import PhoneClientKit

@Suite struct TailnetMatchTests {
    @Test func comparesTailnetPartOfMagicDNSNames() {
        #expect(TailnetMatch.tailnet(of: "rd-mac-1a2b3c4d.tail0001.ts.net.") == "tail0001.ts.net")
        #expect(TailnetMatch.isDifferent(phone: "rd-phone-1.tail0002.ts.net", host: "rd-mac-1.tail0001.ts.net"))
        #expect(!TailnetMatch.isDifferent(phone: "rd-phone-1.TAIL0001.ts.net", host: "rd-mac-1.tail0001.ts.net."))
        // 모르면 판단하지 않는다.
        #expect(!TailnetMatch.isDifferent(phone: nil, host: "rd-mac-1.tail0001.ts.net"))
        #expect(!TailnetMatch.isDifferent(phone: "", host: "rd-mac-1.tail0001.ts.net"))
        #expect(!TailnetMatch.isDifferent(phone: "localhost", host: "rd-mac-1.tail0001.ts.net"))
    }
}
