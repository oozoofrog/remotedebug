#if canImport(SwiftUI)
import SwiftUI

/// 설정 화면(`Form` 또는 `List`)에 두는 개발 빌드 업데이트 구역.
///
/// **Debug 빌드에서만 표시된다.** 배포 빌드에서는 `EmptyView`를 돌려주어 화면에 아무것도 나타나지 않는다.
public struct RemoteDebugUpdateSection: View {
    #if DEBUG
    @State private var status: UpdateStatus = .idle
    @State private var openFailed = false
    private let autoCheck: Bool
    #endif

    /// `autoCheck`가 `true`(기본값)면 화면이 나타날 때 자동으로 업데이트를 확인한다.
    public init(autoCheck: Bool = true) {
        #if DEBUG
        self.autoCheck = autoCheck
        #endif
    }

    public var body: some View {
        #if DEBUG
        Section {
            LabeledContent(UpdateDebugStrings.text(.currentBuild), value: RemoteDebugUpdate.currentVersionLabel)
            statusContent
            actionRow
        } header: {
            Text(UpdateDebugStrings.text(.sectionTitle))
        } footer: {
            Text(UpdateDebugStrings.text(.sectionFooter))
        }
        .task {
            if autoCheck, status == .idle, RemoteDebugUpdate.isConfigured {
                await check()
            }
        }
        #else
        EmptyView()
        #endif
    }

    #if DEBUG
    @ViewBuilder
    private var statusContent: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text(UpdateDebugStrings.text(.checking))
                    .foregroundStyle(.secondary)
            }
        case .upToDate(let info):
            if let info {
                LabeledContent(UpdateDebugStrings.text(.latestBuild), value: info.versionLabel)
                Text(UpdateDebugStrings.text(.upToDate))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(UpdateDebugStrings.text(.noPublishedBuild))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .available(let info):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(UpdateDebugStrings.text(.updateAvailableTitle), systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                    Spacer()
                    Text(info.versionLabel)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let notes = info.releaseNotes {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        case .unavailable(let reason):
            Text(message(for: reason))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if openFailed {
            Text(UpdateDebugStrings.text(.openFailed))
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if case .available(let info) = status {
            Button {
                Task { await triggerUpdate(buildId: info.buildId) }
            } label: {
                Label(UpdateDebugStrings.text(.openRemoteDebugButton), systemImage: "arrow.down.app")
            }
        }
        Button(UpdateDebugStrings.text(.checkButton)) {
            Task { await check() }
        }
        .disabled(status == .checking)
    }

    private func check() async {
        openFailed = false
        status = .checking
        status = await RemoteDebugUpdate.check()
    }

    private func triggerUpdate(buildId: String) async {
        let opened = await RemoteDebugUpdate.openUpdater(buildId: buildId)
        openFailed = !opened
    }

    private func message(for reason: UpdateUnavailableReason) -> String {
        switch reason {
        case .notConfigured: UpdateDebugStrings.text(.notConfigured)
        case .unreachable: UpdateDebugStrings.text(.unreachable)
        case .invalidResponse, .missingBundleID, .disabledInRelease: UpdateDebugStrings.text(.invalidResponse)
        }
    }
    #endif
}

/// 새 Debug 빌드가 Mac에 게시돼 있을 때만 보이는 안내 배너.
///
/// **Debug 빌드에서만 표시된다.** 배포 빌드이거나 새 빌드가 없으면 아무것도 그리지 않는다.
public struct RemoteDebugUpdateBanner: View {
    #if DEBUG
    @State private var update: UpdateInfo?
    @State private var dismissed = false
    @State private var openFailed = false
    #endif

    public init() {}

    public var body: some View {
        #if DEBUG
        Group {
            if let update, !dismissed {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(UpdateDebugStrings.text(.updateAvailableTitle)) · \(update.versionLabel)")
                                .font(.subheadline.weight(.semibold))
                            if let notes = update.releaseNotes {
                                Text(notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        Button(UpdateDebugStrings.text(.updateButton)) {
                            Task {
                                let opened = await RemoteDebugUpdate.openUpdater(buildId: update.buildId)
                                openFailed = !opened
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button {
                            dismissed = true
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if openFailed {
                        Text(UpdateDebugStrings.text(.openFailed))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .task {
            guard RemoteDebugUpdate.isConfigured else { return }
            if case .available(let info) = await RemoteDebugUpdate.check() {
                update = info
            }
        }
        #else
        EmptyView()
        #endif
    }
}

public extension View {
    /// 화면 상단에 Debug 빌드 업데이트 배너를 붙인다.
    /// **Debug 빌드에서 새 빌드가 있을 때만 표시되며, 배포 빌드에서는 뷰를 그대로 돌려준다.**
    @ViewBuilder
    func remoteDebugUpdateBanner() -> some View {
        #if DEBUG
        self.safeAreaInset(edge: .top, spacing: 0) {
            RemoteDebugUpdateBanner()
        }
        #else
        self
        #endif
    }
}
#endif
