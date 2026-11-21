import Foundation
import RDModels

extension HostLogic {
    /// 예전 Go 코어의 `rd_host_publish`와 같은 JSON 입력. 공유 모델로 상태를 보관하되 원문의 문자열 메타데이터도 보존한다.
    @discardableResult
    public func publish(json data: Data) throws -> String {
        let input: HostJSON
        do { input = try HostJSON(data: data, singleValue: true) }
        catch { throw HostErrors.make("bad_request", "빌드 JSON을 읽지 못했습니다.") }
        let signing = try HostJSON(value: input.value("signing") ?? NSNull())
        let ipa = try HostJSON(value: input.value("ipa") ?? NSNull())
        let keys = ["id", "bundleId", "displayName", "version", "buildNumber", "minOS", "configuration", "configurationEvidence", "publishedAt"]
        var wire: [String: Any] = [:]
        for key in keys { wire[key] = try input.string(key) }
        let debug = try input.bool("debug"), taskAllow = try signing.bool("getTaskAllow")
        let count = try signing.integer("provisionedDeviceCount"), size = try ipa.integer("size")
        let profileExpires = try signing.string("profileExpires")
        let signingWire: [String: Any] = try ["teamId": signing.string("teamId"), "profileName": signing.string("profileName"),
            "profileExpires": profileExpires, "provisionedDeviceCount": count, "getTaskAllow": taskAllow]
        let icon: Data?
        if let value = input.value("icon"), !(value is NSNull) {
            if let base64 = value as? String {
                guard let bytes = Data(base64Encoded: base64.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")) else {
                    throw HostErrors.make("bad_request", "빌드 JSON을 읽지 못했습니다.")
                }
                icon = bytes
            } else if let array = value as? [Any] {
                let bytes = try array.map { value -> UInt8 in
                    let field = try HostJSON(value: ["byte": value])
                    let number = try field.integer("byte")
                    guard (0...255).contains(number) else { throw HostErrors.make("bad_request", "빌드 JSON을 읽지 못했습니다.") }
                    return UInt8(number)
                }
                icon = Data(bytes)
            } else { throw HostErrors.make("bad_request", "빌드 JSON을 읽지 못했습니다.") }
        } else { icon = nil }
        let now = options.now()
        var publishedAt = try input.string("publishedAt")
        if publishedAt.isEmpty { publishedAt = hostTimestamp(now) }
        let build = try BuildDescriptor(id: input.string("id"), bundleId: input.string("bundleId"), displayName: input.string("displayName"),
            version: input.string("version"), buildNumber: input.string("buildNumber"), minOS: input.string("minOS"), debug: debug,
            configuration: input.string("configuration"), configurationEvidence: .init(rawValue: input.string("configurationEvidence")) ?? .path,
            signing: .init(teamId: signing.string("teamId"), profileName: signing.string("profileName"),
                           profileExpires: RDTimestamp.parse(profileExpires) ?? Date(timeIntervalSince1970: 0),
                           provisionedDeviceCount: Int(count), getTaskAllow: taskAllow),
            ipa: .init(size: size, sha256: ipa.string("sha256")), publishedAt: RDTimestamp.parse(publishedAt) ?? now, icon: icon)
        let path = try input.string("ipaPath")
        let id = HostIDs.buildID(bundleID: build.bundleId, sha256: build.ipa.sha256.lowercased())
        wire["id"] = id
        wire["debug"] = debug
        wire["signing"] = signingWire
        wire["ipa"] = ["size": size, "sha256": build.ipa.sha256.lowercased()] as [String: Any]
        wire["publishedAt"] = publishedAt
        if let icon, !icon.isEmpty { wire["icon"] = icon.base64EncodedString() }
        let encoded = try JSONSerialization.data(withJSONObject: wire)
        return try publishBuild(.init(build: build, ipaPath: path), wire: encoded, timestamp: publishedAt)
    }

    /// 예전 Go 코어의 `rd_host_publish_resource`와 같은 JSON 입력. 빠진 시각과 잘못된 시각은 현재 시각으로 채운다.
    @discardableResult
    public func publishResource(json data: Data) throws -> String {
        let input: HostJSON
        do { input = try HostJSON(data: data, singleValue: true) }
        catch { throw HostErrors.make("bad_request", "파일 JSON을 읽지 못했습니다.") }
        var project: ResourceProject?
        if let value = input.value("project"), !(value is NSNull) {
            let object = try HostJSON(value: value)
            project = try ResourceProject(id: object.string("id"), name: object.string("name"))
        }
        let link = try input.string("link")
        let size = try input.integer("size")
        var publishedAt = try input.string("publishedAt")
        if RDTimestamp.parse(publishedAt) == nil { publishedAt = hostTimestamp(options.now()) }
        let resource = try ResourceDescriptor(id: input.string("id"), name: input.string("name"), size: size,
            sha256: input.string("sha256"), publishedAt: RDTimestamp.parse(publishedAt) ?? options.now(),
            link: link.isEmpty ? nil : link, project: project)
        return try publishResourceRequest(.init(resource: resource, path: input.string("path")), timestamp: publishedAt)
    }

    /// 예전 Go 코어의 `rd_host_set_devices`와 같은 JSON 입력. devices 배열이 반드시 있어야 한다.
    public func setDevices(json data: Data) throws {
        let input: HostJSON
        do { input = try HostJSON(data: data, singleValue: true) }
        catch { throw HostErrors.make("bad_request", #"{"devices":[…]} 형식의 기기 목록 JSON이 필요합니다."#) }
        guard let array = input.value("devices") as? [Any] else {
            throw HostErrors.make("bad_request", #"{"devices":[…]} 형식의 기기 목록 JSON이 필요합니다."#)
        }
        var wireDates: [String: String] = [:]
        let entries = try array.map { value -> DeviceEntry in
            let object = try HostJSON(value: value)
            var push: PushRegistration?
            if let value = object.value("push"), !(value is NSNull) {
                let registration = try HostJSON(value: value)
                push = try PushRegistration(token: registration.string("token"), bundleId: registration.string("bundleId"), environment: registration.string("environment"))
            }
            let hash = try object.string("directTokenHash"), cable = try object.string("cableUDID")
            var linked: [LinkedNode] = []
            if let value = object.value("linkedNodes"), !(value is NSNull) {
                guard let list = value as? [Any] else { throw HostErrors.make("bad_request", "linkedNodes는 배열이어야 합니다.") }
                linked = try list.map { item in
                    let node = try HostJSON(value: item)
                    return try LinkedNode(nodeStableId: node.string("nodeStableId"), nodeName: node.string("nodeName"), loginName: node.string("loginName"),
                                          linkedAt: RDTimestamp.parse(node.string("linkedAt")) ?? Date(timeIntervalSince1970: 0))
                }.filter { !$0.nodeStableId.isEmpty }
            }
            wireDates[try object.string("nodeStableId")] = try object.string("pairedAt")
            return try DeviceEntry(id: object.string("id"), name: object.string("name"), nodeStableId: object.string("nodeStableId"),
                nodeName: object.string("nodeName"), loginName: object.string("loginName"),
                pairedAt: RDTimestamp.parse(object.string("pairedAt")) ?? Date(timeIntervalSince1970: 0), directTokenHash: hash.isEmpty ? nil : hash, push: push,
                cableUDID: cable.isEmpty ? nil : cable, linkedNodes: linked)
        }
        try locked {
            try setDevices(entries)
            deviceWireDates = wireDates
        }
    }
}
