#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// 피드백을 적어 Mac에 보내는 화면.
public struct RemoteDebugFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var isSending = false
    @State private var result: String?

    public init() {}

    public var body: some View {
        NavigationView {
            Form {
                Section {
                    TextEditor(text: $message)
                        .frame(minHeight: 160)
                        .accessibilityLabel("피드백 내용")
                } header: {
                    Text("무엇이 문제인가요?")
                } footer: {
                    Text(RemoteDebugFeedback.isStarted
                        ? "앱 버전과 기기 종류가 함께 개발자의 Mac으로 갑니다. RemoteDebug 앱의 VPN이 꺼져 있으면 저장해 두었다가 다음에 보냅니다."
                        : "이 빌드는 피드백을 보낼 Mac 주소가 설정되지 않았습니다.")
                }
                if let result {
                    Section { Text(result) }
                }
            }
            .navigationTitle("피드백 보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("보내기") {
                        isSending = true
                        Task {
                            let delivered = await RemoteDebugFeedback.send(message)
                            isSending = false
                            if delivered {
                                dismiss()
                            } else {
                                result = "지금은 Mac에 닿지 않아 저장해 두었습니다. RemoteDebug 앱의 VPN을 켜고 이 앱을 다시 열면 보냅니다."
                                message = ""
                            }
                        }
                    }
                    .disabled(isSending || !RemoteDebugFeedback.isStarted || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

public extension View {
    /// `isPresented`가 참이면 피드백 화면을 띄운다.
    func remoteDebugFeedback(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) { RemoteDebugFeedbackSheet() }
    }
}
#endif
