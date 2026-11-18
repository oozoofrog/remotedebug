#if canImport(SwiftUI)
import SwiftUI

/// 로그 기록 동의 스위치에 쓰는 문구. 기본값은 기기 언어를 따른다(한국어·영어·일본어·중국어 간체·번체, 그 밖에는 영어).
/// 기본 설명은 이 패키지가 하는 일만 말하므로, 그 앱이 실제로 로그에 남기는 것에 맞게 `explanation`을 바꿔 넣는다.
public struct RemoteDebugFeedbackConsentLabels: Sendable {
    public var toggle = FeedbackStrings.text(.consentToggle)
    public var footer = FeedbackStrings.text(.consentFooter)
    public var agreeTitle = FeedbackStrings.text(.consentAgreeTitle)
    /// 무엇을 남기는지에 대한 설명. 동의 단추와 함께 보인다.
    public var explanation = FeedbackStrings.text(.consentExplanation, FeedbackLog.limit, FeedbackStrings.text(.sheetIncludeLogs),
                                                  "\(Int(FeedbackLog.systemWindow) / 60)")
    public var agree = FeedbackStrings.text(.consentAgree)
    public var cancel = FeedbackStrings.text(.consentCancel)

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
