import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MacHostKit
import RDModels
import SwiftUI

/// 페어링 코드 → (iPhone이 코드를 씀) → 허용 요청 → 결과. iPhone이 이 Mac에 닿을 수 없으면 코드 대신 그 이유와 다음 행동을 보인다.
struct PairingSheet: View {
    @Environment(HostModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var creating = false
    @State private var hadCode = false
    @State private var lastRequest: PairRequestEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iPhone 페어링").font(.title2.bold())
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            if let failure = Self.failureText(model) {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if showsNewCodeButton {
                    Button("새 코드 만들기") { Task { await createCode() } }
                        .disabled(creating || !isReady)
                }
                Spacer()
                Button(isFinished ? "완료" : "닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { model.clearPairingError() }
        .task {
            // 만료된 코드·요청을 내린다(카운트다운이 0이 되면 상태가 바뀐다).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.pruneExpiredPairRequests()
            }
        }
        .task(id: isReady) {
            // 시트를 열 때, 또는 연 뒤 이 Mac에 닿을 수 있게 되면 코드를 만든다(만료된 코드는 다시 만들지 않는다).
            if isReady, model.pairingCode == nil, !isWaitingForDecision, lastRequest == nil, !hadCode { await createCode() }
        }
        .onChange(of: model.pairingState, initial: true) { _, state in
            if case .requestReceived(let id) = state, let request = model.pairRequests.first(where: { $0.requestId == id }) {
                lastRequest = request
            }
            if case .open = state { hadCode = true }
        }
    }

    /// 시트 안에 보여 줄 실패 이유. 창의 오류 표시는 시트에 가리므로 코드 만들기·허용·거부 실패는 여기서 보여 준다.
    static func failureText(_ model: HostModel) -> String? { model.pairingError }

    /// 설치 페이지 링크(지금 코드 포함). 있을 때만 "앱 없이 Safari로 설치" 부분을 보인다.
    static func installPageLink(_ model: HostModel) -> URL? { model.installPageLink }

    private var isReady: Bool { model.pairingAvailability == .ready }

    private var isWaitingForDecision: Bool {
        if case .requestReceived = model.pairingState { return true }
        return false
    }

    private var isFinished: Bool {
        if case .idle = model.pairingState, lastRequest != nil, !creating { return true }
        return false
    }

    private var showsNewCodeButton: Bool {
        if case .requestReceived = model.pairingState { return false }
        return true
    }

    @ViewBuilder private var content: some View {
        if case .unavailable(let reason) = model.pairingAvailability, !isWaitingForDecision, lastRequest == nil {
            UnreachablePanel(reason: reason)
        } else if creating {
            HStack { ProgressView().controlSize(.small); Text("코드를 만드는 중…") }
        } else if let code = model.pairingCode {
            if let page = Self.installPageLink(model) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("RemoteDebug 앱으로 페어링", systemImage: "iphone").font(.headline)
                    CodePanel(code: code, link: model.pairingLink)
                    PairingKeyNote(dismiss: { dismiss() })
                    Divider().padding(.vertical, 4)
                    Label(BrowserInstallPanel.heading, systemImage: "safari").font(.headline)
                    BrowserInstallPanel(link: page)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    CodePanel(code: code, link: model.pairingLink)
                    PairingKeyNote(dismiss: { dismiss() })
                }
            }
        } else if case .requestReceived(let id) = model.pairingState {
            VStack(alignment: .leading, spacing: 8) {
                Text("코드가 쓰였습니다. 요청한 기기가 맞는지 확인하고 응답하세요.")
                if let request = model.pairRequests.first(where: { $0.requestId == id }) {
                    PairRequestRow(request: request)
                }
            }
        } else if let request = lastRequest {
            ResultPanel(request: request)
        } else if hadCode {
            Label("코드가 만료됐거나 틀린 시도가 많아 더 쓸 수 없습니다. 새 코드를 만드세요.", systemImage: "clock.badge.xmark")
        } else if Self.failureText(model) == nil {
            Label("코드를 만들지 못했습니다. 다시 시도하세요.", systemImage: "exclamationmark.triangle")
        }
    }

    private func createCode() async {
        creating = true
        lastRequest = nil
        await model.beginPairing()
        creating = false
    }
}

/// iPhone이 이 Mac에 닿을 수 없는 이유와, 고칠 수 있는 화면으로 가는 버튼.
private struct UnreachablePanel: View {
    @Environment(\.dismiss) private var dismiss
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(reason, systemImage: "wifi.exclamationmark")
                .fixedSize(horizontal: false, vertical: true)
            PairingRecoveryActions(beforeNavigate: { dismiss() })
        }
    }
}

private struct CodePanel: View {
    @Environment(\.linkCopier) private var copier
    let code: PairingCode
    let link: URL?
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            if let link {
                QRCodeView(text: link.absoluteString)
                    .frame(width: 160, height: 160)
                    .accessibilityLabel("페어링 QR 코드")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("iPhone의 RemoteDebug에서 QR을 찍거나 코드를 입력하세요.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(code.displayCode)
                    .font(.largeTitle.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityLabel("페어링 코드 \(code.displayCode.map(String.init).joined(separator: " "))")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(code.expiresAt.timeIntervalSince(context.date).rounded(.down)))
                    Text("남은 시간 \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                        .monospacedDigit()
                        .foregroundStyle(remaining < 60 ? .orange : .secondary)
                }
                if let link {
                    Button {
                        copier.copy(link, announcement: nil)
                        copied = true
                    } label: {
                        Label(copied ? "링크 복사됨" : "페어링 링크 복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help(link.absoluteString)
                } else {
                    Text("Mac의 tailnet 주소를 아직 받지 못해 QR과 링크를 만들 수 없습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("코드는 한 번만 쓸 수 있고, 이 Mac에서 허용해야 페어링이 끝납니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// RemoteDebug 앱이 없는 iPhone이 Safari로 여는 설치 페이지. 링크에 지금 코드가 들어 있다.
struct BrowserInstallPanel: View {
    let link: URL

    static let heading = "앱 없이 Safari로 설치"
    static let copyTitle = "링크 복사"
    static let copyAnnouncement = "설치 페이지 링크를 복사했습니다."
    static let facts = "iPhone의 Tailscale 앱이 이 Mac과 같은 tailnet에 로그인되어 있고 VPN이 켜져 있어야 열립니다. 링크에는 위와 같은 코드가 들어 있습니다. 요청이 오면 이 Mac에서 허용하거나 거부하세요."

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            QRCodeView(text: link.absoluteString)
                .frame(width: 160, height: 160)
                .accessibilityLabel("설치 페이지 QR 코드")
            VStack(alignment: .leading, spacing: 10) {
                Text("iPhone 카메라로 QR을 찍거나 Safari에서 링크를 여세요.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(link.absoluteString)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                CopyLinkButton(url: link, title: Self.copyTitle, announcement: Self.copyAnnouncement)
                Text(Self.facts)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ResultPanel: View {
    @Environment(HostModel.self) private var model
    let request: PairRequestEvent

    var body: some View {
        let result = PairingResult.make(
            outcome: model.lastPairingOutcome?.requestId == request.requestId ? model.lastPairingOutcome?.kind : nil,
            request: request,
            alreadyAllowed: model.devices.contains { $0.nodeName == request.nodeName },
            now: Date())
        Label(result.text, systemImage: result.symbol)
            .foregroundStyle(result.succeeded ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 끝난 페어링 요청을 보여 줄 문장. 결과는 그 요청의 결정으로만 정한다.
struct PairingResult: Sendable, Hashable {
    var text: String
    var symbol: String
    var succeeded = false

    static func make(outcome: PairingOutcome.Kind?, request: PairRequestEvent, alreadyAllowed: Bool, now: Date) -> PairingResult {
        let name = PairRequestRow.displayName(request)
        switch outcome ?? (request.expiresAt <= now ? .expired : nil) {
        case .allowed:
            return PairingResult(text: "\(name)\(Korean.objectParticle(after: name)) 허용 목록에 추가했습니다.",
                                 symbol: "checkmark.circle.fill", succeeded: true)
        case .denied:
            let keeps = alreadyAllowed ? " 이미 허용한 기기라 기존 접근은 그대로입니다. 접근을 끊으려면 기기 목록에서 제거하세요." : ""
            return PairingResult(text: "\(name)의 페어링 요청을 거부했습니다.\(keeps)", symbol: "xmark.circle")
        case .expired:
            return PairingResult(text: "요청이 만료됐습니다. 새 코드를 만들어 iPhone에서 다시 요청하세요.", symbol: "clock.badge.xmark")
        case .notAdded:
            return PairingResult(text: "제어 서버가 바뀌어 \(name)\(Korean.objectParticle(after: name)) 추가하지 않았습니다. 지금 서버에서 새 코드로 다시 페어링하세요.",
                                 symbol: "exclamationmark.triangle")
        case nil:
            return PairingResult(text: "요청이 끝났지만 기기가 추가되지 않았습니다. 새 코드로 다시 시도하세요.", symbol: "exclamationmark.triangle")
        }
    }
}

/// CoreImage로 만든 QR 코드. 스캐너가 읽을 수 있게 밝은 바탕에 어두운 점으로 그린다.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.makeImage(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "qrcode")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    static func makeImage(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(scaled, from: scaled.extent)
    }
}
