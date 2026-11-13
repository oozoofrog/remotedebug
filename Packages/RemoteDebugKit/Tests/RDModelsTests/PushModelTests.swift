import Foundation
import Testing
@testable import RDModels

/// docs/protocol-addenda.md P의 선택 필드 `push`. 없으면 키를 쓰지 않고, 모양이 틀리면 없는 것으로 읽는다.
@Suite struct PushModelTests {
    private let oldDevice = #"{"id":"d_9c2e41b7","name":"시험용 iPhone","nodeStableId":"nSTABLE1","nodeName":"rd-phone-1","loginName":"user@example.com","pairedAt":"2026-11-11T09:05:00Z"}"#
    private static let token = String(repeating: "0123abcd", count: 8)
    private let push = #"{"token":"\#(token)","bundleId":"com.oozoofrog.app.RemoteDebugPhone","environment":"development"}"#

    private func withPush(_ value: String) -> String {
        String(oldDevice.dropLast()) + #","push":\#(value)}"#
    }

    private func keys(_ device: DeviceEntry) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: RDJSON.encoder().encode(device)) as? [String: Any]
        return (object?.keys.sorted()) ?? []
    }

    @Test func oldShapeRoundTripsWithTheSameKeys() throws {
        let old = try RDJSON.decoder().decode(DeviceEntry.self, from: Data(oldDevice.utf8))
        #expect(old.push == nil)
        #expect(!old.isPushRegistered)
        #expect(try keys(old) == ["id", "loginName", "name", "nodeName", "nodeStableId", "pairedAt"])
    }

    @Test func registeredShapeRoundTrips() throws {
        let device = try RDJSON.decoder().decode(DeviceEntry.self, from: Data(withPush(push).utf8))
        #expect(device.push == PushRegistration(token: Self.token, bundleId: "com.oozoofrog.app.RemoteDebugPhone", environment: "development"))
        #expect(device.isPushRegistered)
        #expect(try keys(device).contains("push"))
        let back = try RDJSON.decoder().decode(DeviceEntry.self, from: RDJSON.encoder().encode(device))
        #expect(back == device)
        let original = try JSONSerialization.jsonObject(with: Data(withPush(push).utf8)) as? NSDictionary
        let encoded = try JSONSerialization.jsonObject(with: RDJSON.encoder().encode(device)) as? NSDictionary
        #expect(original == encoded)
    }

    @Test(arguments: [#""yes""#, #"{"token":1}"#, #"{"bundleId":"x"}"#, "[]", "null"])
    func malformedPushIsReadAsNone(value: String) throws {
        let device = try RDJSON.decoder().decode(DeviceEntry.self, from: Data(withPush(value).utf8))
        #expect(device.id == "d_9c2e41b7")
        #expect(device.push == nil)
        #expect(try keys(device).contains("push") == false)
    }

    @Test func initKeepsOldCallersAndOmitsMissingPush() throws {
        let d = DeviceEntry(id: "d_1", name: "n", nodeStableId: "s", nodeName: "rd-phone-1", loginName: "", pairedAt: Date(timeIntervalSince1970: 0))
        #expect(d.push == nil)
        #expect(try !keys(d).contains("push"))
    }

    @Test func deviceUpdatedEventCarriesPush() throws {
        let json = #"{"type":"device-updated","device":\#(withPush(push))}"#
        let event = try RDJSON.decoder().decode(CoreEvent.self, from: Data(json.utf8))
        guard case .deviceUpdated(let d) = event else {
            Issue.record("device-updated를 읽지 못함: \(event)")
            return
        }
        #expect(d.push?.token == Self.token)
        #expect(d.push?.environment == "development")
    }
}
