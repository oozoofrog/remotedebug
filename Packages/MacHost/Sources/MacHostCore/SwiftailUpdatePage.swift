import Foundation
import MacHostKit
import SwiftailHostServer

/// iPhone 앱 업데이트 페이지(docs/protocol-addenda.md I)를 이 프로세스의 루프백 서버(`UpdatePageServer.shared`)로 낸다.
/// 호스트 로직의 `/v1/info`가 같은 서버의 `publicURL`을 읽는다.
public struct SwiftailUpdatePage: UpdatePageServing {
    let server: UpdatePageServer

    public init() { server = .shared }

    init(server: UpdatePageServer) { self.server = server }

    public func apply(_ config: UpdatePageConfig) async throws -> String {
        let page = config.page.map {
            UpdatePageServer.Page(bundleID: $0.bundleId, title: $0.title, version: $0.version, buildNumber: $0.buildNumber,
                                  minOS: $0.minOS, size: $0.size, sha256: $0.sha256, publishedAt: $0.publishedAt,
                                  ipaPath: $0.ipaPath, icon: $0.icon.map { Array($0) })
        }
        do {
            return try await server.apply(UpdatePageServer.Configuration(listen: config.listen, publicURL: config.publicURL, page: page))
        } catch {
            throw UpdatePageError(message: Self.message(error))
        }
    }

    /// 화면(`UpdatePageModel.lastError`)에 나오는 문구.
    static func message(_ failure: UpdatePageServer.Failure) -> String {
        switch failure {
        case .invalidPublicURL: String(localized: "publicURL은 /로 끝나는 https 주소여야 합니다")
        case .invalidPage: String(localized: "page에는 ipaPath와 bundleId가 필요합니다")
        case .notLoopback: String(localized: "listen은 루프백 주소여야 합니다")
        case .listenFailed(let address): String(localized: "\(address)에서 기다리지 못했습니다")
        }
    }
}

/// 업데이트 페이지 설정을 적용하지 못했다.
public struct UpdatePageError: LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}
