import AppKit
import MacHostKit
import RDModels
import SwiftUI

struct DevicesView: View {
    @Environment(HostModel.self) private var model
    @Environment(\.showPairing) private var showPairing
    @Environment(\.showPhoneInstall) private var showPhoneInstall
    @State private var deviceToRemove: DeviceEntry?
    @State private var confirmingForget = false

    private var pairingReason: String? {
        if case .unavailable(let reason) = model.pairingAvailability { return reason }
        return nil
    }

    /// 페어링 시트를 열 수 있는지.
    static func pairingEntryEnabled(_ model: HostModel) -> Bool {
        model.pairingAvailability == .ready
    }

    var body: some View {
        Group {
            if model.devices.isEmpty && model.pendingPairRequests.isEmpty {
                ContentUnavailableView {
                    Label("페어링한 기기 없음", systemImage: "iphone.slash")
                } description: {
                    if !model.isRunning {
                        Text("공유를 시작한 뒤 iPhone을 페어링하세요.")
                    } else if let reason = pairingReason {
                        Text(reason)
                    } else {
                        Text("iPhone을 페어링하면 이 Mac의 빌드를 설치할 수 있습니다.")
                    }
                } actions: {
                    if !model.isRunning {
                        SharingButton()
                    } else if pairingReason == nil {
                        Button("iPhone 페어링…") { showPairing() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        PairingRecoveryActions()
                    }
                }
            } else {
                List {
                    if model.deviceScopeConflict == nil, let reason = pairingReason {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(reason, systemImage: "wifi.exclamationmark")
                                    .fixedSize(horizontal: false, vertical: true)
                                PairingRecoveryActions()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if let conflict = model.deviceScopeConflict {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(conflict.message, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("기기 목록 지우기…") { confirmingForget = true }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if !model.pendingPairRequests.isEmpty {
                        Section("허용 대기") {
                            ForEach(model.pendingPairRequests, id: \.requestId) { request in
                                PairRequestRow(request: request)
                            }
                        }
                    }
                    Section(model.deviceScopeConflict == nil
                            ? "허용한 기기 \(model.devices.count)대"
                            : "다른 제어 서버에서 허용한 기기 \(model.devices.count)대") {
                        if model.devices.isEmpty {
                            Text("허용한 기기가 없습니다.").foregroundStyle(.secondary)
                        }
                        ForEach(model.devices) { device in
                            DeviceRow(device: device, path: model.status?.peerPaths?[device.nodeStableId]) { deviceToRemove = device }
                        }
                    }
                }
            }
        }
        .navigationTitle("기기")
        .toolbar {
            if let showPhoneInstall {
                Button { showPhoneInstall() } label: {
                    Label("iPhone 앱 설치…", systemImage: "iphone.and.arrow.forward")
                }
                .help("케이블로 연결한 iPhone에 RemoteDebug 앱을 빌드해 설치합니다")
            }
            Button { showPairing() } label: {
                Label("iPhone 페어링…", systemImage: "qrcode")
            }
            .disabled(!Self.pairingEntryEnabled(model))
            .help(pairingReason ?? String(localized: "페어링 코드를 만듭니다"))
        }
        .confirmationDialog(
            "기기를 제거할까요?",
            isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } }),
            presenting: deviceToRemove
        ) { device in
            Button("제거", role: .destructive) { Task { await model.removeDevice(device.id) } }
            Button("돌아가기", role: .cancel) {}
        } message: { device in
            Text("\(device.name)(\(device.nodeName)): 이 Mac의 빌드 목록과 설치에 접근할 수 없게 되고, 진행 중인 설치는 끊깁니다. 다시 쓰려면 새로 페어링해야 합니다.")
        }
        .confirmationDialog("기기 목록을 지울까요?", isPresented: $confirmingForget) {
            Button("기기 목록 지우기", role: .destructive) { model.forgetDevicesFromOtherServer() }
            Button("돌아가기", role: .cancel) {}
        } message: {
            Text("다른 제어 서버에서 페어링한 기기 \(model.devices.count)대를 지웁니다. 지금 제어 서버에서 iPhone을 새로 페어링해야 합니다.")
        }
    }
}

struct DeviceRow: View {
    let device: DeviceEntry

    /// 알림 등록 상태 문구.
    static func pushLabel(_ device: DeviceEntry) -> String {
        device.isPushRegistered ? String(localized: "알림 등록됨") : String(localized: "알림 없음")
    }
    /// 이 기기까지 가는 경로. 최근에 주고받은 것이 없으면 `nil`.
    var path: PeerPath?
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "iphone")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline)
                Text(device.nodeName)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !device.loginName.isEmpty {
                    Text(device.loginName).font(.callout).foregroundStyle(.secondary)
                }
                Text("등록 \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout)
                if device.isDirectEnrolled {
                    Label("같은 네트워크 직접 연결 등록됨", systemImage: "wifi")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Label(Self.pushLabel(device), systemImage: device.isPushRegistered ? "bell" : "bell.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let path {
                    Label(path.label, systemImage: path.direct ? "arrow.left.arrow.right" : "arrow.triangle.branch")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("연결 경로 \(path.label)")
                }
            }
            Spacer()
            Button("제거", action: remove)
                .accessibilityLabel("\(device.name) 제거")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// “‘내 iPhone’(rd-phone-ab12cd34)이 페어링을 요청했습니다” [허용] [거부]
struct PairRequestRow: View {
    @Environment(HostModel.self) private var model
    let request: PairRequestEvent

    var body: some View {
        let deciding = model.decidingRequestIDs.contains(request.requestId)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "iphone.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.sentence(request))
                    .font(.headline)
                if !request.loginName.isEmpty {
                    Text(request.loginName).font(.callout).foregroundStyle(.secondary)
                }
                Text("\(request.expiresAt.formatted(date: .omitted, time: .shortened))까지 응답하지 않으면 만료됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if deciding {
                ProgressView().controlSize(.small).accessibilityLabel("처리 중")
            }
            Button("거부") { Task { await model.deny(request.requestId) } }
                .disabled(deciding)
                .accessibilityLabel("\(Self.displayName(request)) 페어링 거부")
            Button("허용") { Task { await model.approve(request.requestId) } }
                .buttonStyle(.borderedProminent)
                .disabled(deciding)
                .accessibilityLabel("\(Self.displayName(request)) 페어링 허용")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    /// 요청한 기기 이름. 비어 있으면 `이름 없는 기기`.
    /// 값만 다루는 함수라 메인 액터에 묶지 않는다(View 구조체의 격리를 물려받지 않게 한다).
    nonisolated static func displayName(_ r: PairRequestEvent) -> String {
        r.deviceName.isEmpty ? String(localized: "이름 없는 기기") : r.deviceName
    }

    nonisolated static func sentence(_ r: PairRequestEvent) -> String {
        let name = displayName(r)
        let node = r.nodeName.isEmpty ? "" : "(\(r.nodeName))"
        // 조사(이/가)는 한국어 문장에서만 고른다. 다른 언어는 두 키를 같은 문장으로 옮긴다.
        return Korean.endsWithConsonant(name)
            ? String(localized: "‘\(name)’\(node)이 페어링을 요청했습니다")
            : String(localized: "‘\(name)’\(node)가 페어링을 요청했습니다")
    }
}

/// 페어링할 수 없을 때 그 이유를 풀 행동.
enum PairingRecovery: Sendable, Hashable {
    case startSharing
    case openLoginPage
    case openDNSSettings
    case openNetworkScreen

    @MainActor
    static func make(for model: HostModel) -> PairingRecovery {
        guard model.isRunning else { return .startSharing }
        if model.deviceScopeConflict != nil { return .openNetworkScreen }
        let guidance = model.guidance
        if guidance.action == .openLoginPage { return .openLoginPage }
        if guidance.kind == .certificatesDisabled || guidance.kind == .magicDNSDisabled { return .openDNSSettings }
        if guidance.kind == .ready, model.status?.fqdn.isEmpty == true { return .openDNSSettings }
        return .openNetworkScreen
    }
}

/// 페어링할 수 없는 이유 옆에 두는 버튼. `beforeNavigate`는 다른 화면으로 가기 전에 부른다(시트를 닫는다).
struct PairingRecoveryActions: View {
    @Environment(HostModel.self) private var model
    @Environment(\.showNetwork) private var showNetwork
    var beforeNavigate: () -> Void = {}

    var body: some View {
        switch PairingRecovery.make(for: model) {
        case .startSharing:
            SharingButton()
        case .openLoginPage:
            Button("로그인 페이지 열기") { model.openLoginPage() }
                .buttonStyle(.borderedProminent)
        case .openDNSSettings:
            if let url = URL(string: StatusGuidance.dnsConsoleURL) {
                Button("DNS 설정 페이지 열기") { NSWorkspace.shared.open(url) }
            }
        case .openNetworkScreen:
            Button("네트워크 화면 열기") {
                beforeNavigate()
                showNetwork()
            }
        }
    }
}

enum Korean {
    /// 이름 뒤에 붙일 주격 조사(이/가).
    static func subjectParticle(after word: String) -> String {
        endsWithConsonant(word) ? "이" : "가"
    }

    /// 목적격 조사(을/를).
    static func objectParticle(after word: String) -> String {
        endsWithConsonant(word) ? "을" : "를"
    }

    /// 마지막 글자가 받침으로 끝나는지. 한글은 받침으로, 숫자는 읽는 소리로 정하고 그 밖(영문 등)은 받침이 있다고 본다.
    static func endsWithConsonant(_ word: String) -> Bool {
        guard let last = word.trimmingCharacters(in: .whitespaces).unicodeScalars.last else { return true }
        let v = last.value
        if (0xAC00...0xD7A3).contains(v) { return (v - 0xAC00) % 28 != 0 }
        if let digit = Int(String(last)) { return ![2, 4, 5, 9].contains(digit) }
        return true
    }
}
