import PhoneClientKit
import RDModels
import SwiftUI

/// 빌드 한 줄의 설치 동작. RemoteDebug 앱과 업데이트 앱이 함께 쓴다.
@MainActor
struct InstallActions {
    var install: (BuildDescriptor) -> Void
    var clearInstall: (_ buildID: String) -> Void
    /// 같은 설치 세션의 iOS 설치 창을 다시 연다.
    var reopenInstaller: @MainActor @Sendable (_ buildID: String) async -> Void
    /// iOS 설치기를 기다리는 설치를 그만둔다.
    var cancelInstall: (_ buildID: String) -> Void
}

/// 설치를 시작하기 전 단계(VPN을 이 앱으로 옮기기).
enum InstallPreparation: Equatable {
    /// 진행 중인 단계의 안내.
    case working(String)
    /// 설치를 시작하지 못한 이유.
    case failed(String)
}

/// 빌드 하나: 이름·버전·크기와 설치 상태.
struct BuildRow: View {
    var build: BuildDescriptor
    var install: InstallState?
    var actions: InstallActions
    /// 같은 앱의 이전 빌드. 타일과 이름을 빼고 게시 시각으로 구분한다.
    var isOlder = false
    /// 이 iPhone에 설치된 같은 앱의 버전. 읽지 못했으면 `nil`.
    var installed: InstalledApp?
    var preparation: InstallPreparation?
    /// 설치된 버전 아래에 더 보여 줄 것(크래시 기록 버튼 등).
    var accessory: AnyView?

    private var isInstalledBuild: Bool {
        installed?.version == build.version && installed?.buildNumber == build.buildNumber
    }

    private var installTitle: String {
        guard installed != nil else { return "설치" }
        return isInstalledBuild ? "다시 설치" : (isOlder ? "설치" : "업데이트")
    }

    private var published: String { build.publishedAt.formatted(date: .abbreviated, time: .shortened) }

    private var isPreparing: Bool {
        if case .working = preparation { return true }
        return false
    }

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
                if install == nil, !isPreparing {
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
            if let accessory { accessory }
            if build.signing.profileExpires < .now {
                Label("프로비저닝 프로파일이 \(build.signing.profileExpires.formatted(date: .abbreviated, time: .omitted))에 만료되었습니다. 설치해도 실행되지 않을 수 있습니다.", systemImage: "calendar.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            switch preparation {
            case .working(let text):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            case .failed(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
            if let install {
                InstallStatusView(build: build, state: install, actions: actions)
            }
        }
        .padding(.vertical, 4)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct InstallStatusView: View {
    var build: BuildDescriptor
    var state: InstallState
    var actions: InstallActions

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
