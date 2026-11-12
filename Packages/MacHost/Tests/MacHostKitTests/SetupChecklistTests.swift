import RDModels
import Testing
@testable import MacHostKit

@Suite struct SetupChecklistTests {
    private func guidance(_ status: CoreStatus?) -> StatusGuidance { StatusGuidance.make(for: status) }

    @Test func firstUndoneStepIsCurrent() {
        let stopped = SetupChecklist.make(guidance: guidance(nil), fqdn: nil, devices: 0, builds: 0)
        #expect(stopped.items.map(\.state) == [.current, .later, .later, .later])
        #expect(stopped.current?.step == .tailnet)
        #expect(!stopped.isComplete)

        let noCerts = guidance(CoreStatus(backendState: .running, fqdn: "rd-mac-1.t.ts.net", certDomains: []))
        let addressBlocked = SetupChecklist.make(guidance: noCerts, fqdn: "rd-mac-1.t.ts.net", devices: 0, builds: 0)
        #expect(addressBlocked.items.map(\.state) == [.done, .current, .later, .later])
        #expect(addressBlocked.current?.detail.contains("HTTPS") == true)

        let ready = guidance(CoreStatus(backendState: .running, fqdn: "rd-mac-1.t.ts.net", certDomains: ["rd-mac-1.t.ts.net"], tlsReady: true, listening: true))
        let needPhone = SetupChecklist.make(guidance: ready, fqdn: "rd-mac-1.t.ts.net", devices: 0, builds: 2)
        #expect(needPhone.items.map(\.state) == [.done, .done, .current, .done])
        #expect(needPhone.doneCount == 3)

        let all = SetupChecklist.make(guidance: ready, fqdn: "rd-mac-1.t.ts.net", devices: 1, builds: 1)
        #expect(all.isComplete && all.current == nil)
        #expect(all.items[2].detail == "iPhone 1대 허용됨")
    }
}
