import Foundation
import Testing
@testable import RDModels

/// docs/protocol-addenda.md O의 선택 필드. 모두 없어도 읽히고, 값이 없으면 키도 쓰지 않는다.
@Suite struct DirectModelTests {
    private let oldDevice = #"{"id":"d_1","name":"n","nodeStableId":"s","nodeName":"rd-phone-1","loginName":"u@example.com","pairedAt":"2026-11-11T09:05:00Z"}"#

    @Test func deviceEntryReadsOldAndNewShapes() throws {
        let old = try RDJSON.decoder().decode(DeviceEntry.self, from: Data(oldDevice.utf8))
        #expect(old.directTokenHash == nil)
        #expect(!old.isDirectEnrolled)
        // 등록하지 않은 기기는 예전과 같은 키만 쓴다(예전 Mac 앱이 읽던 파일과 같다).
        let encoded = try JSONSerialization.jsonObject(with: RDJSON.encoder().encode(old)) as? [String: Any]
        #expect(encoded?.keys.sorted() == ["id", "loginName", "name", "nodeName", "nodeStableId", "pairedAt"])

        let hash = String(repeating: "ab", count: 32)
        let new = try RDJSON.decoder().decode(DeviceEntry.self, from: Data(oldDevice.replacingOccurrences(of: #""id":"d_1""#, with: #""id":"d_1","directTokenHash":"\#(hash)""#).utf8))
        #expect(new.directTokenHash == hash)
        #expect(new.isDirectEnrolled)
        let back = try RDJSON.decoder().decode(DeviceEntry.self, from: RDJSON.encoder().encode(new))
        #expect(back == new)
    }

    @Test func deviceUpdatedEventCarriesTheEntry() throws {
        let json = #"{"type":"device-updated","device":\#(oldDevice)}"#
        let event = try RDJSON.decoder().decode(CoreEvent.self, from: Data(json.utf8))
        guard case .deviceUpdated(let d) = event else {
            Issue.record("device-updated를 읽지 못함: \(event)")
            return
        }
        #expect(d.id == "d_1")
        #expect(event.type == "device-updated")
    }

    @Test func statusDirectIsOptional() throws {
        let plain = try RDJSON.decoder().decode(CoreStatus.self, from: Data(#"{"backendState":"Running"}"#.utf8))
        #expect(plain.direct == nil)
        let json = #"{"backendState":"Starting","direct":{"listening":true,"port":49152,"id":"0123456789abcdef"}}"#
        let status = try RDJSON.decoder().decode(CoreStatus.self, from: Data(json.utf8))
        #expect(status.direct == DirectStatus(listening: true, port: 49152, id: "0123456789abcdef"))
        // 모양이 달라도 상태 전체를 버리지 않는다.
        let odd = try RDJSON.decoder().decode(CoreStatus.self, from: Data(#"{"backendState":"Running","direct":"yes"}"#.utf8))
        #expect(odd.direct == nil)
    }

    @Test func configWritesDirectListenOnlyWhenOn() throws {
        func keys(_ c: CoreConfig) throws -> Set<String> {
            Set((try JSONSerialization.jsonObject(with: RDJSON.encoder().encode(c)) as? [String: Any] ?? [:]).keys)
        }
        let off = CoreConfig(mode: .host, stateDir: "/s", hostname: "rd-mac-1")
        #expect(try !keys(off).contains("directListen"))
        let on = CoreConfig(mode: .host, stateDir: "/s", hostname: "rd-mac-1", directListen: true)
        #expect(try keys(on).contains("directListen"))
        #expect(try RDJSON.decoder().decode(CoreConfig.self, from: RDJSON.encoder().encode(on)) == on)
        #expect(try RDJSON.decoder().decode(CoreConfig.self, from: RDJSON.encoder().encode(off)) == off)
    }

    @Test func enrollmentResponseDecodes() throws {
        let json = #"{"directId":"0123456789abcdef","port":49152,"tlsSPKI":"47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=","deviceId":"d_1a2b3c4d","token":"Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE"}"#
        let e = try RDJSON.decoder().decode(DirectEnrollment.self, from: Data(json.utf8))
        #expect(e.port == 49152)
        #expect(e.deviceId == "d_1a2b3c4d")
    }
}
