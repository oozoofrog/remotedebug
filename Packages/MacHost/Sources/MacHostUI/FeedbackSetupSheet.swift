import AppKit
import MacHostKit
import SwiftUI

/// 연결한 프로젝트의 앱이 크래시 기록과 피드백을 이 Mac에 보내게 하는 방법.
struct FeedbackSetupSheet: View {
    let project: ConnectedProject
    let host: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(project.name): 크래시·피드백 보내기").font(.title2.weight(.semibold))
            Text("패키지를 넣으면 이 앱의 Debug 빌드가 비정상 종료된 뒤 다시 열릴 때 크래시 기록을 이 Mac에 보내고, 앱 안에서 피드백을 적어 보낼 수 있습니다. 받은 것은 **크래시·피드백** 화면에 모입니다.")
                .fixedSize(horizontal: false, vertical: true)
            step(1, "Xcode에서 File > Add Package Dependencies…를 열고 이 주소를 넣어 \(FeedbackSetup.packageName)을 앱 대상에 추가합니다.") {
                copyable(FeedbackSetup.packageURL)
            }
            step(2, "앱 시작 코드와 피드백을 띄울 화면에 아래 코드를 넣습니다.") {
                copyable(FeedbackSetup.snippet(host: host))
            }
            step(3, "빌드해서 게시하고 iPhone에 설치합니다. 보낼 때는 iPhone에서 RemoteDebug 앱의 VPN이 켜져 있어야 하고, 꺼져 있으면 앱이 저장해 두었다가 다음에 보냅니다.") { EmptyView() }
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
        .frame(width: 600)
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
