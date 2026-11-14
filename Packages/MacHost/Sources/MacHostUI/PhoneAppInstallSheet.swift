import AppKit
import MacHostKit
import SwiftUI

/// 케이블로 연결한 iPhone에 RemoteDebug iPhone 앱을 빌드해 설치한다. 팀만 고르면 Xcode가 기기 등록과 서명을 한다.
struct PhoneAppInstallSheet: View {
    @Environment(PhoneAppInstaller.self) private var installer
    @Environment(\.dismiss) private var dismiss
    @State private var choosingSource = false

    var body: some View {
        @Bindable var installer = installer
        VStack(alignment: .leading, spacing: 16) {
            Text("iPhone 앱 설치").font(.title2.bold())
            Text("iPhone을 케이블로 연결하고 잠금을 푼 뒤 서명할 팀을 고르세요. Xcode가 그 iPhone을 팀에 등록하고 앱을 서명합니다.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                LabeledContent("소스") {
                    HStack {
                        Text(installer.sourceRoot?.path ?? String(localized: "선택하지 않음"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(installer.hasSource ? .primary : .secondary)
                            .help(installer.sourceRoot?.path ?? "")
                        Button("선택…") { choosingSource = true }
                    }
                }
                if !installer.hasSource {
                    Text("RemoteDebug.xcodeproj가 있는 RemoteDebug 저장소 폴더를 고르세요.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Picker("서명 팀", selection: $installer.team) {
                    if installer.teams.isEmpty { Text("팀 없음").tag("") }
                    ForEach(installer.teams) { team in
                        Text("\(team.name) (\(team.id))").tag(team.id)
                    }
                }
                if installer.teams.isEmpty && !installer.isRefreshing {
                    Text("Apple Development 인증서가 없습니다. Xcode > Settings > Accounts에서 Apple 계정을 추가하고 팀의 인증서를 만드세요.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("번들 ID 앞부분", text: Binding(get: { installer.bundlePrefix }, set: { installer.editPrefix($0) }))
                    .help("앱은 \(installer.phoneBundleID)가 됩니다. 이 팀에서 이미 쓰는 값이 아니면 그대로 두세요.")
                HStack {
                    Picker("iPhone", selection: $installer.phoneID) {
                        if installer.phoneID == nil || installer.phones.isEmpty { Text("연결한 iPhone 없음").tag(String?.none) }
                        ForEach(installer.phones) { phone in
                            Text(phone.reachable ? "\(phone.name) · iOS \(phone.osVersion)" : "\(phone.name) (연결 안 됨)")
                                .tag(Optional(phone.id))
                        }
                    }
                    Button {
                        Task { await installer.refresh() }
                    } label: {
                        Label("다시 찾기", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(installer.isRefreshing || installer.phase.isWorking)
                    .help("연결한 iPhone과 서명 팀을 다시 찾습니다")
                }
            }
            .formStyle(.grouped)
            .disabled(installer.phase.isWorking)

            if !installer.isRefreshing, !installer.phones.contains(where: { $0.id == installer.phoneID && $0.reachable }) {
                Label("iPhone을 케이블로 연결하고 잠금을 푼 뒤 '이 컴퓨터를 신뢰'를 허용하고 다시 찾기를 누르세요. 처음 연결한 iPhone은 개발자 모드도 켜야 합니다.", systemImage: "cable.connector")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            status

            HStack {
                Button("기록 보기") { NSWorkspace.shared.open(installer.logURL) }
                    .disabled(!FileManager.default.fileExists(atPath: installer.logURL.path))
                Spacer()
                Button(isFinished ? "완료" : "닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(installer.phase.isWorking)
                Button("설치") { Task { await installer.install() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!installer.canInstall)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task { await installer.refresh() }
        .fileImporter(isPresented: $choosingSource, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { installer.chooseSource(url) }
        }
    }

    private var isFinished: Bool {
        if case .done = installer.phase { return true }
        return false
    }

    @ViewBuilder private var status: some View {
        switch installer.phase {
        case .idle:
            EmptyView()
        case .building:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("빌드하는 중… 처음에는 몇 분 걸립니다.")
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("iPhone에 설치하는 중…")
            }
        case .done(let phone, let bundleID):
            Label("\(phone)에 설치하고 실행했습니다(\(bundleID)). iPhone 앱에서 VPN을 켜고 이 Mac과 같은 Tailscale 계정으로 로그인한 뒤 페어링 QR을 찍으세요. 앱이 열리지 않으면 설정 > 일반 > VPN 및 기기 관리에서 개발자를 신뢰하세요.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// iPhone 앱 설치 창을 여는 동작(창에 하나).
struct PhoneAppInstallPresenter {
    let open: () -> Void
    func callAsFunction() { open() }
}
