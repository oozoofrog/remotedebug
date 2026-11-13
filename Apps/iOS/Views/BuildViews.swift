import PhoneClientKit
import RDModels
import SwiftUI

/// Mac이 공유 중인 빌드 목록. 이 앱 자신의 빌드는 `state.builds`에 없다(업데이트 앱에서 설치한다).
struct BuildListSection: View {
    var state: PhoneViewState
    var actions: PhoneActions

    var body: some View {
        Section {
            if state.buildsLoadedAt == nil {
                notLoaded
            } else {
                if let error = state.refreshError {
                    Label {
                        Text("목록을 새로 받지 못했습니다. 아래는 이전 목록입니다.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.footnote)
                    .accessibilityHint(error)
                }
                if state.builds.isEmpty {
                    ContentUnavailableView {
                        Label("공유 중인 빌드가 없습니다", systemImage: "shippingbox")
                    } description: {
                        Text("Mac 앱에서 빌드를 공유한 뒤 새로고침하세요.")
                    }
                } else {
                    // 같은 앱의 빌드는 최신 것만 보여 주고 나머지는 접어 둔다.
                    ForEach(AppBuildGrouping.groups(state.builds)) { group in
                        ListedBuildRow(build: group.latest, state: state, actions: actions)
                        if !group.older.isEmpty {
                            DisclosureGroup("\(group.latest.displayName) 이전 빌드 \(group.older.count)개") {
                                ForEach(group.older) { build in
                                    ListedBuildRow(build: build, state: state, actions: actions, isOlder: true)
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("빌드")
                Spacer()
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await actions.refresh() }
                    } label: {
                        Label("새로고침", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("빌드 목록 새로고침")
                }
            }
        } footer: {
            if let loaded = state.buildsLoadedAt {
                Text("\(loaded.formatted(date: .omitted, time: .shortened))에 받은 목록")
            }
        }
    }

    @ViewBuilder
    private var notLoaded: some View {
        if state.isRefreshing {
            HStack(spacing: 12) {
                ProgressView()
                Text("빌드 목록을 받는 중")
            }
        } else if let error = state.refreshError {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.subheadline)
                Button("다시 시도") { Task { await actions.refresh() } }
                    .buttonStyle(.borderless)
            }
        } else if state.tunnel != .connected {
            Text("VPN이 연결되면 빌드 목록을 받습니다.")
                .foregroundStyle(.secondary)
        } else {
            Button("빌드 목록 받기") { Task { await actions.refresh() } }
        }
    }
}

/// 빌드 목록의 한 줄. 설치된 앱이면 크래시 기록 버튼을 붙인다.
private struct ListedBuildRow: View {
    var build: BuildDescriptor
    var state: PhoneViewState
    var actions: PhoneActions
    var isOlder = false
    @Environment(\.crashPanel) private var crashPanel
    @State private var showsCrashes = false

    private var installed: InstalledApp? { state.installedApps[build.bundleId] }

    private var crashCount: Int {
        crashPanel?.state.crashes.count { $0.bundleId == build.bundleId } ?? 0
    }

    var body: some View {
        BuildRow(build: build, install: state.installs[build.id], actions: actions.installActions, isOlder: isOlder,
                 installed: installed, preparation: state.installPreparations[build.id],
                 accessory: installed != nil && !isOlder && crashPanel != nil ? AnyView(crashButton) : nil)
            .sheet(isPresented: $showsCrashes) {
                if let crashPanel { AppCrashSheet(app: build, panel: crashPanel) }
            }
    }

    private var crashButton: some View {
        Button {
            showsCrashes = true
        } label: {
            Label(crashCount == 0 ? "크래시 기록" : "크래시 기록 \(crashCount)개", systemImage: "waveform.path.ecg")
                .font(.footnote)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(build.displayName) 크래시 기록")
    }
}
