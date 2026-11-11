import Foundation
import RDBuildInspection
import RDModels

/// 게시 폴더에 IPA가 있는 수락된 빌드.
public struct LibraryBuild: Codable, Sendable, Hashable, Identifiable {
    public var descriptor: BuildDescriptor
    /// 가져온 원본(.app 또는 .ipa) 경로.
    public var sourcePath: String

    public var id: String { descriptor.id }

    public init(descriptor: BuildDescriptor, sourcePath: String) {
        self.descriptor = descriptor
        self.sourcePath = sourcePath
    }
}

/// 디버그 한정 정책에 걸린 빌드.
public struct RejectedBuild: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sourcePath: String
    public var bundleId: String?
    public var reasons: [Rejection]
    public var rejectedAt: Date

    public init(id: UUID = UUID(), sourcePath: String, bundleId: String?, reasons: [Rejection], rejectedAt: Date) {
        self.id = id
        self.sourcePath = sourcePath
        self.bundleId = bundleId
        self.reasons = reasons
        self.rejectedAt = rejectedAt
    }

    public var codes: [RejectionCode] { reasons.map(\.code) }

    /// 사유별 한국어 문장(같은 문장은 한 번만).
    public var messages: [String] {
        var seen = Set<String>()
        return reasons.map(RejectionText.sentence(for:)).filter { seen.insert($0).inserted }
    }

    public var fileName: String { URL(fileURLWithPath: sourcePath).lastPathComponent }
}

/// 사용자에게 Debug 구성인지 물어본 빌드의 내용. 확인한 뒤 같은 경로의 내용이 바뀌면 가져오지 않는다.
public struct BuildIdentity: Sendable, Hashable {
    enum Content: Sendable, Hashable {
        case app(BundleSnapshot)
        case ipa(FileDigest)
    }

    let content: Content
    public let bundleId: String
    public let version: String
    public let buildNumber: String
}

public enum ImportMode: Sendable, Hashable {
    /// 구성을 확인할 수 없으면 거부 목록에 남긴다(감시 폴더).
    case automatic
    /// 구성을 확인할 수 없으면 거부 목록에 남기지 않고 `.needsConfirmation`으로 돌려준다.
    case askIfUnverified
    /// 사용자가 이 내용을 Debug 빌드라고 확인했다. 지금 내용이 다르면 `changedSinceConfirmation`을 던진다.
    case confirmed(BuildIdentity)
}

public enum ImportOutcome: Sendable, Hashable {
    /// 수락돼 게시 폴더에 들어갔다. 공유 중이면 게시까지 끝났다.
    case accepted(LibraryBuild)
    case rejected(RejectedBuild)
    /// 구성만 확인하지 못했다. 사용자의 답을 기다린다.
    case needsConfirmation(BuildIdentity)
}

public struct RestoreReport: Sendable, Hashable {
    public struct Failure: Sendable, Hashable {
        public var buildID: String
        public var message: String
    }

    public var restored: [String] = []
    /// IPA가 없거나 크기·해시가 달라 목록에서 뺀 빌드.
    public var removed: [String] = []
    /// 프로필이 만료돼 다시 게시하지 않고 거부 목록으로 옮긴 빌드.
    public var expired: [String] = []
    /// 확인·게시에 실패했지만 목록에 남겨 둔 빌드(다음 시작 때 다시 시도한다).
    public var failed: [Failure] = []
    /// 취소나 공유 중지로 중간에 멈췄다. 목록·파일·인덱스는 하나도 바꾸지 않았다.
    public var interrupted = false
    /// 저장된 목록을 읽지 못해 시작하지 않았다(`interrupted`도 true). 폴더와 인덱스는 건드리지 않았다.
    public var notLoaded = false

    public init() {}
}

public enum BuildLibraryError: Error, LocalizedError, Equatable {
    case unsupportedFile(String)
    case changedDuringImport(String)
    /// 사용자에게 물어본 뒤 같은 경로의 내용이 바뀌었다.
    case changedSinceConfirmation(String)
    case publishFailed(String)
    case unknownBuild(String)
    /// 저장된 목록을 읽지 못한 채로는 목록을 덮어쓸 수 없다.
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name): "\(name): .app 폴더나 .ipa 파일만 가져올 수 있습니다."
        case .changedDuringImport(let name): "\(name): 가져오는 동안 파일이 바뀌었습니다. 빌드가 끝난 뒤 다시 가져오세요."
        case .changedSinceConfirmation(let name): "\(name): 확인한 뒤 내용이 바뀌어 가져오지 않았습니다. 다시 가져와 새 내용을 확인하세요."
        case .publishFailed(let message): "게시하지 못했습니다: \(message)"
        case .unknownBuild(let id): "\(id): 목록에 없는 빌드입니다."
        case .notLoaded: "저장된 빌드 목록을 읽지 못해 가져오지 않았습니다. 목록 파일을 복구한 뒤 다시 가져오세요."
        }
    }
}

/// 가져오기 → IPA 만들기(작업 폴더) → 그 IPA 검사 → 게시 → 인덱스 저장.
///
/// 게시하는 IPA는 언제나 검사한 바로 그 파일이다. 원본 경로는 작업 폴더로 옮긴 뒤 다시 읽지 않는다.
/// 가져오기·게시 취소·재게시는 한 번에 하나씩 순서대로 처리한다(검사가 겹치지 않는다).
public actor BuildLibrary {
    public let paths: HostPaths
    public let keepPerBundle: Int
    public let maxRejected: Int

    private let host: any HostCore
    private let inspector: any BuildInspecting
    private let packager: any BuildPackaging
    private let now: @Sendable () -> Date
    private let index: JSONFile<Index>

    public private(set) var builds: [LibraryBuild] = []
    public private(set) var rejected: [RejectedBuild] = []
    public private(set) var isActive = false
    /// 저장된 인덱스를 읽었는지. 읽기 전이나 읽지 못했을 때는 게시 폴더와 인덱스를 바꾸지 않는다.
    public private(set) var isLoaded = false

    /// `deactivate`마다 늘어난다. 진행 중이거나 기다리던 `activate`는 값이 바뀌면 멈춘다.
    private var epoch = 0
    private var busy = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextWaiterID: UInt64 = 0

    struct Index: Codable, Sendable {
        var builds: [LibraryBuild]
    }

    public init(
        paths: HostPaths,
        host: any HostCore,
        inspector: any BuildInspecting = KitBuildInspector(),
        packager: any BuildPackaging = KitBuildPackager(),
        keepPerBundle: Int = 3,
        maxRejected: Int = 50,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.host = host
        self.inspector = inspector
        self.packager = packager
        self.keepPerBundle = max(1, keepPerBundle)
        self.maxRejected = max(1, maxRejected)
        self.now = now
        self.index = JSONFile(url: paths.buildsFile)
    }

    // MARK: 순차 실행

    /// 차례를 기다린다. 기다리는 태스크가 취소되면 `CancellationError`를 던진다.
    private func lock() async throws {
        guard busy else {
            busy = true
            return
        }
        nextWaiterID &+= 1
        let id = nextWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, c))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// 차례를 기다리는 작업 수(테스트용).
    var waitingCount: Int { waiters.count }

    private func cancelWaiter(_ id: UInt64) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }  // 이미 차례를 받았다
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }

    private func unlock() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()  // busy는 다음 작업에 넘긴다
        }
    }

    private func serially<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try await lock()
        defer { unlock() }
        return try await body()
    }

    // MARK: 인덱스

    /// 저장된 인덱스를 읽고 작업 폴더의 남은 임시 파일을 지운다. 노드에는 아직 게시하지 않는다.
    /// 한 번 읽은 뒤에는 아무것도 하지 않는다. 읽기 전에는 가져오기가 돌 수 없으므로(`isLoaded`) 작업 폴더를 지워도 안전하다.
    public func load() throws {
        guard !isLoaded else { return }
        try paths.prepare()
        builds = try index.load()?.builds ?? []
        isLoaded = true
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: paths.workDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }
    }

    private func saveIndex() throws {
        try index.save(Index(builds: builds))
    }

    // MARK: 노드 연결

    /// 공유를 시작한 뒤 부른다. 저장된 빌드의 IPA 크기·SHA-256과 프로필 만료를 확인해 다시 게시한다.
    ///
    /// - IPA가 없거나 크기·해시가 확실히 다르면 목록과 디스크에서 지운다.
    /// - 프로필이 만료된 빌드는 게시하지 않고 거부 목록으로 옮긴다.
    /// - 읽기 오류·게시 실패는 목록에 남기고 `failed`로 알린다.
    /// - 취소되거나 그사이 `deactivate`되면 아무것도 바꾸지 않고 `interrupted`로 돌려준다.
    /// - 저장된 목록을 읽지 못했으면 시작하지 않는다(`notLoaded`). 빈 목록으로 보고 IPA를 지우면 안 된다.
    @discardableResult
    public func activate() async -> RestoreReport {
        guard isLoaded else {
            var report = RestoreReport()
            report.interrupted = true
            report.notLoaded = true
            return report
        }
        let epoch = self.epoch
        do {
            return try await serially { await restoreAll(epoch: epoch) }
        } catch {
            var report = RestoreReport()
            report.interrupted = true
            return report
        }
    }

    /// 공유를 멈출 때 부른다. 기다리거나 진행 중인 `activate`는 멈추고, 이후 가져온 빌드는 다음 `activate`에서 게시된다.
    public func deactivate() {
        epoch += 1
        isActive = false
    }

    private func restoreAll(epoch: Int) async -> RestoreReport {
        var report = RestoreReport()
        func live() -> Bool { epoch == self.epoch && !Task.isCancelled }
        func interrupt() -> RestoreReport {
            if epoch == self.epoch { isActive = false }
            var r = report
            r.interrupted = true
            return r
        }
        guard live() else { return interrupt() }
        isActive = true

        let checkTime = now()
        var kept: [LibraryBuild] = []
        var removeFiles: [URL] = []
        var expiredBuilds: [LibraryBuild] = []
        for build in builds {
            guard live() else { return interrupt() }
            let url = paths.ipaURL(forBuildID: build.id)
            switch FileKind.of(url) {
            case .missing:
                report.removed.append(build.id)
                continue
            case .other:  // 일반 파일이 아니면(링크 등) 게시할 수 없다. 링크가 가리키는 대상은 건드리지 않는다.
                report.removed.append(build.id)
                continue
            case .unreadable(let code):
                kept.append(build)
                report.failed.append(.init(buildID: build.id, message: HostErrorText.message(for: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))))
                continue
            case .regular:
                break
            }
            let digest: FileDigest
            do {
                digest = try await packager.digest(of: url)
            } catch {
                if error is CancellationError || !live() { return interrupt() }
                kept.append(build)
                report.failed.append(.init(buildID: build.id, message: HostErrorText.message(for: error)))
                continue
            }
            guard live() else { return interrupt() }
            guard digest.size == build.descriptor.ipa.size, digest.sha256 == build.descriptor.ipa.sha256 else {
                removeFiles.append(url)
                report.removed.append(build.id)
                continue
            }
            if build.descriptor.signing.profileExpires <= checkTime {
                expiredBuilds.append(build)
                report.expired.append(build.id)
                continue
            }
            kept.append(build)
            do {
                try await host.publish(PublishRequest(build: build.descriptor, ipaPath: url.path))
                report.restored.append(build.id)
            } catch {
                if error is CancellationError || !live() { return interrupt() }
                report.failed.append(.init(buildID: build.id, message: HostErrorText.message(for: error)))
            }
        }
        guard live() else { return interrupt() }

        // 끝까지 확인했을 때만 바꾼다.
        let fm = FileManager.default
        for url in removeFiles { try? fm.removeItem(at: url) }
        for build in expiredBuilds {
            try? fm.removeItem(at: paths.ipaURL(forBuildID: build.id))
            _ = recordRejection(path: build.sourcePath, bundleId: build.descriptor.bundleId,
                                reasons: [Rejection(code: .profileExpired, detail: "프로필이 만료됐습니다")])
        }
        builds = kept
        removeOrphanIPAs()
        try? saveIndex()
        return report
    }

    /// 게시 폴더 맨 위의 일반 `.ipa` 파일 중 목록에 없는 것만 지운다.
    /// 숨김 항목(코어의 `.rd-snapshots` 등)·폴더·심볼릭 링크·다른 확장자는 건드리지 않는다.
    private func removeOrphanIPAs() {
        let fm = FileManager.default
        let known = Set(builds.map { "\($0.id).ipa" })
        for item in (try? fm.contentsOfDirectory(at: paths.publishedDir, includingPropertiesForKeys: nil)) ?? [] {
            let name = item.lastPathComponent
            guard !name.hasPrefix("."), item.pathExtension == "ipa", !known.contains(name), FileKind.of(item) == .regular else { continue }
            try? fm.removeItem(at: item)
        }
    }

    // MARK: 가져오기

    /// `.app` 폴더나 `.ipa` 파일을 가져온다. 정책 위반은 `.rejected`로 돌려준다(던지지 않는다).
    public func importBuild(at url: URL, mode: ImportMode = .automatic) async throws -> ImportOutcome {
        try await serially { try await performImport(url, mode: mode) }
    }

    private enum Prepared {
        case ready(BuildDescriptor)
        case rejected(RejectedBuild)
        case needsConfirmation(BuildIdentity)
    }

    private func performImport(_ source: URL, mode: ImportMode) async throws -> ImportOutcome {
        guard isLoaded else { throw BuildLibraryError.notLoaded }
        try paths.prepare()
        let kind = source.pathExtension.lowercased()
        guard kind == "app" || kind == "ipa" else { throw BuildLibraryError.unsupportedFile(source.lastPathComponent) }
        var confirmed = false
        if case .confirmed = mode { confirmed = true }
        let options = InspectionOptions(confirmedDebug: confirmed, now: now())

        let fm = FileManager.default
        let temp = paths.workDir.appendingPathComponent("import-\(UUID().uuidString).ipa")
        defer { try? fm.removeItem(at: temp) }

        let prepared = kind == "app"
            ? try await prepareApp(source, temp: temp, options: options, mode: mode)
            : try await prepareIPA(source, temp: temp, options: options, mode: mode)
        var descriptor: BuildDescriptor
        switch prepared {
        case .rejected(let r): return .rejected(r)
        case .needsConfirmation(let identity):
            forgetRejections(of: source)  // 답을 기다리는 동안 같은 빌드를 거부 목록에 함께 보여 주지 않는다.
            return .needsConfirmation(identity)
        case .ready(let d): descriptor = d
        }
        if case .confirmed(let expected) = mode,
           descriptor.bundleId != expected.bundleId || descriptor.version != expected.version || descriptor.buildNumber != expected.buildNumber {
            throw BuildLibraryError.changedSinceConfirmation(source.lastPathComponent)
        }
        descriptor.publishedAt = now()

        // 게시 직전: 옮길 파일이 검사한 그 바이트인지 한 번 더 확인한다.
        guard FileKind.of(temp) == .regular else { throw BuildLibraryError.changedDuringImport(source.lastPathComponent) }
        let final = try await packager.digest(of: temp)
        guard final.size == descriptor.ipa.size, final.sha256 == descriptor.ipa.sha256 else {
            throw BuildLibraryError.changedDuringImport(source.lastPathComponent)
        }

        let destination = paths.ipaURL(forBuildID: descriptor.id)
        let alreadyIndexed = builds.contains { $0.id == descriptor.id }
        try atomicReplace(temp, with: destination)

        if isActive {
            let publishEpoch = epoch
            do {
                try await host.publish(PublishRequest(build: descriptor, ipaPath: destination.path))
            } catch {
                // 그사이 공유가 멈췄으면 버리지 않고 남겨 두었다가 다음 시작 때 게시한다.
                if publishEpoch == epoch {
                    if !alreadyIndexed { try? fm.removeItem(at: destination) }
                    throw BuildLibraryError.publishFailed(HostErrorText.message(for: error))
                }
            }
        }

        let build = LibraryBuild(descriptor: descriptor, sourcePath: source.path)
        builds.removeAll { $0.id == build.id }
        builds.insert(build, at: 0)
        forgetRejections(of: source)
        await enforceRetention(bundleId: descriptor.bundleId)
        try saveIndex()
        return .accepted(build)
    }

    /// `.app`: 지문 → 폴더 검사(규칙 7 근거) → 작업 폴더에 IPA 묶기 → 지문 재확인 → 그 IPA 검사.
    private func prepareApp(_ source: URL, temp: URL, options: InspectionOptions, mode: ImportMode) async throws -> Prepared {
        let name = source.lastPathComponent
        guard let before = BundleSnapshot.take(source) else {
            return .rejected(recordRejection(path: source.path, bundleId: nil,
                                             reasons: [Rejection(code: .unreadable, detail: "번들을 읽을 수 없습니다")]))
        }
        if case .confirmed(let expected) = mode, expected.content != .app(before) {
            throw BuildLibraryError.changedSinceConfirmation(name)
        }
        let folder: InspectionResult
        switch try await inspect(source, { try await self.inspector.inspect(appAt: source, options: options) }) {
        case .rejected(let r): return .rejected(r)
        case .inspected(let result): folder = result
        }
        if mode == .askIfUnverified, Self.isOnlyUnverified(folder) {
            var confirmedOptions = options
            confirmedOptions.confirmedDebug = true
            switch try await inspect(source, { try await self.inspector.inspect(appAt: source, options: confirmedOptions) }) {
            case .rejected(let r): return .rejected(r)
            case .inspected(let result):
                guard result.accepted, let d = result.descriptor else { return .rejected(rejection(source, result)) }
                guard BundleSnapshot.take(source) == before else { throw BuildLibraryError.changedDuringImport(name) }
                return .needsConfirmation(BuildIdentity(content: .app(before), bundleId: d.bundleId, version: d.version, buildNumber: d.buildNumber))
            }
        }
        guard folder.accepted, let folderDescriptor = folder.descriptor else { return .rejected(rejection(source, folder)) }

        let packaged = try await packager.package(appAt: source, to: temp)
        guard BundleSnapshot.take(source) == before else { throw BuildLibraryError.changedDuringImport(name) }

        // 규칙 7(구성)은 위 폴더 검사로 확인했다. IPA에는 폴더 정보가 없으므로 그 결과를 넘긴다.
        var ipaOptions = options
        ipaOptions.confirmedDebug = true
        let packagedResult: InspectionResult
        switch try await inspect(source, { try await self.inspector.inspect(ipaAt: temp, options: ipaOptions, workDirectory: self.paths.workDir) }) {
        case .rejected(let r): return .rejected(r)
        case .inspected(let result): packagedResult = result
        }
        guard packagedResult.accepted, var descriptor = packagedResult.descriptor else { return .rejected(rejection(source, packagedResult)) }
        guard descriptor.ipa.size == packaged.size, descriptor.ipa.sha256 == packaged.sha256,
              descriptor.bundleId == folderDescriptor.bundleId,
              descriptor.version == folderDescriptor.version,
              descriptor.buildNumber == folderDescriptor.buildNumber,
              descriptor.signing.teamId == folderDescriptor.signing.teamId
        else { throw BuildLibraryError.changedDuringImport(name) }
        descriptor.configuration = folderDescriptor.configuration
        descriptor.configurationEvidence = folderDescriptor.configurationEvidence
        return .ready(descriptor)
    }

    /// `.ipa`: 내용(링크가 아니라 실제 파일)을 작업 폴더로 복사 → 해시 → 그 사본을 검사.
    private func prepareIPA(_ source: URL, temp: URL, options: InspectionOptions, mode: ImportMode) async throws -> Prepared {
        let name = source.lastPathComponent
        let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
        do {
            try FileManager.default.copyItem(at: resolved, to: temp)
        } catch {
            return .rejected(recordRejection(path: source.path, bundleId: nil,
                                             reasons: [Rejection(code: .unreadable, detail: HostErrorText.message(for: error))]))
        }
        guard FileKind.of(temp) == .regular else { throw BuildLibraryError.changedDuringImport(name) }
        let copied = try await packager.digest(of: temp)
        if case .confirmed(let expected) = mode, expected.content != .ipa(copied) {
            throw BuildLibraryError.changedSinceConfirmation(name)
        }
        let result: InspectionResult
        switch try await inspect(source, { try await self.inspector.inspect(ipaAt: temp, options: options, workDirectory: self.paths.workDir) }) {
        case .rejected(let r): return .rejected(r)
        case .inspected(let r): result = r
        }
        if mode == .askIfUnverified, Self.isOnlyUnverified(result) {
            var confirmedOptions = options
            confirmedOptions.confirmedDebug = true
            switch try await inspect(source, { try await self.inspector.inspect(ipaAt: temp, options: confirmedOptions, workDirectory: self.paths.workDir) }) {
            case .rejected(let r): return .rejected(r)
            case .inspected(let confirmedResult):
                guard confirmedResult.accepted, let d = confirmedResult.descriptor else { return .rejected(rejection(source, confirmedResult)) }
                return .needsConfirmation(BuildIdentity(content: .ipa(copied), bundleId: d.bundleId, version: d.version, buildNumber: d.buildNumber))
            }
        }
        guard result.accepted, let descriptor = result.descriptor else { return .rejected(rejection(source, result)) }
        guard descriptor.ipa.size == copied.size, descriptor.ipa.sha256 == copied.sha256 else {
            throw BuildLibraryError.changedDuringImport(name)
        }
        return .ready(descriptor)
    }

    private enum Inspected {
        case inspected(InspectionResult)
        case rejected(RejectedBuild)
    }

    private func inspect(_ source: URL, _ body: () async throws -> InspectionResult) async throws -> Inspected {
        do {
            return .inspected(try await body())
        } catch let InspectionError.unreadable(message) {
            return .rejected(recordRejection(path: source.path, bundleId: nil, reasons: [Rejection(code: .unreadable, detail: message)]))
        }
    }

    /// 구성을 확인하지 못한 것 말고는 걸린 규칙이 없다.
    private static func isOnlyUnverified(_ result: InspectionResult) -> Bool {
        !result.accepted && Set(result.reasons.map(\.code)) == [.configurationUnverified]
    }

    /// 이 원본의 예전 거부 기록을 지운다(게시됐거나 사용자에게 다시 묻는 중이라 더 맞지 않는다).
    private func forgetRejections(of source: URL) {
        rejected.removeAll { $0.sourcePath == source.path }
    }

    private func rejection(_ source: URL, _ result: InspectionResult) -> RejectedBuild {
        var reasons = result.reasons
        if reasons.isEmpty { reasons = [Rejection(code: .unreadable, detail: "검사 결과에 빌드 정보가 없습니다")] }
        return recordRejection(path: source.path, bundleId: result.bundleId ?? result.descriptor?.bundleId, reasons: reasons)
    }

    /// `temp`를 `destination`으로 옮긴다. 같은 볼륨의 rename(2)이라 기존 파일은 원자적으로 바뀐다.
    private func atomicReplace(_ temp: URL, with destination: URL) throws {
        if rename(temp.path, destination.path) != 0 {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path,
                                                          NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }

    /// 번들별 최신 `keepPerBundle`개만 남긴다. 게시 취소가 `build_not_found` 밖의 이유로 실패하면
    /// 목록과 IPA를 남겨 두고 다음 가져오기 때 다시 시도한다.
    private func enforceRetention(bundleId: String) async {
        let same = builds.filter { $0.descriptor.bundleId == bundleId }
        guard same.count > keepPerBundle else { return }
        for old in same.dropFirst(keepPerBundle) {
            if isActive {
                do {
                    try await host.unpublish(buildID: old.id)
                } catch where HostErrorText.isBuildNotFound(error) {
                    // 코어에 없으면 이미 내려간 것이다.
                } catch {
                    continue
                }
            }
            try? FileManager.default.removeItem(at: paths.ipaURL(forBuildID: old.id))
            builds.removeAll { $0.id == old.id }
        }
    }

    private func recordRejection(path: String, bundleId: String?, reasons: [Rejection]) -> RejectedBuild {
        let item = RejectedBuild(sourcePath: path, bundleId: bundleId, reasons: reasons, rejectedAt: now())
        rejected.insert(item, at: 0)
        if rejected.count > maxRejected { rejected.removeLast(rejected.count - maxRejected) }
        return item
    }

    // MARK: 게시 취소

    /// 코어가 `build_not_found`로 답하면(재게시에 실패한 빌드 등) 이미 내려간 것으로 보고 목록에서 뺀다.
    public func unpublish(id: String) async throws {
        try await serially {
            guard builds.contains(where: { $0.id == id }) else { throw BuildLibraryError.unknownBuild(id) }
            if isActive {
                do {
                    try await host.unpublish(buildID: id)
                } catch where HostErrorText.isBuildNotFound(error) {}
            }
            try? FileManager.default.removeItem(at: paths.ipaURL(forBuildID: id))
            builds.removeAll { $0.id == id }
            try saveIndex()
        }
    }

    public func clearRejected() {
        rejected.removeAll()
    }
}
