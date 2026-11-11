#if DEBUG
// 미리보기·테스트 전용. Release 빌드에는 들어가지 않으며 실제 화면은 이 데이터를 쓰지 않는다.
// 이 대상(MacHostUI)은 Go 런타임을 링크하지 않으므로 Xcode 미리보기가 이 파일만으로 뜬다.
import Foundation
import MacHostKit
import RDBuildInspection
import RDModels
import Synchronization
import SwiftUI

/// 미리보기용 가짜 코어. 정해 둔 상태를 돌려주고, 이벤트를 구독하면 미리 넣어 둔 이벤트를 보낸다.
final class PreviewCore: HostCore {
    struct Setup: Sendable {
        var status: CoreStatus
        var startError: APIErrorBody?
        var events: [CoreEvent] = []
        var pairing = PairingCode(code: "K7M29QXD", expiresAt: Date().addingTimeInterval(272))
    }

    private let setup: Mutex<Setup>
    private let continuation = Mutex<AsyncStream<CoreEvent>.Continuation?>(nil)

    init(_ setup: Setup) {
        self.setup = Mutex(setup)
    }

    func start(_ config: CoreConfig) async throws {
        if let error = setup.withLock({ $0.startError }) { throw error }
    }

    func stop() async {
        continuation.withLock { $0?.finish(); $0 = nil }
    }

    func status() async throws -> CoreStatus { setup.withLock { $0.status } }
    func publish(_ request: PublishRequest) async throws {}
    func unpublish(buildID: String) async throws {}
    func setDevices(_ devices: [DeviceEntry]) async throws {}
    func openPairing(ttlSeconds: Int) async throws -> PairingCode { setup.withLock { $0.pairing } }

    func decidePairing(requestID: String, allow: Bool) async throws -> DeviceEntry? {
        allow ? DeviceEntry(id: "d_preview2", name: "iPhone", nodeStableId: "nPREVIEW2", nodeName: "rd-phone-preview",
                            loginName: "", pairedAt: Date()) : nil
    }

    func events() -> AsyncStream<CoreEvent> {
        let (stream, c) = AsyncStream.makeStream(of: CoreEvent.self)
        setup.withLock { $0.events }.forEach { c.yield($0) }
        continuation.withLock { $0 = c }
        return stream
    }
}

/// 저장된 게시본의 크기·해시를 미리 정해 둔 값으로 돌려준다(빈 파일로 다시 게시가 통과하게).
struct PreviewPackager: BuildPackaging {
    let digests: [String: FileDigest]

    func package(appAt appURL: URL, to ipaURL: URL) async throws -> FileDigest {
        try Data().write(to: ipaURL)
        return FileDigest(size: 0, sha256: "")
    }

    func digest(of fileURL: URL) async throws -> FileDigest {
        digests[fileURL.lastPathComponent] ?? FileDigest(size: 0, sha256: "")
    }
}

/// 폴더 이름이 `Release-iphoneos`면 구성 위반, 이름에 `AdHoc`이 있으면 배포 프로필로 거부한다.
struct PreviewInspector: BuildInspecting {
    func inspect(appAt url: URL, options: InspectionOptions) async throws -> InspectionResult {
        var reasons: [Rejection] = []
        if url.deletingLastPathComponent().lastPathComponent.hasPrefix("Release") {
            reasons.append(Rejection(code: .configurationNotDebug, detail: "Release"))
        }
        if url.lastPathComponent.contains("AdHoc") {
            reasons.append(Rejection(code: .notDevelopmentProfile, detail: "ad_hoc"))
            reasons.append(Rejection(code: .getTaskAllowMissing, detail: ""))
        }
        return InspectionResult(accepted: false, reasons: reasons, warnings: [], descriptor: nil,
                                bundleId: "com.example.preview.\(url.deletingPathExtension().lastPathComponent.lowercased())")
    }

    func inspect(ipaAt url: URL, options: InspectionOptions, workDirectory: URL) async throws -> InspectionResult {
        InspectionResult(accepted: false, reasons: [Rejection(code: .unreadable, detail: "")], warnings: [], descriptor: nil)
    }
}

/// 저장한 감시 폴더를 풀 수 없는 상태(미리보기용).
struct UnresolvableBookmarks: FolderBookmarking {
    func save(_ url: URL) throws {}
    func resolve() -> URL? { nil }
    func clear() {}
    func savedFolder() -> SavedFolder { .unresolvable(path: "/Users/preview/Library/Developer/Xcode/DerivedData/Sample/Build/Products") }
}

public enum PreviewScenario: Sendable, CaseIterable {
    /// ① 빈 상태 + 로그인 전(공유 중지)
    case empty
    /// ② 로그인 필요(authURL 있음)
    case needsLogin
    /// ③ 공유 중: 빌드 2개, 기기 1대, 승인 대기 1건
    case sharing
    /// ④ 거부된 빌드 목록
    case rejected
    /// ⑤ HTTPS 인증서 꺼짐
    case certificatesOff
    /// ⑥ 오류
    case error
    /// 공유 중이지만 로그인 전이라 페어링할 수 없음
    case pairingUnavailable
    /// 저장한 감시 폴더를 열 수 없음
    case watchProblem
}

@MainActor
public enum PreviewFactory {
    static let id8 = "ab12cd34"
    static let fqdn = "rd-mac-ab12cd34.example.ts.net"

    struct Index: Codable {
        var builds: [LibraryBuild]
    }

    static func runningStatus(certificates: Bool = true) -> CoreStatus {
        CoreStatus(backendState: .running, hostname: "rd-mac-\(id8)", fqdn: fqdn, tailscaleIPs: ["100.64.0.10"],
                   certDomains: certificates ? [fqdn] : [], tlsReady: certificates, listening: certificates,
                   publishedBuilds: 2, pairedDevices: 1, rssMiB: 31.5)
    }

    /// 시나리오의 모델. `root`를 주면 그 아래에 저장한다(없으면 임시 폴더). 지우는 것은 부른 쪽이 한다.
    public static func makeModel(_ scenario: PreviewScenario, root: URL? = nil) async -> HostModel {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteDebugPreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = HostPaths(root: root)
        _ = try? paths.prepare()

        var setup = PreviewCore.Setup(status: runningStatus())
        var builds: [LibraryBuild] = []
        var devices: [DeviceEntry] = []
        var start = true
        var bookmarks: any FolderBookmarking = NoFolderBookmarks()

        switch scenario {
        case .empty:
            start = false
        case .needsLogin:
            setup.status = CoreStatus(backendState: .needsLogin, authURL: "https://login.example.com/a/preview", hostname: "rd-mac-\(id8)")
        case .sharing:
            builds = sampleBuilds()
            devices = [DeviceEntry(id: "d_9c2e41b7", name: "내 iPhone", nodeStableId: "nSTABLE1PREVIEW",
                                   nodeName: "rd-phone-ab12cd34", loginName: "user@example.com",
                                   pairedAt: Date().addingTimeInterval(-86_400 * 3))]
            setup.events = [.pairRequest(PairRequestEvent(requestId: "pr_7c1e55d0", deviceName: "테스트 iPhone",
                                                          nodeName: "rd-phone-77aa01ef", loginName: "user@example.com",
                                                          expiresAt: Date().addingTimeInterval(110)))]
        case .rejected:
            start = false
        case .certificatesOff:
            setup.status = runningStatus(certificates: false)
        case .error:
            setup.status = CoreStatus(backendState: .error, hostname: "rd-mac-\(id8)",
                                      errorMessage: "제어 서버에 연결하지 못했습니다(connection refused).")
        case .pairingUnavailable:
            setup.status = CoreStatus(backendState: .needsLogin, authURL: "https://login.example.com/a/preview", hostname: "rd-mac-\(id8)")
        case .watchProblem:
            start = false
            builds = sampleBuilds()
            bookmarks = UnresolvableBookmarks()
        }

        try? JSONFile<Index>(url: paths.buildsFile).save(Index(builds: builds))
        try? JSONFile<DeviceList>(url: paths.devicesFile).save(DeviceList(devices: devices))
        var digests: [String: FileDigest] = [:]
        for b in builds {
            try? Data().write(to: paths.ipaURL(forBuildID: b.id))
            digests["\(b.id).ipa"] = FileDigest(size: b.descriptor.ipa.size, sha256: b.descriptor.ipa.sha256)
        }

        let model = HostModel(core: PreviewCore(setup), paths: paths, inspector: PreviewInspector(),
                              packager: PreviewPackager(digests: digests), bookmarks: bookmarks,
                              watcherOptions: .init(useFileEvents: false), id8: id8, hostDisplayName: "미리보기 Mac",
                              appVersion: "0.1.0", openURL: { _ in })
        await model.load()
        await model.waitForFolderResume()
        if start { await model.start() }

        if scenario == .rejected {
            for (folder, name) in [("Release-iphoneos", "Sample.app"), ("Debug-iphoneos", "AdHocSample.app")] {
                let app = root.appendingPathComponent("src/\(folder)/\(name)", isDirectory: true)
                try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
                try? Data("preview".utf8).write(to: app.appendingPathComponent("Sample"))
                await model.importBuild(app)
            }
        }
        if scenario == .error {
            model.lastError = "공유 상태를 읽지 못했습니다: 코어 내부 오류가 발생했습니다."
        }
        return model
    }

    /// 시나리오의 모델에 페어링 코드를 연다(페어링 시트 미리보기). 공유 중 시나리오는 허용 대기 요청이 먼저 도착한 뒤 연다.
    public static func makePairingModel(_ scenario: PreviewScenario, root: URL? = nil) async -> HostModel {
        let model = await makeModel(scenario, root: root)
        if scenario == .sharing {
            for _ in 0..<300 where model.pendingPairRequests.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        }
        await model.beginPairing()
        return model
    }

    public static func sampleBuilds() -> [LibraryBuild] {
        func build(_ name: String, bundle: String, version: String, number: String, evidence: BuildDescriptor.ConfigurationEvidence,
                   expires: TimeInterval, published: TimeInterval, sha: Character) -> LibraryBuild {
            let hash = String(repeating: sha, count: 64)
            let d = BuildDescriptor(
                id: BuildDescriptor.makeID(bundleId: bundle, ipaSHA256: hash), bundleId: bundle, displayName: name,
                version: version, buildNumber: number, minOS: "26.0", debug: true, configuration: "Debug",
                configurationEvidence: evidence,
                signing: .init(teamId: "ABCDE12345", profileName: "iOS Team Provisioning Profile: \(bundle)",
                               profileExpires: Date().addingTimeInterval(expires), provisionedDeviceCount: 3, getTaskAllow: true),
                ipa: .init(size: 52_428_800, sha256: hash), publishedAt: Date().addingTimeInterval(published))
            return LibraryBuild(descriptor: d, sourcePath: "/Users/preview/DerivedData/Build/Products/Debug-iphoneos/\(name).app")
        }
        return [
            build("Sample", bundle: "com.example.app.Sample", version: "1.4.0", number: "128", evidence: .path,
                  expires: 86_400 * 170, published: -600, sha: "a"),
            build("Notes", bundle: "com.example.app.Notes", version: "2.0.1", number: "7", evidence: .debugDylib,
                  expires: 86_400 * 5, published: -86_400, sha: "b"),
        ]
    }
}

/// 시나리오의 모델을 만든 뒤 앱 화면을 그린다.
public struct PreviewHost: View {
    let scenario: PreviewScenario
    let selection: SidebarItem
    @State private var model: HostModel?

    public init(scenario: PreviewScenario, selection: SidebarItem) {
        self.scenario = scenario
        self.selection = selection
    }

    public var body: some View {
        Group {
            if let model {
                RootView(selection: selection)
                    .environment(model)
            } else {
                ProgressView()
                    .task { model = await PreviewFactory.makeModel(scenario) }
            }
        }
        .frame(width: 960, height: 640)
    }
}

/// 시나리오의 모델로 페어링 시트를 그린다(코드가 열린 상태).
public struct PairingSheetPreviewHost: View {
    let scenario: PreviewScenario
    @State private var model: HostModel?

    public init(scenario: PreviewScenario) {
        self.scenario = scenario
    }

    public var body: some View {
        if let model {
            PairingSheet()
                .environment(model)
                .environment(AuthKeyDraft())
        } else {
            ProgressView()
                .frame(width: 520, height: 400)
                .task { model = await PreviewFactory.makePairingModel(scenario) }
        }
    }
}

#Preview("① 빈 상태·로그인 전") {
    PreviewHost(scenario: .empty, selection: .builds)
}

#Preview("② 로그인 필요") {
    PreviewHost(scenario: .needsLogin, selection: .network)
}

#Preview("③ 공유 중: 빌드 2·기기 1·허용 대기 1") {
    PreviewHost(scenario: .sharing, selection: .devices)
}

#Preview("③ 공유 중: 빌드 목록·페어링 요청 알림") {
    PreviewHost(scenario: .sharing, selection: .builds)
}

#Preview("③ 공유 중: 페어링 코드·Safari 설치 페이지") {
    PairingSheetPreviewHost(scenario: .sharing)
}

#Preview("③ 공유 중: 네트워크·설치 페이지 주소") {
    PreviewHost(scenario: .sharing, selection: .network)
}

#Preview("④ 거부된 빌드") {
    PreviewHost(scenario: .rejected, selection: .builds)
}

#Preview("⑤ HTTPS 인증서 꺼짐") {
    PreviewHost(scenario: .certificatesOff, selection: .network)
}

#Preview("⑥ 오류") {
    PreviewHost(scenario: .error, selection: .network)
}

#Preview("로그인 전: 페어링 불가") {
    PreviewHost(scenario: .pairingUnavailable, selection: .devices)
}

#Preview("감시 폴더를 열 수 없음") {
    PreviewHost(scenario: .watchProblem, selection: .builds)
}
#endif
