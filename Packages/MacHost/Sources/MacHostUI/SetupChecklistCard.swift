import AppKit
import MacHostKit
import SwiftUI

/// 빌드 화면 위의 시작 순서. 네 단계를 다 마치면 사라진다. "나중에"를 누르면 숨긴다.
struct SetupChecklistCard: View {
    @Environment(HostModel.self) private var model
    @Environment(\.showPairing) private var showPairing
    @Environment(\.showNetwork) private var showNetwork
    @Environment(\.showPhoneInstall) private var showPhoneInstall
    @AppStorage("setupChecklistHidden") private var hidden = false
    let showImporter: () -> Void

    private var checklist: SetupChecklist {
        SetupChecklist.make(guidance: model.guidance, fqdn: model.status?.fqdn, devices: model.devices.count, builds: model.builds.count)
    }

    var body: some View {
        let list = checklist
        if !hidden && !list.isComplete {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("시작하기", systemImage: "flag.checkered")
                        .font(.headline)
                    Text("\(list.doneCount)/\(list.items.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("나중에") { hidden = true }
                        .buttonStyle(.link)
                        .help("시작하기 목록을 숨깁니다")
                }
                ForEach(list.items) { item in
                    row(item)
                }
            }
            .rdCardSurface()
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("시작하기 \(list.doneCount)/\(list.items.count) 완료")
        }
    }

    private func row(_ item: SetupChecklist.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(item.state))
                .foregroundStyle(item.state == .done ? .green : item.state == .current ? RDTheme.tint : .secondary)
                .font(.title3)
                .frame(width: 22)
                .accessibilityLabel(item.state == .done ? "완료" : item.state == .current ? "지금 할 일" : "남은 일")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(item.state == .current ? .semibold : .regular))
                    .foregroundStyle(item.state == .later ? .secondary : .primary)
                if item.state != .later {
                    Text(item.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if item.state == .current {
                    actions(item.step)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func symbol(_ state: SetupChecklist.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .current: "arrow.right.circle.fill"
        case .later: "circle"
        }
    }

    @ViewBuilder private func actions(_ step: SetupChecklist.Step) -> some View {
        HStack {
            switch step {
            case .tailnet:
                switch model.guidance.action {
                case .start: SharingButton()
                case .openLoginPage:
                    Button("로그인 페이지 열기") { model.openLoginPage() }
                        .buttonStyle(.borderedProminent)
                case .restart: RestartSharingButton()
                case nil: EmptyView()
                }
                Button("네트워크 화면") { showNetwork() }
            case .address:
                if model.guidance.kind == .certificatesDisabled || model.guidance.kind == .magicDNSDisabled,
                   let url = URL(string: StatusGuidance.dnsConsoleURL) {
                    Button("DNS 설정 페이지 열기") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderedProminent)
                }
                Button("네트워크 화면") { showNetwork() }
            case .iphone:
                if let showPhoneInstall {
                    Button("iPhone 앱 설치…") { showPhoneInstall() }
                }
                Button("iPhone 페어링…") { showPairing() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.pairingAvailability != .ready)
            case .build:
                Button("빌드 가져오기…", action: showImporter)
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
    }
}
