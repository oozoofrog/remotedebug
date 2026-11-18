#if canImport(SwiftUI)
import SwiftUI

/// 로그 기록 동의 스위치에 쓰는 문구. 앱의 언어와, 그 앱이 실제로 로그에 남기는 것에 맞게 바꿔 넣는다.
public struct RemoteDebugFeedbackConsentLabels: Sendable {
    public var toggle = "문제 해결용 로그 기록"
    public var footer = "켜면 이 앱의 최근 동작 기록을 이 기기에 남기고, 피드백을 보낼 때 붙일지 고를 수 있습니다. 끄면 남긴 기록을 바로 지웁니다."
    public var agreeTitle = "로그를 기록할까요?"
    /// 무엇을 남기는지에 대한 설명. 동의 단추와 함께 보인다.
    public var explanation = "앱이 남기는 동작 기록(화면 이동, 오류, 시각)을 최근 \(FeedbackLog.limit)줄까지 이 기기의 메모리에 두고, 앱을 끄면 사라집니다. 피드백을 보낼 때 \"최근 로그 붙이기\"를 켠 경우에만 이 기록과 이 앱의 최근 15분 시스템 로그를 암호화해서 개발자에게 보냅니다. 보낸 기록은 문제를 살펴보는 데만 쓰고, 이 스위치를 끄면 기기에 남은 기록을 지웁니다."
    public var agree = "동의하고 켜기"
    public var cancel = "취소"

    public init() {}
}

/// 로그 기록 동의 스위치. 앱의 설정 화면에서 피드백 근처에 둔다.
/// 켤 때 무엇을 남기는지 설명을 보여 주고 동의 단추를 눌러야 켜진다. 끄면 남긴 것을 바로 지운다.
///
/// ```swift
/// Form {
///     RemoteDebugFeedbackConsentSection()
/// }
/// ```
public struct RemoteDebugFeedbackConsentToggle: View {
    @State private var isOn: Bool
    @State private var asksAgreement = false
    private let labels: RemoteDebugFeedbackConsentLabels
    private let onChange: (Bool) -> Void

    /// `onChange`는 동의가 바뀐 뒤 불린다. 다른 기기(Watch 등)에 동의를 전하거나 그쪽 기록을 지울 때 쓴다.
    public init(labels: RemoteDebugFeedbackConsentLabels = RemoteDebugFeedbackConsentLabels(), onChange: @escaping (Bool) -> Void = { _ in }) {
        self.labels = labels
        self.onChange = onChange
        _isOn = State(initialValue: RemoteDebugFeedback.hasRecordingConsent)
    }

    public var body: some View {
        Toggle(labels.toggle, isOn: Binding(get: { isOn }, set: { wanted in
            if wanted {
                // 설명을 읽고 동의하기 전에는 켜지지 않는다.
                asksAgreement = true
            } else {
                apply(false)
            }
        }))
        .alert(labels.agreeTitle, isPresented: $asksAgreement) {
            Button(labels.agree) { apply(true) }
            Button(labels.cancel, role: .cancel) {}
        } message: {
            Text(labels.explanation)
        }
        .onAppear { isOn = RemoteDebugFeedback.hasRecordingConsent }
    }

    private func apply(_ granted: Bool) {
        RemoteDebugFeedback.setRecordingConsent(granted)
        isOn = RemoteDebugFeedback.hasRecordingConsent
        onChange(isOn)
    }
}

/// 동의 스위치와 그 아래 설명을 묶은 `Form`·`List`용 구역.
public struct RemoteDebugFeedbackConsentSection: View {
    private let labels: RemoteDebugFeedbackConsentLabels
    private let onChange: (Bool) -> Void

    public init(labels: RemoteDebugFeedbackConsentLabels = RemoteDebugFeedbackConsentLabels(), onChange: @escaping (Bool) -> Void = { _ in }) {
        self.labels = labels
        self.onChange = onChange
    }

    public var body: some View {
        Section {
            RemoteDebugFeedbackConsentToggle(labels: labels, onChange: onChange)
        } footer: {
            Text(labels.footer)
        }
    }
}
#endif
