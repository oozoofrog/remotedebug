import PhoneClientKit
import RDModels
import SwiftUI

/// Mac이 공유 중인 빌드 목록.
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
                // 이 앱의 업데이트는 위의 업데이트 칸에만 보여 준다.
                let builds = state.builds.filter { $0.id != state.selfUpdate?.id }
                if state.builds.isEmpty {
                    ContentUnavailableView {
                        Label("공유 중인 빌드가 없습니다", systemImage: "shippingbox")
                    } description: {
                        Text("Mac 앱에서 빌드를 공유한 뒤 새로고침하세요.")
                    }
                } else {
                    // 같은 앱의 빌드는 최신 것만 보여 주고 나머지는 접어 둔다.
                    ForEach(AppBuildGrouping.groups(builds)) { group in
                        BuildRow(build: group.latest, install: state.installs[group.latest.id], actions: actions, installed: state.installedApps[group.latest.bundleId])
                        if !group.older.isEmpty {
                            DisclosureGroup("\(group.latest.displayName) 이전 빌드 \(group.older.count)개") {
                                ForEach(group.older) { build in
                                    BuildRow(build: build, install: state.installs[build.id], actions: actions, isOlder: true, installed: state.installedApps[build.bundleId])
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

/// Mac에 게시된 이 앱 자신의 새 빌드. 설치가 시작되면 iOS가 앱을 닫는다.
struct SelfUpdateSection: View {
    var build: BuildDescriptor
    var install: InstallState?
    var actions: PhoneActions
    var updatePage: URL?
    var pair = VPNPairState()
    @State private var showsGuide = false
    @State private var moving = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    PhoneBuildIcon(build: build, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("새 RemoteDebug 빌드").font(.headline).lineLimit(1)
                        Text("버전 \(build.version) (\(build.buildNumber)) · \(BuildRow.size(build.ipa.size))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\(build.publishedAt.formatted(date: .abbreviated, time: .shortened)) 게시")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if install == nil {
                        Button(pair.survivesSelfUpdate || pair.installed == nil ? "업데이트" : "VPN 옮기기") {
                            if pair.survivesSelfUpdate {
                                // 다른 앱이 VPN을 켜 두었다. 설치하는 동안에도 연결이 유지되므로 여기서 바로 설치한다.
                                actions.install(build)
                            } else if pair.installed != nil {
                                moving = true
                                Task {
                                    await actions.moveVPNToVPNApp()
                                    moving = false
                                }
                            } else {
                                showsGuide = true
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .fixedSize()
                        .disabled(moving)
                        .accessibilityLabel(pair.survivesSelfUpdate ? "RemoteDebug 업데이트" : (pair.installed != nil ? "VPN 앱으로 VPN 옮기기" : "RemoteDebug 업데이트 순서 보기"))
                    }
                }
                if let install {
                    InstallStatusView(build: build, state: install, actions: actions)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("앱 업데이트")
        } footer: {
            if pair.survivesSelfUpdate {
                Text("다른 앱이 VPN을 켜 두어서, 설치하는 동안에도 연결이 유지됩니다.")
            } else if pair.installed != nil {
                Text("이 앱의 VPN은 설치하는 동안 꺼집니다. VPN 앱으로 옮긴 뒤 돌아와 업데이트하세요.")
            } else {
                Text("이 앱은 설치하는 동안 VPN이 꺼져 자기 VPN으로는 업데이트할 수 없습니다. RD VPN 앱을 설치해 VPN을 맡기거나, 공식 Tailscale로 Mac의 업데이트 페이지를 엽니다.")
            }
        }
        .sheet(isPresented: $showsGuide) {
            NavigationStack {
                SelfUpdateGuide(pageURL: updatePage, open: actions.openInstallPage)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("닫기") { showsGuide = false }
                        }
                    }
            }
        }
    }
}

/// 빌드 하나: 이름·버전·크기와 설치 상태.
struct BuildRow: View {
    var build: BuildDescriptor
    var install: InstallState?
    var actions: PhoneActions
    /// 같은 앱의 이전 빌드. 타일과 이름을 빼고 게시 시각으로 구분한다.
    var isOlder = false
    /// 이 iPhone에 설치된 같은 앱의 버전. 읽지 못했으면 `nil`.
    var installed: InstalledApp?
    @Environment(\.crashPanel) private var crashPanel
    @State private var showsCrashes = false

    private var crashCount: Int {
        crashPanel?.state.crashes.count { $0.bundleId == build.bundleId } ?? 0
    }

    private var isInstalledBuild: Bool {
        installed?.version == build.version && installed?.buildNumber == build.buildNumber
    }

    private var installTitle: String {
        guard installed != nil else { return "설치" }
        return isInstalledBuild ? "다시 설치" : (isOlder ? "설치" : "업데이트")
    }

    private var published: String { build.publishedAt.formatted(date: .abbreviated, time: .shortened) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                if isOlder {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(published) 게시").font(.subheadline.weight(.medium))
                        Text("버전 \(build.version) (\(build.buildNumber)) · \(Self.size(build.ipa.size))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    PhoneBuildIcon(build: build)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(build.displayName).font(.headline)
                        Text("버전 \(build.version) (\(build.buildNumber)) · \(Self.size(build.ipa.size))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(build.bundleId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if install == nil {
                    Button { actions.install(build) } label: {
                        Label(installTitle, systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel(isOlder ? "\(build.displayName) \(published) 빌드 \(installTitle)" : "\(build.displayName) \(installTitle)")
                }
            }
            if let installed {
                if isInstalledBuild {
                    Label("이 빌드가 설치되어 있습니다", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else if !isOlder {
                    Label("설치된 버전 \(installed.version) (\(installed.buildNumber))", systemImage: "iphone")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if installed != nil, !isOlder, crashPanel != nil {
                Button {
                    showsCrashes = true
                } label: {
                    Label(crashCount == 0 ? "크래시 기록" : "크래시 기록 \(crashCount)개", systemImage: "waveform.path.ecg")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(build.displayName) 크래시 기록")
            }
            if build.signing.profileExpires < .now {
                Label("프로비저닝 프로파일이 \(build.signing.profileExpires.formatted(date: .abbreviated, time: .omitted))에 만료되었습니다. 설치해도 실행되지 않을 수 있습니다.", systemImage: "calendar.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let install {
                InstallStatusView(build: build, state: install, actions: actions)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showsCrashes) {
            if let crashPanel { AppCrashSheet(app: build, panel: crashPanel) }
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct InstallStatusView: View {
    var build: BuildDescriptor
    var state: InstallState
    var actions: PhoneActions

    var body: some View {
        switch state {
        case .preparing:
            progressLine("Mac이 빌드를 확인하는 중")
        case .waitingForInstaller:
            VStack(alignment: .leading, spacing: 6) {
                progressLine("iOS 설치 창에서 ‘설치’를 누르세요")
                HStack(spacing: 16) {
                    Button("다시 열기") { Task { await actions.reopenInstaller(build.id) } }
                        .accessibilityLabel("\(build.displayName) 설치 창 다시 열기")
                    Button("취소") { actions.cancelInstall(build.id) }
                        .accessibilityLabel("\(build.displayName) 설치 취소")
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
        case .transferring(let served, let size):
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = state.fraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel("전송")
                        .accessibilityValue("\(Int(fraction * 100))%")
                    Text("전송 중 \(BuildRow.size(served)) / \(BuildRow.size(size))")
                } else {
                    ProgressView()
                    Text("전송 중 \(BuildRow.size(served))")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .completed:
            VStack(alignment: .leading, spacing: 6) {
                Label("전송 완료", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.bold())
                Text("Mac이 빌드를 모두 보냈습니다. 설치 진행은 홈 화면의 앱 아이콘에서 확인하세요.")
                    .font(.footnote)
                Label(InstallState.developerModeHint, systemImage: "hammer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("확인") { actions.clearInstall(build.id) }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        case .expired, .failed:
            VStack(alignment: .leading, spacing: 6) {
                Label(state.message ?? "", systemImage: state == .expired ? "clock.badge.exclamationmark" : "xmark.octagon.fill")
                    .foregroundStyle(state == .expired ? .orange : .red)
                    .font(.footnote)
                HStack(spacing: 16) {
                    Button("다시 설치") { actions.install(build) }
                        .buttonStyle(.bordered)
                    Button("닫기") { actions.clearInstall(build.id) }
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
        }
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
