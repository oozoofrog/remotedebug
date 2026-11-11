import PhoneClientKit
import SwiftUI

/// QR 스캔 버튼과 직접 입력(Mac 주소 + 코드).
struct PairingForm: View {
    var pair: (_ host: String, _ code: String) -> Void
    var handleScanned: (_ text: String) -> String?
    /// 페어링을 시작한 뒤(시트를 닫을 때) 부른다.
    var onSubmit: () -> Void

    @State private var host = ""
    @State private var code = ""
    @State private var showsScanner = false
    @FocusState private var focus: Field?

    private enum Field { case host, code }

    var body: some View {
        Button {
            showsScanner = true
        } label: {
            Label("QR 코드 스캔", systemImage: "qrcode.viewfinder")
        }
        .bold()

        TextField("Mac 주소 (예: my-mac.example.ts.net)", text: $host)
            .textContentType(.URL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: .host)
            .submitLabel(.next)
            .onSubmit { focus = .code }
            .accessibilityLabel("Mac 주소")

        TextField("페어링 코드 8자", text: $code)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(.body.monospaced())
            .focused($focus, equals: .code)
            .submitLabel(.go)
            .onSubmit(submit)
            .accessibilityLabel("페어링 코드")

        Button("페어링 요청", action: submit)
            .disabled(!canSubmit)
        .sheet(isPresented: $showsScanner) {
            QRScannerSheet(handleScanned: handleScanned) {
                showsScanner = false
                onSubmit()
            }
        }
    }

    private var canSubmit: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !code.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        pair(host, code)
        code = ""
        onSubmit()
    }
}

/// VPN 대기·요청 중·승인 대기.
struct PairingProgressSection: View {
    var state: PhoneViewState
    var cancel: () -> Void

    var body: some View {
        if let queued = state.queuedPairingHost {
            Section("페어링 대기") {
                Label {
                    Text("VPN이 연결되면 \(queued)에 페어링을 요청합니다.")
                } icon: {
                    Image(systemName: "clock")
                }
                Button("페어링 취소", role: .destructive, action: cancel)
            }
        } else {
            switch state.phase {
            case .requestingPairing:
                Section("페어링") {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("페어링 요청을 보내는 중")
                    }
                    .accessibilityElement(children: .combine)
                    Button("페어링 취소", role: .destructive, action: cancel)
                }
            case .waitingApproval(let deviceName):
                Section("페어링") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Mac의 승인을 기다리는 중").font(.headline)
                        }
                        Text("Mac 앱에서 ‘\(deviceName)’의 페어링 요청을 승인하세요.")
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
