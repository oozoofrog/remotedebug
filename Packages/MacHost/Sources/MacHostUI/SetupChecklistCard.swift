import AppKit
import MacHostKit
import SwiftUI

/// 앱 화면 위의 시작 순서. 네 단계를 다 마치면 사라진다. "나중에"를 누르면 숨긴다.
/// 도움말 메뉴의 "시작하기 보기"로 다시 연다(다 마친 뒤에도 연다).
struct SetupChecklistCard: View {
    @Environment(HostModel.self) private var model
    @Environment(\.showPairing) private var showPairing
    @Environment(\.showNetwork) private var showNetwork
    @Environment(\.showPhoneInstall) private var showPhoneInstall
    @AppStorage(SetupChecklistCard.hiddenKey) private var hidden = false
    @AppStorage(SetupChecklistCard.reopenedKey) private var reopened = false
    let showImporter: () -> Void
    var addProject: () -> Void = {}

    static let hiddenKey = "setupChecklistHidden"
    /// 도움말 메뉴에서 다시 열었다. 다 마친 목록도 닫을 때까지 보인다.
    static let reopenedKey = "setupChecklistReopened"

    /// 도움말 메뉴의 "시작하기 보기": 숨긴 카드를 다시 보이게 한다.
    static func reopen(_ defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: hiddenKey)
        defaults.set(true, forKey: reopenedKey)
    }

    /// 카드를 보일지: 숨기지 않았고, 남은 단계가 있거나 다시 열었다.
    static func isShown(_ list: SetupChecklist, hidden: Bool, reopened: Bool) -> Bool {
        !hidden && (!list.isComplete || reopened)
    }

    /// 카드가 보이고 지금 할 일이 공유 연결 단계라 공유 문제와 그 버튼을 카드가 이미 보여 준다.
    @MainActor
    static func coversSharing(_ model: HostModel, hidden: Bool) -> Bool {
        guard !hidden else { return false }
        let list = SetupChecklist.make(guidance: model.guidance, fqdn: model.status?.fqdn, devices: model.devices.count, builds: model.builds.count)
        guard let current = list.current else { return false }
        return current.step == .tailnet || current.step == .address
    }

    private var checklist: SetupChecklist {
        SetupChecklist.make(guidance: model.guidance, fqdn: model.status?.fqdn, devices: model.devices.count, builds: model.builds.count)
    }

    var body: some View {
        let list = checklist
        if Self.isShown(list, hidden: hidden, reopened: reopened) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("시작하기", systemImage: "flag.checkered")
                        .font(.headline)
                    Text("\(list.doneCount)/\(list.items.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(list.isComplete ? "닫기" : "나중에") {
                        hidden = true
                        reopened = false
                    }
                    .buttonStyle(.link)
                    .help("시작하기 목록을 숨깁니다. 도움말 메뉴의 ‘시작하기 보기’로 다시 엽니다.")
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
                    if item.substeps.isEmpty {
                        actions(item.step)
                            .padding(.top, 2)
                    } else {
                        substeps(item.substeps)
                            .padding(.top, 2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 번호를 붙인 하위 단계와 그 단계의 버튼.
    private func substeps(_ steps: [SetupChecklist.Substep]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(step.id).")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if let action = step.action {
                            substepAction(action)
                                .controlSize(.small)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(step.id)단계")
            }
        }
    }

    @ViewBuilder private func substepAction(_ action: SetupChecklist.SubstepAction) -> some View {
        switch action {
        case .installPhoneApp:
            if let showPhoneInstall {
                Button("iPhone 앱 설치…") { showPhoneInstall() }
            }
        case .pair:
            Button("iPhone 페어링…") { showPairing() }
                .buttonStyle(.borderedProminent)
                .disabled(model.pairingAvailability != .ready)
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
                // 하위 단계마다 버튼이 붙는다.
                EmptyView()
            case .build:
                Button("프로젝트 추가…", action: addProject)
                    .buttonStyle(.borderedProminent)
                Button("빌드 가져오기…", action: showImporter)
            }
        }
        .controlSize(.small)
    }
}
