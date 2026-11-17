import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MacHostKit
import RDModels
import SwiftUI

/// iPhone 페어링. 사용자가 iPhone의 상황으로 동선을 고른다.
/// - 앱이 있는 iPhone: QR → 앱에서 읽기 → 확인 숫자 비교 → 이 Mac에서 허용.
/// - 앱이 아직 없는 iPhone: Safari로 설치 페이지 → 코드 → 이 Mac에서 허용 → 페이지에서 앱 설치 → 앱으로 다시 QR 페어링.
/// 코드·QR은 그 동선을 골랐을 때만 연다. iPhone이 이 Mac에 닿을 수 없으면 그 이유와 다음 행동을 보인다.
struct PairingSheet: View {
    @Environment(HostModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var route: HostModel.PairingRoute?
    @State private var opening = false
    /// 마지막으로 시작한 열기. 앞의 열기가 늦게 끝나도 진행 표시를 내리지 않는다.
    @State private var openingID = 0
    /// 이 동선에서 코드·QR을 한 번이라도 보였다(만료 안내에 쓴다).
    @State private var hadOpen = false
    @State private var lastRequest: PairRequestEvent?

    init(route: HostModel.PairingRoute? = nil) {
        _route = State(initialValue: route)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iPhone 페어링").font(.title2.bold())
            if route != nil, !isWaitingForDecision, lastRequest == nil, isReady {
                Picker("iPhone", selection: Binding(get: { route ?? .app }, set: { choose($0) })) {
                    Text(Self.routeTitle(.app)).tag(HostModel.PairingRoute.app)
                    Text(Self.routeTitle(.browser)).tag(HostModel.PairingRoute.browser)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            if let failure = Self.failureText(model) {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let route, showsRenewButton {
                    Button(route == .app ? String(localized: "새 QR 만들기") : String(localized: "새 코드 만들기")) { Task { await open(route) } }
                        .disabled(opening || model.isOpeningInvite || !isReady)
                }
                Spacer()
                Button(isFinished ? "완료" : "닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            model.clearPairingError()
            // 이미 열린 코드·QR이 있으면(에이전트가 연 설치 페이지 코드 등) 그 동선으로 보인다.
            if route == nil {
                if model.pairingCode != nil { route = .browser } else if model.openInvite != nil { route = .app }
            }
        }
        .task {
            // 만료된 코드·QR·요청을 내린다(카운트다운이 0이 되면 상태가 바뀐다).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.pruneExpiredPairRequests()
            }
        }
        .task(id: isReady) {
            // 동선을 고른 채 열었거나, 연 뒤 이 Mac에 닿을 수 있게 되면 그 동선을 연다(만료된 것은 다시 열지 않는다).
            if isReady, let route, !isShowing(route), !isWaitingForDecision, lastRequest == nil, !hadOpen { await open(route) }
        }
        .onChange(of: model.pairingState, initial: true) { _, state in
            if case .requestReceived(let id) = state, let request = model.pairRequests.first(where: { $0.requestId == id }) {
                lastRequest = request
            }
            switch state {
            case .open, .offerOpen: hadOpen = true
            default: break
            }
        }
    }

    static func routeTitle(_ route: HostModel.PairingRoute) -> String {
        switch route {
        case .app: String(localized: "RemoteDebug 앱이 있는 iPhone")
        case .browser: String(localized: "앱이 아직 없는 iPhone")
        }
    }

    /// 시트 안에 보여 줄 실패 이유. 창의 오류 표시는 시트에 가리므로 코드 만들기·허용·거부 실패는 여기서 보여 준다.
    static func failureText(_ model: HostModel) -> String? { model.pairingError }

    /// 설치 페이지 링크(지금 코드 포함). 앱이 없는 iPhone 동선에서만 쓴다.
    static func installPageLink(_ model: HostModel) -> URL? { model.installPageLink }

    private var isReady: Bool { model.pairingAvailability == .ready }

    private var isWaitingForDecision: Bool {
        if case .requestReceived = model.pairingState { return true }
        return false
    }

    private var isFinished: Bool {
        if case .idle = model.pairingState, lastRequest != nil, !opening { return true }
        return false
    }

    private var showsRenewButton: Bool {
        if case .requestReceived = model.pairingState { return false }
        return lastRequest == nil
    }

    private func isShowing(_ route: HostModel.PairingRoute) -> Bool {
        switch route {
        case .app: model.openInvite != nil
        case .browser: model.pairingCode != nil
        }
    }

    private func choose(_ next: HostModel.PairingRoute) {
        guard next != route else { return }
        route = next
        hadOpen = false
        Task { await open(next) }
    }

    @ViewBuilder private var content: some View {
        if case .unavailable(let reason) = model.pairingAvailability, !isWaitingForDecision, lastRequest == nil {
            UnreachablePanel(reason: reason)
        } else if case .requestReceived(let id) = model.pairingState {
            VStack(alignment: .leading, spacing: 8) {
                Text("요청한 iPhone이 맞는지 확인하고 응답하세요.")
                if let request = model.pairRequests.first(where: { $0.requestId == id }) {
                    PairRequestRow(request: request)
                }
            }
        } else if let request = lastRequest {
            ResultPanel(request: request)
        } else if let route {
            switch route {
            case .app: appContent
            case .browser: browserContent
            }
        } else {
            RouteChoice { choose($0) }
        }
    }

    @ViewBuilder private var appContent: some View {
        if opening || model.isOpeningInvite {
            VStack(alignment: .leading, spacing: 8) {
                HStack { ProgressView().controlSize(.small); Text("QR을 만드는 중…") }
                PairingKeyNote(dismiss: { dismiss() })
            }
        } else if let invite = model.openInvite {
            AppPairingPanel(invite: invite, dismiss: { dismiss() })
        } else if hadOpen {
            Label("QR이 만료됐습니다. 새 QR을 만드세요.", systemImage: "clock.badge.xmark")
        } else if Self.failureText(model) == nil {
            Label("QR을 만들지 못했습니다. 다시 시도하세요.", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder private var browserContent: some View {
        if opening {
            HStack { ProgressView().controlSize(.small); Text("코드를 만드는 중…") }
        } else if let code = model.pairingCode, let page = Self.installPageLink(model) {
            BrowserPairingPanel(code: code, link: page, address: model.installPageURL,
                                hasPhoneAppBuild: model.builds.contains { BrowserPairingPanel.isPhoneApp($0.descriptor.bundleId) })
        } else if hadOpen {
            Label("코드가 만료됐거나 틀린 시도가 많아 더 쓸 수 없습니다. 새 코드를 만드세요.", systemImage: "clock.badge.xmark")
        } else if Self.failureText(model) == nil {
            Label("코드를 만들지 못했습니다. 다시 시도하세요.", systemImage: "exclamationmark.triangle")
        }
    }

    private func open(_ route: HostModel.PairingRoute) async {
        openingID += 1
        let id = openingID
        opening = true
        lastRequest = nil
        await model.beginPairing(route)
        if id == openingID { opening = false }
    }
}

/// 처음 화면: iPhone의 상황으로 동선을 고른다.
private struct RouteChoice: View {
    let choose: (HostModel.PairingRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("이 iPhone에 RemoteDebug 앱이 있나요?")
            choice(.app, symbol: "qrcode.viewfinder", detail: String(localized: "앱으로 QR을 읽어 페어링합니다."))
            choice(.browser, symbol: "safari", detail: String(localized: "Safari로 설치 페이지를 열어 코드로 페어링하고 앱을 설치합니다."))
        }
    }

    private func choice(_ route: HostModel.PairingRoute, symbol: String, detail: String) -> some View {
        Button { choose(route) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2).frame(width: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PairingSheet.routeTitle(route)).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(PairingSheet.routeTitle(route))
        .accessibilityHint(detail)
    }
}

/// 순서대로 할 일.
struct PairingSteps: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 남은 시간 한 줄.
private struct Countdown: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded(.down)))
            Text("남은 시간 \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                .monospacedDigit()
                .foregroundStyle(remaining < 60 ? .orange : .secondary)
        }
    }
}

/// 앱이 있는 iPhone: QR, 할 일, 남은 시간, 키 상태.
struct AppPairingPanel: View {
    let invite: PairingInvite
    let dismiss: () -> Void

    static let steps = [
        String(localized: "iPhone에서 RemoteDebug 앱을 열고 이 QR을 읽습니다."),
        String(localized: "iPhone과 이 Mac에 나온 확인 숫자가 같은지 봅니다."),
        String(localized: "같으면 이 Mac에서 허용합니다."),
    ]
    static let copyTitle = String(localized: "페어링 링크 복사")
    /// 키를 실은 QR에는 링크 복사가 없다.
    static let cameraOnlyNote = String(localized: "Tailscale 키가 든 QR은 링크로 복사할 수 없습니다. iPhone의 RemoteDebug 앱 안 카메라로 읽으세요.")
    static let lockNote = String(localized: "이 tailnet은 tailnet lock을 씁니다. QR의 키로 처음 들어온 iPhone은 서명 기기에서 서명해야 이 Mac에 닿습니다. 서명한 뒤 새 QR로 다시 페어링하세요.")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 20) {
                OfferQRCode(image: invite.qrImage)
                    .frame(width: 180, height: 180)
                    .accessibilityLabel("페어링 QR 코드")
                VStack(alignment: .leading, spacing: 10) {
                    PairingSteps(steps: Self.steps)
                    Countdown(expiresAt: invite.expiresAt)
                    if let link = invite.link {
                        CopyLinkButton(url: link, title: Self.copyTitle, announcement: String(localized: "페어링 링크를 복사했습니다."))
                    } else {
                        Text(Self.cameraOnlyNote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            PairingKeyNote(dismiss: dismiss)
            if invite.tailnetLockEnabled, case .included = invite.authKey {
                Label(Self.lockNote, systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 코어가 만든 QR 그림(모듈 하나가 한 화소). 보간 없이 키운다.
private struct OfferQRCode: View {
    let image: CGImage?

    var body: some View {
        if let image {
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

/// 앱이 아직 없는 iPhone: 할 일, 설치 페이지 QR·주소, 코드, 남은 시간.
struct BrowserPairingPanel: View {
    let code: PairingCode
    /// 지금 코드를 넣은 설치 페이지 링크.
    let link: URL
    /// 코드 없는 설치 페이지 주소(Safari에 직접 칠 때).
    let address: URL?
    /// 이 Mac에 RemoteDebug iPhone 앱 빌드가 게시되어 있다(4단계에 필요하다).
    let hasPhoneAppBuild: Bool

    static let steps = [
        String(localized: "iPhone의 Tailscale 앱을 이 Mac과 같은 tailnet에 연결합니다."),
        String(localized: "iPhone 카메라로 이 QR을 찍거나, Safari에서 아래 주소를 엽니다."),
        String(localized: "페이지에 아래 코드를 넣고 페어링을 요청한 뒤, 이 Mac에서 허용합니다."),
        String(localized: "페이지의 빌드 목록에서 RemoteDebug를 설치하고, 앱을 열어 ‘RemoteDebug 앱이 있는 iPhone’의 QR을 읽습니다."),
    ]
    static let copyTitle = String(localized: "링크 복사")
    static let copyAnnouncement = String(localized: "설치 페이지 링크를 복사했습니다.")
    static let missingPhoneApp = String(localized: "이 Mac에 게시된 RemoteDebug 앱 빌드가 없어 4단계를 할 수 없습니다. 먼저 RemoteDebugPhone 스킴을 빌드해 게시하세요.")

    /// RemoteDebug iPhone 앱의 번들 ID인지(업데이트 페이지와 같은 규칙).
    static func isPhoneApp(_ bundleID: String) -> Bool {
        bundleID == "com.oozoofrog.app.RemoteDebugPhone" || bundleID.hasSuffix(".RemoteDebugPhone")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PairingSteps(steps: Self.steps)
            HStack(alignment: .top, spacing: 20) {
                QRCodeView(text: link.absoluteString)
                    .frame(width: 160, height: 160)
                    .accessibilityLabel("설치 페이지 QR 코드")
                VStack(alignment: .leading, spacing: 8) {
                    if let address {
                        Text(address.absoluteString)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    CopyLinkButton(url: link, title: Self.copyTitle, announcement: Self.copyAnnouncement)
                    Text(code.displayCode)
                        .font(.largeTitle.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityLabel("페어링 코드 \(code.displayCode.map(String.init).joined(separator: " "))")
                    Countdown(expiresAt: code.expiresAt)
                }
            }
            if !hasPhoneAppBuild {
                Label(Self.missingPhoneApp, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
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
            let text = Korean.endsWithConsonant(name)
                ? String(localized: "\(name)을 허용 목록에 추가했습니다.") : String(localized: "\(name)를 허용 목록에 추가했습니다.")
            return PairingResult(text: text,
                                 symbol: "checkmark.circle.fill", succeeded: true)
        case .denied:
            let text = alreadyAllowed
                ? String(localized: "\(name)의 페어링 요청을 거부했습니다. 이미 허용한 기기라 기존 접근은 그대로입니다. 접근을 끊으려면 기기 목록에서 제거하세요.")
                : String(localized: "\(name)의 페어링 요청을 거부했습니다.")
            return PairingResult(text: text, symbol: "xmark.circle")
        case .expired:
            return PairingResult(text: String(localized: "요청이 만료됐습니다. 새 QR이나 코드로 다시 페어링하세요."), symbol: "clock.badge.xmark")
        case .notAdded:
            let text = Korean.endsWithConsonant(name)
                ? String(localized: "제어 서버가 바뀌어 \(name)을 추가하지 않았습니다. 지금 서버에서 다시 페어링하세요.")
                : String(localized: "제어 서버가 바뀌어 \(name)를 추가하지 않았습니다. 지금 서버에서 다시 페어링하세요.")
            return PairingResult(text: text,
                                 symbol: "exclamationmark.triangle")
        case nil:
            return PairingResult(text: String(localized: "요청이 끝났지만 기기가 추가되지 않았습니다. 새 QR이나 코드로 다시 페어링하세요."), symbol: "exclamationmark.triangle")
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

    nonisolated static func makeImage(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(scaled, from: scaled.extent)
    }
}
