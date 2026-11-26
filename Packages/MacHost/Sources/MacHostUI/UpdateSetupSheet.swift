import AppKit
import MacHostKit
import SwiftUI

/// 연결한 프로젝트의 앱이 Debug 빌드에서 자신의 업데이트 정보를 확인하고 RemoteDebug 앱으로 설치하게 하는 방법.
struct UpdateSetupSheet: View {
    let project: ConnectedProject
    let host: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(project.name): 앱 안 업데이트").font(.title2.weight(.semibold))
            Text("패키지를 넣으면 이 앱의 **Debug 빌드에서만** Mac에 게시된 최신 업데이트 정보와 업데이트 내역을 보여 주고, RemoteDebug 앱을 열어 바로 설치할 수 있습니다. 배포 빌드(Release)에는 표시되지 않고 네트워크 코드도 들어가지 않습니다.")
                .fixedSize(horizontal: false, vertical: true)
            step(1, String(localized: "Xcode에서 File > Add Package Dependencies…를 열고 이 주소를 넣어 \(UpdateSetup.packageName)을 앱 대상에 추가합니다.")) {
                copyable(UpdateSetup.packageURL)
            }
            step(2, String(localized: "앱 시작 코드와 화면에 아래 코드를 넣습니다. 뷰와 배너는 Debug 빌드에서만 표시됩니다.")) {
                copyable(UpdateSetup.snippet(host: host))
            }
            step(3, String(localized: "RemoteDebug 앱 설치 여부를 코드에서 확인하려면 Info.plist의 LSApplicationQueriesSchemes에 remotedebug를 추가합니다(선택). 넣지 않아도 업데이트 버튼으로 RemoteDebug 앱을 열 수 있습니다.")) {
                EmptyView()
            }
            step(4, String(localized: "빌드해서 게시하고 iPhone에 설치합니다. 업데이트를 확인할 때는 iPhone에서 RemoteDebug 앱의 VPN이 켜져 있어야 합니다.")) {
                EmptyView()
            }
            if host.isEmpty {
                Label("이 Mac의 주소를 아직 모릅니다. 공유를 시작한 뒤 다시 열면 코드에 주소가 들어갑니다.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
    }

    private func step(_ number: Int, _ text: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(number). \(text)").fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func copyable(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("복사", systemImage: "doc.on.doc")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
