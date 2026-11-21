import Foundation
import RDModels

extension HostLogic {
    /// 공유 CoreEvent 모델에 없는 필드를 같은 사건의 JSON에 더한다.
    /// 사건 저장·전달에는 Options.eventDetails를 쓴다. Options.events는 기존 CoreEvent 소비자를 위한 접점이다.
    public struct EmittedEvent: Codable, Sendable, Hashable {
        public let event: CoreEvent
        public let receivedAt: Date?
        public let nodeName: String?
        public let deviceID: String?
        public let devicePairedAt: String?
        public init(event: CoreEvent, receivedAt: Date? = nil, nodeName: String? = nil, deviceID: String? = nil, devicePairedAt: String? = nil) {
            self.event = event
            self.receivedAt = receivedAt
            self.nodeName = nodeName
            self.deviceID = deviceID
            self.devicePairedAt = devicePairedAt
        }
        enum CodingKeys: String, CodingKey { case type, device, receivedAt, nodeName; case deviceID = "deviceId" }
        enum DeviceKeys: String, CodingKey { case id, name, nodeStableId, nodeName, loginName, pairedAt, directTokenHash, push, cableUDID, linkedNodes }
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            if type == "device-added" || type == "device-updated" {
                let object = try container.nestedContainer(keyedBy: DeviceKeys.self, forKey: .device)
                let rawDate = try object.decode(String.self, forKey: .pairedAt)
                let date = RDTimestamp.parse(rawDate) ?? Date(timeIntervalSince1970: 0)
                let device = try DeviceEntry(id: object.decode(String.self, forKey: .id), name: object.decode(String.self, forKey: .name),
                    nodeStableId: object.decode(String.self, forKey: .nodeStableId), nodeName: object.decode(String.self, forKey: .nodeName),
                    loginName: object.decode(String.self, forKey: .loginName), pairedAt: date,
                    directTokenHash: object.decodeIfPresent(String.self, forKey: .directTokenHash), push: object.decodeIfPresent(PushRegistration.self, forKey: .push),
                    cableUDID: object.decodeIfPresent(String.self, forKey: .cableUDID),
                    linkedNodes: object.decodeIfPresent([LinkedNode].self, forKey: .linkedNodes) ?? [])
                event = type == "device-added" ? .deviceAdded(device) : .deviceUpdated(device)
                devicePairedAt = rawDate == hostTimestamp(date) ? nil : rawDate
            } else {
                event = try CoreEvent(from: decoder)
                devicePairedAt = nil
            }
            receivedAt = try container.decodeIfPresent(String.self, forKey: .receivedAt).flatMap(RDTimestamp.parse)
            if case .agentRequest = event { nodeName = try container.decodeIfPresent(String.self, forKey: .nodeName) } else { nodeName = nil }
            if case .agentCancel = event { deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) } else { deviceID = nil }
        }
        public func encode(to encoder: any Encoder) throws {
            try event.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let receivedAt {
                try container.encode(receivedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), forKey: .receivedAt)
            }
            try container.encodeIfPresent(nodeName, forKey: .nodeName)
            try container.encodeIfPresent(deviceID, forKey: .deviceID)
            if let devicePairedAt {
                switch event {
                case .deviceAdded(let device), .deviceUpdated(let device):
                    try container.encode(DeviceWithTimestamp(device: device, timestamp: devicePairedAt), forKey: .device)
                default: break
                }
            }
        }
        private struct DeviceWithTimestamp: Encodable {
            let device: DeviceEntry
            let timestamp: String
            func encode(to encoder: any Encoder) throws {
                try device.encode(to: encoder)
                var container = encoder.container(keyedBy: DeviceKeys.self)
                try container.encode(timestamp, forKey: .pairedAt)
            }
        }
    }
}
