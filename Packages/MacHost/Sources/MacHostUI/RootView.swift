import AppKit
import MacHostKit
import RDModels
import SwiftUI
import UniformTypeIdentifiers

public enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case builds, projects, devices, network, activity

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .builds: "빌드"
        case .projects: "프로젝트"
        case .devices: "기기"
        case .network: "네트워크"
        case .activity: "활동"
        }
    }

    var symbol: String {
        switch self {
        case .builds: "shippingbox"
        case .projects: "hammer"
        case .devices: "iphone"
        case .network: "network"
        case .activity: "list.bullet.rectangle"
        }
    }
}

/// 네트워크 화면에서 입력한 인증 키. 공유를 시작·다시 시작하는 모든 버튼이 꺼내 쓰고 바로 지운다. 저장하지 않는다.
@MainActor
@Observable
final class AuthKeyDraft {
    var value = ""
    /// 이 키로 다시 시작하는 중이다. 끝날 때까지 시작·다시 시작을 받지 않는다(빈 키가 먼저 시작되면 입력한 키를 잃는다).
    var isRestarting = false

    /// 입력한 키를 꺼내고 입력란을 비운다.
    func take() -> String {
        defer { value = "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct RootView: View {
    @Environment(HostModel.self) private var model
    @Environment(ProjectsModel.self) private var projects: ProjectsModel?
    @State private var selection: SidebarItem
    @State private var showingImporter = false
    @State private var showingPairing = false
    @State private var importQueue: ImportQueue
    @State private var authKey = AuthKeyDraft()
    @State private var seenRequests: [PairRequestEvent] = []

    public init(selection: SidebarItem = .builds) {
        self.init(selection: selection, importQueue: ImportQueue())
    }

    init(selection: SidebarItem, importQueue: ImportQueue) {
        _selection = State(initialValue: selection)
        _importQueue = State(initialValue: importQueue)
    }

    public var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(badge(for: item))
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                SharingStatusFooter()
                    .padding(12)
            }
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if let request = Self.noticeRequest(model: model, selection: selection, showingPairing: showingPairing) {
                            PairRequestNotice(request: request) { selection = .devices }
                        }
                        if let message = model.lastError {
                            ErrorBanner(message: message) { model.lastError = nil }
                        }
                    }
                }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: BuildFileTypes.importable,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            selection = .builds
            Task { await importQueue.importURLs(urls, using: importer) }
        }
        // 대화상자는 줄의 첫 항목을 보여 주고, 버튼은 보여 준 그 항목(id)에만 답한다. 닫힐 때 SwiftUI가 부르는
        // isPresented setter는 줄을 건드리지 않는다(버튼 동작과 겹쳐 다른 항목을 처리하지 않게).
        .confirmationDialog(
            "Debug 구성으로 빌드한 앱인가요?",
            isPresented: ImportConfirmation.isPresented(importQueue),
            presenting: importQueue.current
        ) { item in
            Button("Debug 빌드로 가져오기") { importQueue.confirm(item.id, using: importer) }
            Button("가져오지 않기", role: .cancel) { importQueue.skip(item.id) }
        } message: { item in
            Text(ImportConfirmation.message(item))
        }
        .sheet(isPresented: $showingPairing) {
            PairingSheet()
        }
        .task(id: model.pairRequests.map(\.requestId)) {
            noteNewRequests()
            // 120초 대기 시간이 지나면 요청과 알림을 내린다.
            while !Task.isCancelled, !model.pairRequests.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                model.pruneExpiredPairRequests()
            }
        }
        .environment(importQueue)
        .environment(authKey)
        .environment(\.showPairing, PairingPresenter { showingPairing = true })
        .environment(\.showNetwork, NetworkPresenter { selection = .network })
        .environment(\.connectProjects, ProjectConnector { urls in
            guard let projects else { return }
            selection = .projects
            Task { for url in urls { await projects.connectAndBuild(url) } }
        })
        .onChange(of: projects?.suggestions.count ?? 0) { old, new in
            if new > old { selection = .projects }
        }
        .focusedSceneValue(\.importBuilds, ImportBuildsAction { showingImporter = true })
    }

    private var importer: ImportQueue.Importer {
        { [model] url, mode in await model.importBuild(url, mode: mode) }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .builds: BuildsView(showImporter: { showingImporter = true })
        case .projects:
            if let projects {
                ProjectsView(projects: projects)
            } else {
                ContentUnavailableView("프로젝트를 쓸 수 없습니다", systemImage: "hammer")
            }
        case .devices: DevicesView()
        case .network: NetworkView()
        case .activity: ActivityView()
        }
    }

    /// 페어링 시트가 닫혀 있고 기기 화면이 아닐 때 창 위에 띄울 요청.
    static func noticeRequest(model: HostModel, selection: SidebarItem, showingPairing: Bool) -> PairRequestEvent? {
        guard !showingPairing, selection != .devices else { return nil }
        return model.pendingPairRequests.first
    }

    /// 새 요청이 오거나 요청이 만료되면 VoiceOver로 읽어 주고, 새 요청은 앱이 뒤에 있을 때 Dock 아이콘으로도 알린다.
    private func noteNewRequests() {
        let current = model.pendingPairRequests
        let announcements = PairRequestAnnouncements.make(previous: seenRequests, current: current, now: Date())
        let hasNew = current.contains { request in !seenRequests.contains { $0.requestId == request.requestId } }
        seenRequests = current
        for text in announcements { PairRequestAnnouncements.post(text) }
        if hasNew, let app = NSApp, !app.isActive {
            app.requestUserAttention(.informationalRequest)
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .devices: model.pendingPairRequests.count
        case .builds: importQueue.pending.count
        case .projects: projects?.suggestions.count ?? 0
        default: 0
        }
    }
}

/// 페어링 시트를 여는 동작(창에 하나).
struct PairingPresenter {
    let open: () -> Void
    func callAsFunction() { open() }
}

/// 네트워크 화면으로 가는 동작(창에 하나).
struct NetworkPresenter {
    let open: () -> Void
    func callAsFunction() { open() }
}

/// 끌어 놓은 프로젝트 파일·폴더를 연결하고 빌드하는 동작(창에 하나).
struct ProjectConnector {
    let connect: ([URL]) -> Void
    func callAsFunction(_ urls: [URL]) { connect(urls) }

    /// 끌어 놓은 항목 중 빌드 파일(.app, .ipa)이 아닌 프로젝트 파일과 폴더.
    static func projectURLs(in urls: [URL]) -> [URL] {
        urls.filter { url in
            if ["app", "ipa"].contains(url.pathExtension.lowercased()) { return false }
            return ProjectLocator.isContainer(url) || url.hasDirectoryPath
                || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}

extension EnvironmentValues {
    @Entry var connectProjects = ProjectConnector { _ in }
    @Entry var showPairing = PairingPresenter {}
    @Entry var showNetwork = NetworkPresenter {}
}

/// 페어링 요청의 도착과 만료를 VoiceOver로 알린다.
enum PairRequestAnnouncements {
    /// `previous`에 없던 요청과, 시간이 지나 사라진 요청의 문장.
    static func make(previous: [PairRequestEvent], current: [PairRequestEvent], now: Date) -> [String] {
        let arrived = current.filter { request in !previous.contains { $0.requestId == request.requestId } }
        let expired = previous.filter { request in
            request.expiresAt <= now && !current.contains { $0.requestId == request.requestId }
        }
        return arrived.map { "\(PairRequestRow.sentence($0)). 만료되기 전에 기기 화면에서 허용하거나 거부하세요." }
            + expired.map { "\(PairRequestRow.displayName($0))의 페어링 요청이 만료됐습니다. iPhone에서 다시 요청하세요." }
    }

    @MainActor
    static func post(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

/// 창 위 알림: 페어링 요청이 왔다. 허용·거부는 기기 화면에서 한다.
struct PairRequestNotice: View {
    let request: PairRequestEvent
    let show: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "iphone.badge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(PairRequestRow.sentence(request))
                    .font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(request.expiresAt.timeIntervalSince(context.date).rounded(.down)))
                    Text("\(remaining / 60):\(String(format: "%02d", remaining % 60)) 안에 허용하거나 거부하지 않으면 요청이 만료됩니다.")
                        .monospacedDigit()
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("요청 보기", action: show)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("페어링 요청")
    }
}

/// 사이드바 아래: 공유 상태와 공유 시작·중지.
struct SharingStatusFooter: View {
    @Environment(HostModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GuidanceLabel(guidance: model.guidance)
                .font(.callout)
            SharingButton()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 공유 시작 / 공유 중지. 시작하는 중에도 중지할 수 있다. 네트워크 화면에 입력한 인증 키가 있으면 그 키로 시작하고 지운다.
struct SharingButton: View {
    @Environment(HostModel.self) private var model
    @Environment(AuthKeyDraft.self) private var authKey

    var body: some View {
        if model.isRunning || model.isStarting {
            Button {
                Task { await model.stop() }
            } label: {
                Label("공유 중지", systemImage: "stop.fill")
            }
        } else {
            Button {
                SharingActions.start(model, authKey: authKey)
            } label: {
                Label("공유 시작", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(authKey.isRestarting)
        }
    }
}

/// 공유를 멈췄다가 다시 시작한다. 입력한 인증 키가 있으면 그 키로 시작하고 지운다.
struct RestartSharingButton: View {
    @Environment(HostModel.self) private var model
    @Environment(AuthKeyDraft.self) private var authKey
    var title = "공유 다시 시작"

    var body: some View {
        Button(title) {
            SharingActions.restart(model, authKey: authKey)
        }
        .disabled(authKey.isRestarting)
    }
}

/// 공유 시작·다시 시작 버튼의 동작. 입력한 인증 키는 눌린 순간 꺼내고 입력란을 비운다.
/// 다시 시작하는 동안 온 클릭은 받지 않는다(nil). 그 시작이 꺼낸 키를 쓴다.
@MainActor
enum SharingActions {
    @discardableResult
    static func start(_ model: HostModel, authKey: AuthKeyDraft) -> Task<Void, Never>? {
        guard !authKey.isRestarting else { return nil }
        let key = authKey.take()
        return Task { await model.start(authKey: key) }
    }

    @discardableResult
    static func restart(_ model: HostModel, authKey: AuthKeyDraft) -> Task<Void, Never>? {
        guard !authKey.isRestarting else { return nil }
        authKey.isRestarting = true
        let key = authKey.take()
        return Task {
            defer { authKey.isRestarting = false }
            await model.stop()
            await model.start(authKey: key)
        }
    }
}

/// 공유 상태 제목과 상태별 기호(색만으로 구분하지 않는다).
struct GuidanceLabel: View {
    let guidance: StatusGuidance

    var body: some View {
        Label {
            Text(guidance.title)
        } icon: {
            if guidance.kind == .starting || guidance.kind == .issuingCertificate || guidance.kind == .waitingForLoginURL {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: Self.symbol(guidance.kind))
                    .foregroundStyle(Self.tint(guidance.kind))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("공유 상태: \(guidance.title)")
    }

    static func symbol(_ kind: StatusGuidance.Kind) -> String {
        switch kind {
        case .ready: "checkmark.circle.fill"
        case .stopped: "pause.circle"
        case .starting, .issuingCertificate, .waitingForLoginURL: "clock"
        case .needsLogin, .needsMachineAuth: "person.badge.key"
        case .certificatesDisabled, .magicDNSDisabled: "lock.slash"
        case .error, .unknown: "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ kind: StatusGuidance.Kind) -> Color {
        switch kind {
        case .ready: .green
        case .stopped, .starting, .issuingCertificate, .waitingForLoginURL: .secondary
        case .needsLogin, .needsMachineAuth, .certificatesDisabled, .magicDNSDisabled: .orange
        case .error, .unknown: .red
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("닫기", action: dismiss)
                .accessibilityLabel("오류 메시지 닫기")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("오류")
    }
}

// MARK: 가져오기

/// Debug 구성 확인 대화상자의 내용과 표시 여부.
@MainActor
enum ImportConfirmation {
    /// `번들 ID 버전 (빌드 번호)`.
    static func title(_ item: ImportQueue.Pending) -> String {
        "\(item.identity.bundleId) \(item.identity.version) (\(item.identity.buildNumber))"
    }

    static func message(_ item: ImportQueue.Pending) -> String {
        "\(title(item))\n\(item.url.path)\n\n구성을 폴더 이름이나 debug.dylib로 확인할 수 없습니다. Xcode에서 Debug 구성으로 빌드한 것이 맞을 때만 가져오세요."
    }

    /// 대화상자가 닫힐 때 SwiftUI가 부르는 setter는 줄을 건드리지 않는다. 답은 버튼이 항목 id로 한다.
    static func isPresented(_ queue: ImportQueue) -> Binding<Bool> {
        Binding(get: { queue.current != nil }, set: { _ in })
    }
}

enum BuildFileTypes {
    static let ipa = UTType(filenameExtension: "ipa") ?? .data
    static let importable: [UTType] = [.applicationBundle, ipa]
}

struct ImportBuildsAction {
    let perform: () -> Void
    func callAsFunction() { perform() }
}

extension FocusedValues {
    @Entry var importBuilds: ImportBuildsAction?
}

/// 메뉴 막대의 파일 > 빌드 가져오기… (⌘O).
public struct ImportCommand: View {
    @FocusedValue(\.importBuilds) private var importBuilds

    public init() {}

    public var body: some View {
        Button("빌드 가져오기…") { importBuilds?() }
            .keyboardShortcut("o")
            .disabled(importBuilds == nil)
    }
}
