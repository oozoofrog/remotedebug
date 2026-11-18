import RemoteDebugFeedback
import SwiftUI

struct ContentView: View {
    @State private var showsFeedback = false
    @State private var taps = 0

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    var body: some View {
        NavigationStack {
            List {
                Section("이 빌드") {
                    LabeledContent("버전", value: version)
                    LabeledContent("빌드 번호", value: build)
                    LabeledContent("구성", value: SampleSetup.configuration)
                    LabeledContent("피드백을 보내는 곳", value: SampleSetup.route)
                }
                if !RemoteDebugFeedback.isStarted {
                    Section {
                        Text("보낼 곳이 설정되지 않았습니다. 저장소의 Config/Signing.local.xcconfig에 RD_FEEDBACK_MAC_HOST와 RD_FEEDBACK_PUBLIC_KEY(메일로도 받으려면 RD_FEEDBACK_EMAIL)를 넣고 다시 빌드하세요.")
                            .font(.callout)
                    }
                }
                Section {
                    Button("피드백 보내기") {
                        RemoteDebugFeedback.log("피드백 화면 열기")
                        showsFeedback = true
                    }
                    .disabled(!RemoteDebugFeedback.isStarted)
                }
                Section {
                    Button("로그 한 줄 남기기") {
                        taps += 1
                        RemoteDebugFeedback.log("단추 누름 \(taps)번째")
                    }
                    LabeledContent("남긴 줄", value: "\(taps)")
                } footer: {
                    Text("남긴 줄은 피드백 화면에서 \"최근 로그 붙이기\"를 켜면 함께 갑니다. Release 구성에서는 설정에서 로그 기록에 동의한 뒤에만 남습니다.")
                }
                Section {
                    NavigationLink("설정") { SettingsView() }
                }
            }
            .navigationTitle("피드백 예제")
        }
        .remoteDebugFeedback(isPresented: $showsFeedback)
        .onAppear { RemoteDebugFeedback.log("첫 화면 보임") }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            RemoteDebugFeedbackConsentSection { isOn in
                RemoteDebugFeedback.log(isOn ? "로그 기록 동의" : "로그 기록 동의 거둠")
            }
        }
        .navigationTitle("설정")
        .onAppear { RemoteDebugFeedback.log("설정 화면 보임") }
    }
}
