import Foundation
import Observation
import RDBuildInspection

/// 보안 범위 접근의 시작·종료(테스트가 바꿔 끼운다).
public protocol SecurityScoping: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public struct SystemSecurityScoping: SecurityScoping {
    public init() {}
    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// 사용자가 고르거나 끌어 놓은 빌드의 가져오기 줄.
///
/// 구성을 폴더 이름이나 debug.dylib로 확인할 수 없는 빌드(`.needsConfirmation`)는 사용자에게 하나씩 묻는다.
/// 묻는 동안 그 파일의 보안 범위 접근을 붙잡아 둔다. 답(`confirm`/`skip`)은 항목 id로 받고, 그 항목만 처리한다.
/// 답은 물어본 내용(`identity`)에만 유효하다. 그사이 경로의 내용이 바뀌면 가져오기가 거절한다.
/// 같은 id에 대한 두 번째 답이나 이미 끝난 항목에 대한 답은 아무것도 하지 않는다.
@MainActor
@Observable
public final class ImportQueue {
    public struct Pending: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let url: URL
        /// 물어본 빌드의 내용.
        public let identity: BuildIdentity
        let accessing: Bool
    }

    /// `(경로, 가져오기 방식)` → 가져오기 결과.
    public typealias Importer = @MainActor (URL, ImportMode) async -> ImportOutcome?

    /// 사용자 확인을 기다리는 빌드(앞에서부터 하나씩 묻는다).
    public private(set) var pending: [Pending] = []

    @ObservationIgnored private let scoping: any SecurityScoping

    public init(scoping: any SecurityScoping = SystemSecurityScoping()) {
        self.scoping = scoping
    }

    /// 지금 물을 빌드.
    public var current: Pending? { pending.first }

    public func contains(_ id: UUID) -> Bool { pending.contains { $0.id == id } }

    public func importURLs(_ urls: [URL], using importer: Importer) async {
        for url in urls {
            let accessing = scoping.startAccessing(url)
            let outcome = await importer(url, .askIfUnverified)
            if case .needsConfirmation(let identity) = outcome {
                pending.append(Pending(id: UUID(), url: url, identity: identity, accessing: accessing))
            } else if accessing {
                scoping.stopAccessing(url)
            }
        }
    }

    /// 사용자가 이 빌드(`id`)가 Debug 빌드라고 확인했다. 항목은 부르는 즉시(동기적으로) 줄에서 빠지고,
    /// 가져오기는 돌려준 작업에서 한다. 줄에 없는 id면 nil.
    @discardableResult
    public func confirm(_ id: UUID, using importer: @escaping Importer) -> Task<Void, Never>? {
        guard let item = take(id) else { return nil }
        let scoping = self.scoping
        return Task { @MainActor in
            _ = await importer(item.url, .confirmed(item.identity))
            if item.accessing { scoping.stopAccessing(item.url) }
        }
    }

    /// 사용자가 이 빌드(`id`)를 가져오지 않기로 했다.
    public func skip(_ id: UUID) {
        guard let item = take(id) else { return }
        if item.accessing { scoping.stopAccessing(item.url) }
    }

    private func take(_ id: UUID) -> Pending? {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return nil }
        return pending.remove(at: i)
    }
}
