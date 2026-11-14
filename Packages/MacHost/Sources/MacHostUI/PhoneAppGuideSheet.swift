import AppKit
import MacHostKit
import SwiftUI

/// App Store판의 iPhone 앱 설치 안내. 이 앱은 빌드하지 못하므로 터미널에서 실행할 명령을 준다.
struct PhoneAppGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iPhone 앱 설치").font(.title2.bold())
            Text("iPhone 앱은 자기 Apple 개발자 계정으로 빌드해 설치합니다. 터미널에서 아래 명령을 실행하면 소스를 받아 빌드하고, 연결한 iPhone에 설치합니다.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Xcode를 설치하고 Settings > Accounts에서 Apple 계정으로 로그인합니다.")
                step(2, "터미널에서 `brew install xcodegen`으로 XcodeGen을 설치합니다.")
                step(3, "iPhone을 케이블로 연결해 잠금을 풀고, 설정 > 개인정보 보호 및 보안에서 개발자 모드를 켭니다.")
                step(4, "아래 명령을 터미널에 붙여 넣어 실행합니다.")
            }

            Text(PhoneAppGuide.command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button(copied ? "복사함" : "명령 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(PhoneAppGuide.command, forType: .string)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                Button("터미널 열기") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                }
                Link("소스 보기", destination: PhoneAppGuide.repository)
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
