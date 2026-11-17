import PhoneClientKit
import SwiftUI

/// QR 스캔 버튼. 페어링은 QR과 Mac이 보낸 링크로만 시작한다.
struct PairingForm: View {
    var handleScanned: (_ text: String) -> String?
    /// 페어링을 시작한 뒤(시트를 닫을 때) 부른다.
    var onSubmit: () -> Void
    /// `true`면 눈에 띄는 버튼으로 보인다(페어링 전 첫 화면).
    var isPrimary = false

    @State private var showsScanner = false

    var body: some View {
        scanButton
            .sheet(isPresented: $showsScanner) {
                QRScannerSheet(handleScanned: handleScanned) {
                    showsScanner = false
                    onSubmit()
                }
            }
    }

    @ViewBuilder private var scanButton: some View {
        let label = Label("QR 코드 스캔", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity, alignment: isPrimary ? .center : .leading)
        if isPrimary {
            Button { showsScanner = true } label: { label }
                .bold()
                .buttonStyle(.borderedProminent)
        } else {
            Button { showsScanner = true } label: { label }
                .bold()
        }
    }
}

/// VPN 대기·Mac에 연결 중·승인 대기.
struct PairingProgressSection: View {
    var state: PhoneViewState
    var cancel: () -> Void
    var takeOverVPN: @MainActor @Sendable () async -> Void = {}

    var body: some View {
        if let queued = state.queuedPairingHost {
            Section("페어링 대기") {
                Label {
                    Text("VPN이 연결되면 \(queued)에 페어링을 요청합니다.")
                } icon: {
                    Image(systemName: "clock")
                }
                // 페어링은 이 앱의 터널로만 맺는다. 다른 VPN(공식 Tailscale 앱 등)이 켜져 있거나,
                // 다른 VPN 구성이 선택돼 있어 저절로 켜지지 않을 때 사용자가 켠다.
                Button(state.vpnPair.owner == .other ? "이 앱으로 VPN 가져오기" : "VPN 켜기") { Task { await takeOverVPN() } }
                    .bold()
                Button("페어링 취소", role: .destructive, action: cancel)
            }
        } else {
            switch state.phase {
            case .requestingPairing:
                Section("페어링") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Mac에 연결하는 중")
                        }
                        Text("방금 연결한 VPN은 Mac에 닿기까지 최대 1분 걸릴 수 있습니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Button("페어링 취소", role: .destructive, action: cancel)
                }
            case .waitingApproval(let deviceName):
                Section("페어링") {
                    if let code = state.confirmationCode {
                        ConfirmationCodeView(code: code)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Mac의 승인을 기다리는 중").font(.headline)
                        }
                        Text("Mac 화면의 숫자와 같은지 확인하고, 같으면 Mac 앱에서 ‘\(deviceName)’의 페어링을 승인하세요. 다르면 취소하세요.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    if let expiresAt = state.pairingExpiresAt {
                        PairingCountdown(expiresAt: expiresAt)
                    }
                    Button("페어링 취소", role: .destructive, action: cancel)
                }
            case .unpaired, .paired:
                EmptyView()
            }
        }
    }
}

/// Mac 화면의 숫자와 견주는 확인 숫자(6자리). 세 자리씩 끊어 크게 보인다.
struct ConfirmationCodeView: View {
    var code: String

    var body: some View {
        VStack(spacing: 4) {
            Text("확인 숫자")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Self.grouped(code))
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("확인 숫자 \(code.map(String.init).joined(separator: " "))")
    }

    /// `482915` → `482 915`.
    static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }
}

/// 승인 대기 마감까지 남은 시간.
struct PairingCountdown: View {
    var expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded(.up)))
            LabeledContent("남은 시간") {
                Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                    .monospacedDigit()
                    .foregroundStyle(remaining <= 30 ? .orange : .secondary)
            }
            .accessibilityLabel("남은 시간 \(remaining / 60)분 \(remaining % 60)초")
        }
    }
}
