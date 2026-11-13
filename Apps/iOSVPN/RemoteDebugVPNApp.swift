import PhoneClientKit
import SwiftUI
import UIKit

/// VPN만 맡는 앱. RemoteDebug 앱과 같은 tailnet 기기로 VPN을 켠다.
/// RemoteDebug 앱을 업데이트하는 동안에도 이 앱의 VPN은 꺼지지 않는다.
@main
struct RemoteDebugVPNApp: App {
    @State private var services = VPNServices()

    var body: some Scene {
        WindowGroup {
            VPNScreen(services: services)
        }
    }
}

@MainActor
@Observable
final class VPNServices {
    let tunnel: TunnelController
    let opener = UIKitURLOpener()
    /// 마지막 동작의 안내(실패 이유 등).
    var notice: String?
    /// 짝 앱의 요청을 처리하는 중이면 그 내용.
    var working: String?

    init() {
        // 이 앱만의 예전 저장소가 없으므로 옮길 것도 없다.
        tunnel = TunnelController(settings: TunnelSettingsStore(legacy: nil))
    }

    let appVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }()

    /// 공용 저장소에 Tailscale 로그인(기기 정보)이 있는가. 없으면 이 앱에서 켤 때 새 기기로 로그인하게 된다.
    var hasSharedLogin: Bool {
        guard let support = SharedContainer.groupSupportDirectory() else { return true }
        // RemoteDebug 앱의 터널이 한 번 켜져야 페어링한 예전 기기 정보가 공용 저장소로 온다.
        guard SharedContainer.defaults.bool(forKey: SharedContainer.storeMigratedKey) else { return false }
        return SharedContainer.hasState(support.appendingPathComponent("RemoteDebug/tailscale", isDirectory: true))
    }

    /// 이 앱의 터널을 켠다. 다른 앱이 켜 둔 VPN은 iOS가 끄고 이 앱의 것으로 바꾼다.
    func connect() async {
        notice = nil
        do {
            try await tunnel.connectOwn()
        } catch {
            notice = error.localizedDescription
        }
    }

    func disconnect() async {
        notice = nil
        await tunnel.disconnect()
    }

    func relogin() async {
        if TunnelStateMapping.isActive(tunnel.vpnStatus) {
            await tunnel.disconnect()
            await tunnel.waitUntilStopped()
        }
        tunnel.setPendingResetLogin()
        await connect()
    }

    func openStore(_ action: AppPair.Action = .open, returning: Bool = false) async {
        guard let url = AppPair.url(toOther: action, returning: returning) else { return }
        if await !opener.open(url) {
            notice = "RemoteDebug 앱을 열지 못했습니다. 설치돼 있는지 확인하세요."
        }
    }

    /// 짝 앱이 보낸 요청을 처리한다. `returning`이면 끝난 뒤 짝 앱으로 돌아간다.
    func handle(_ url: URL) async {
        guard let request = AppPair.request(from: url) else { return }
        switch request.action {
        case .open:
            return
        case .connect:
            working = "VPN을 켜는 중…"
            await connect()
            await waitForConnection()
        case .disconnect:
            working = "VPN을 끄는 중…"
            await disconnect()
            await tunnel.waitUntilStopped()
        }
        working = nil
        // 로그인이 필요하면 이 앱에 머문다. 사용자가 여기서 로그인해야 한다.
        if case .needsLogin = tunnel.state { return }
        if request.returning, notice == nil { await openStore() }
    }

    /// 연결되거나 로그인·오류로 멈출 때까지 최대 20초 기다린다.
    private func waitForConnection() async {
        for _ in 0..<40 {
            switch tunnel.state {
            case .connected, .needsLogin, .failed: return
            default: try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

struct VPNScreen: View {
    let services: VPNServices
    @Environment(\.scenePhase) private var scenePhase

    private var tunnel: TunnelController { services.tunnel }
    private var ownActive: Bool { TunnelStateMapping.isActive(tunnel.vpnStatus) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(title, systemImage: symbol)
                        .font(.headline)
                        .foregroundStyle(color)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                    if let working = services.working {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(working)
                        }
                    }
                    if let notice = services.notice {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("VPN")
                } footer: {
                    Text(services.hasSharedLogin
                        ? "기기 이름 \(tunnel.settings.hostname). RemoteDebug 앱과 같은 tailnet 기기로 연결합니다."
                        : "RemoteDebug 앱을 쓰던 iPhone이면 먼저 기기 정보를 가져오세요. 그래야 Mac 페어링이 그대로 유지됩니다. 새 기기로 시작하면 Tailscale 로그인과 Mac 페어링을 다시 합니다.")
                }
                Section {
                    actions
                }
                Section {
                    Button {
                        Task { await services.openStore() }
                    } label: {
                        Label("RemoteDebug 앱 열기", systemImage: "shippingbox")
                    }
                    LabeledContent("버전", value: services.appVersion)
                } footer: {
                    Text("이 앱이 VPN을 켜 두면 RemoteDebug 앱을 업데이트하는 동안에도 연결이 유지됩니다. 이 앱을 업데이트할 때는 RemoteDebug 앱이 VPN을 넘겨받습니다.")
                }
            }
            .navigationTitle("RemoteDebug VPN")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await tunnel.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await tunnel.reload(); tunnel.refreshExternal() } }
        }
        .onOpenURL { url in Task { await services.handle(url) } }
    }

    @ViewBuilder private var actions: some View {
        if !tunnel.isAvailable {
            Text(TunnelStateMapping.simulatorUnavailableMessage).font(.subheadline)
        } else if ownActive {
            if !services.hasSharedLogin {
                Button {
                    Task { await services.openStore(.connect, returning: true) }
                } label: {
                    Label("RemoteDebug 앱에서 기기 정보 가져오기", systemImage: "square.and.arrow.down.on.square")
                }
            }
            if case .needsLogin(let url) = tunnel.state, let url {
                Button {
                    Task { _ = await services.opener.open(url) }
                } label: {
                    Label("Tailscale 로그인", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            Button(role: .destructive) {
                Task { await services.disconnect() }
            } label: {
                Label("VPN 끄기", systemImage: "power")
            }
            Button {
                Task { await services.relogin() }
            } label: {
                Label("다른 계정으로 로그인", systemImage: "arrow.triangle.2.circlepath")
            }
        } else if tunnel.externalVPNActive {
            Button {
                Task { await services.connect() }
            } label: {
                Label("이 앱으로 VPN 옮기기", systemImage: "arrow.left.arrow.right")
            }
            if tunnel.pairedAppOwnsVPN {
                Button(role: .destructive) {
                    Task { await services.openStore(.disconnect, returning: true) }
                } label: {
                    Label("RemoteDebug 앱에서 VPN 끄기", systemImage: "power")
                }
            }
        } else if !services.hasSharedLogin {
            // 공용 저장소에 기기 정보가 아직 없다. RemoteDebug 앱을 쓰던 기기면 그 앱의 터널이 한 번 켜질 때 옮겨 온다.
            Button {
                Task { await services.openStore(.connect, returning: true) }
            } label: {
                Label("RemoteDebug 앱에서 기기 정보 가져오기", systemImage: "square.and.arrow.down.on.square")
            }
            Button {
                Task { await services.connect() }
            } label: {
                Label("새 기기로 시작하기", systemImage: "power")
            }
        } else {
            Button {
                Task { await services.connect() }
            } label: {
                Label("VPN 켜기", systemImage: "power")
            }
        }
    }

    private var title: String {
        if !ownActive, tunnel.externalVPNActive {
            return tunnel.pairedAppOwnsVPN ? "RemoteDebug 앱이 VPN을 켜 두었습니다" : "다른 앱의 VPN이 켜져 있습니다"
        }
        switch tunnel.state {
        case .off: return "꺼짐"
        case .connecting: return "연결하는 중"
        case .disconnecting: return "끄는 중"
        case .connected: return "연결됨"
        case .needsLogin: return "로그인이 필요합니다"
        case .failed: return "연결하지 못했습니다"
        }
    }

    private var detail: String? {
        if !ownActive, tunnel.externalVPNActive {
            return tunnel.pairedAppOwnsVPN ? "지금 연결은 RemoteDebug 앱의 터널입니다. RemoteDebug 앱을 업데이트하려면 이 앱으로 옮기세요."
                : "tailnet 주소를 가진 다른 VPN입니다."
        }
        if case .failed(let message) = tunnel.state { return message }
        if let message = tunnel.disconnectMessage { return message }
        return nil
    }

    private var symbol: String {
        switch tunnel.state {
        case .connected: "checkmark.shield.fill"
        case .connecting, .disconnecting: "arrow.triangle.2.circlepath"
        case .needsLogin: "person.crop.circle.badge.exclamationmark"
        case .failed: "exclamationmark.shield.fill"
        case .off: "shield.slash"
        }
    }

    private var color: Color {
        switch tunnel.state {
        case .connected: .green
        case .failed: .red
        case .needsLogin: .orange
        default: .primary
        }
    }
}
