import PhoneClientKit
import RDModels
import SwiftUI

/// 페어링한 Mac에 게시된 RemoteDebug 앱의 빌드와 설치.
struct StoreUpdateSection: View {
    let services: VPNServices

    private var model: ClientModel { services.model }

    var body: some View {
        Section {
            if let host = model.host {
                LabeledContent("Mac", value: host.hostName)
                if model.buildsLoadedAt == nil {
                    notLoaded
                } else {
                    loaded
                }
            } else {
                Text("페어링한 Mac이 없습니다. RemoteDebug 앱에서 Mac과 페어링하면 여기에 RemoteDebug 빌드가 나옵니다.")
                    .font(.subheadline)
                Button {
                    Task { await services.openStore() }
                } label: {
                    Label("RemoteDebug 앱 열기", systemImage: "shippingbox")
                }
            }
        } header: {
            HStack {
                Text("RemoteDebug 빌드")
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if model.host != nil {
                    Button {
                        Task { await services.refresh() }
                    } label: {
                        Label("새로고침", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("RemoteDebug 빌드 목록 새로고침")
                }
            }
        } footer: {
            if model.host != nil {
                if let loaded = model.buildsLoadedAt {
                    Text("\(loaded.formatted(date: .omitted, time: .shortened))에 받은 목록. 설치하는 동안 RemoteDebug 앱이 닫힙니다. VPN이 이 앱의 터널이 아니면 이 앱으로 옮긴 뒤 설치합니다.")
                } else {
                    Text("설치하는 동안 RemoteDebug 앱이 닫힙니다. VPN이 이 앱의 터널이 아니면 이 앱으로 옮긴 뒤 설치합니다.")
                }
            }
        }
    }

    @ViewBuilder private var notLoaded: some View {
        if model.isRefreshing {
            HStack(spacing: 12) {
                ProgressView()
                Text("빌드 목록을 받는 중")
            }
        } else if let error = model.refreshError {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.subheadline)
                Button("다시 시도") { Task { await services.refresh() } }
                    .buttonStyle(.borderless)
            }
        } else if model.tunnel != .connected {
            Text("VPN이 연결되면 RemoteDebug 빌드를 확인합니다.")
                .foregroundStyle(.secondary)
        } else {
            Button("빌드 목록 받기") { Task { await services.refresh() } }
        }
    }

    @ViewBuilder private var loaded: some View {
        if let error = model.refreshError {
            Label {
                Text("목록을 새로 받지 못했습니다. 아래는 이전 목록입니다.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.footnote)
            .accessibilityHint(error)
        }
        let builds = services.storeBuilds
        if let latest = builds.first {
            row(latest)
            let older = builds.dropFirst()
            if !older.isEmpty {
                DisclosureGroup("이전 빌드 \(older.count)개") {
                    ForEach(older) { row($0, isOlder: true) }
                }
                .font(.subheadline)
            }
        } else {
            LabeledContent("설치된 버전", value: services.storeInstalled.map { "\($0.version) (\($0.buildNumber))" } ?? String(localized: "알 수 없음"))
            Text("Mac에 게시된 RemoteDebug 빌드가 없습니다. Mac에서 RemoteDebugPhone 스킴을 게시한 뒤 새로고침하세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ build: BuildDescriptor, isOlder: Bool = false) -> some View {
        BuildRow(build: build, install: model.installs[build.id], actions: services.installActions, isOlder: isOlder,
                 installed: services.storeInstalled, preparation: services.installer.preparations[build.id])
    }
}
