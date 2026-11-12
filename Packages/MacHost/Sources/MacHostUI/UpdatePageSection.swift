import AppKit
import MacHostKit
import SwiftUI

/// RemoteDebug iPhone 앱 자신의 업데이트를 공식 Tailscale로 내주는 칸.
struct UpdatePageSection: View {
    @Environment(UpdatePageModel.self) private var page: UpdatePageModel?

    var body: some View {
        if let page {
            Section {
                status(page)
                if let build = page.servedBuild {
                    LabeledContent("올린 빌드") {
                        Text("\(build.displayName) \(build.version) (\(build.buildNumber)) · \(build.publishedAt.formatted(date: .abbreviated, time: .shortened)) 게시")
                    }
                } else {
                    LabeledContent("올린 빌드") {
                        Text("없음: 프로젝트 화면에서 RemoteDebugPhone 스킴을 빌드해 게시하면 자동으로 올립니다.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let url = page.pageURL {
                    LabeledContent("주소") {
                        HStack(spacing: 6) {
                            Text(url.absoluteString)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            } label: {
                                Label("주소 복사", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .help("주소 복사")
                        }
                    }
                }
                if let error = page.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions(page)
                    .task { await page.refresh() }
            } header: {
                Text("iPhone 앱 업데이트(공식 Tailscale)")
            } footer: {
                Text("RemoteDebug iPhone 앱은 자기 VPN으로 자기 업데이트를 받을 수 없습니다. iPhone에서 공식 Tailscale을 켜고 이 주소를 열면 설치됩니다. iPhone 앱의 업데이트 버튼이 이 주소와 순서를 안내합니다. 주소는 이 Mac의 tailnet 안에서만 열립니다.")
            }
        }
    }

    @ViewBuilder
    private func status(_ page: UpdatePageModel) -> some View {
        switch page.tailscale {
        case .checking:
            Label("공식 Tailscale 확인 중", systemImage: "clock")
        case .missing:
            Label("이 Mac에 공식 Tailscale 앱이 없습니다. Tailscale을 설치하고 로그인하세요.", systemImage: "xmark.circle")
                .foregroundStyle(.orange)
        case .notConnected(let state):
            Label("공식 Tailscale이 연결돼 있지 않습니다(\(state)). Tailscale 앱에서 연결하세요.", systemImage: "pause.circle")
                .foregroundStyle(.orange)
        case .connected(let dns):
            if page.isRouted {
                Label("열림: \(dns)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("공식 Tailscale 연결됨(\(dns)). 업데이트 페이지는 아직 닫혀 있습니다.", systemImage: "circle")
            }
        }
    }

    @ViewBuilder
    private func actions(_ page: UpdatePageModel) -> some View {
        HStack {
            if case .connected = page.tailscale {
                if page.isRouted {
                    Button("닫기") { Task { await page.disable() } }
                } else {
                    Button("공식 Tailscale로 열기") { Task { await page.enable() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            Button("다시 확인") { Task { await page.refresh() } }
            if page.isWorking { ProgressView().controlSize(.small) }
        }
        .disabled(page.isWorking)
    }
}
