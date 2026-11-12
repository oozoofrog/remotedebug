import Foundation
import MacHostKit
import RDCoreBridge

/// `rd_update_page_set`을 부른다(docs/protocol-addenda.md I).
public struct RDCoreUpdatePage: UpdatePageServing {
    public init() {}

    public func apply(_ config: UpdatePageConfig) async throws -> String {
        let body = try JSONEncoder().encode(config)
        let data = try await Task.detached { try RDUpdatePage.set(body) }.value
        struct Reply: Decodable { var addr: String }
        return try JSONDecoder().decode(Reply.self, from: data).addr
    }
}
