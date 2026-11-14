import Foundation

/// 처음 쓰는 사람을 위한 시작 순서: Tailscale 연결 → 설치 주소 → iPhone 페어링 → 첫 빌드 게시.
public struct SetupChecklist: Sendable, Hashable {
    public enum Step: String, CaseIterable, Sendable, Hashable {
        case tailnet, address, iphone, build
    }

    public enum State: Sendable, Hashable {
        case done
        /// 지금 할 차례.
        case current
        case later
    }

    public struct Item: Sendable, Hashable, Identifiable {
        public var step: Step
        public var state: State
        public var title: String
        /// 지금 할 일이나 막힌 이유. 끝난 단계는 짧은 결과.
        public var detail: String
        public var id: Step { step }
    }

    public var items: [Item]

    public var isComplete: Bool { items.allSatisfy { $0.state == .done } }
    public var current: Item? { items.first { $0.state == .current } }
    public var doneCount: Int { items.filter { $0.state == .done }.count }

    public static func make(guidance: StatusGuidance, fqdn: String?, devices: Int, builds: Int) -> SetupChecklist {
        let connected: Bool
        switch guidance.kind {
        case .stopped, .starting, .needsLogin, .waitingForLoginURL, .needsMachineAuth, .unknown: connected = false
        case .certificatesDisabled, .magicDNSDisabled, .issuingCertificate, .ready, .error: connected = true
        }
        let ready = guidance.kind == .ready
        let done: [Step: Bool] = [.tailnet: connected || ready, .address: ready, .iphone: devices > 0, .build: builds > 0]

        var items: [Item] = []
        var foundCurrent = false
        for step in Step.allCases {
            let isDone = done[step] ?? false
            let state: State
            if isDone {
                state = .done
            } else if !foundCurrent {
                state = .current
                foundCurrent = true
            } else {
                state = .later
            }
            items.append(Item(step: step, state: state, title: title(step), detail: detail(step, isDone: isDone, guidance: guidance, fqdn: fqdn, devices: devices, builds: builds)))
        }
        return SetupChecklist(items: items)
    }

    static func title(_ step: Step) -> String {
        switch step {
        case .tailnet: String(localized: "이 Mac을 Tailscale에 연결")
        case .address: String(localized: "설치 주소 열기")
        case .iphone: String(localized: "iPhone 연결")
        case .build: String(localized: "첫 빌드 게시")
        }
    }

    static func detail(_ step: Step, isDone: Bool, guidance: StatusGuidance, fqdn: String?, devices: Int, builds: Int) -> String {
        switch step {
        case .tailnet:
            return isDone ? String(localized: "tailnet에 연결됨") : guidance.message
        case .address:
            if isDone { return fqdn.map { String(localized: "\($0)에서 iPhone이 빌드를 받습니다") } ?? String(localized: "설치 주소가 열림") }
            switch guidance.kind {
            case .certificatesDisabled, .magicDNSDisabled, .issuingCertificate, .error: return guidance.message
            default: return String(localized: "Tailscale 연결이 끝나면 HTTPS 설치 주소를 엽니다.")
            }
        case .iphone:
            if isDone { return String(localized: "iPhone \(String(devices))대 허용됨") }
            let install = HostEdition.isSandboxed
                ? String(localized: "'iPhone 앱 설치…'의 명령을 터미널에서 실행해 앱을 설치합니다.")
                : String(localized: "iPhone을 케이블로 연결하고 'iPhone 앱 설치…'로 앱을 설치합니다.")
            return String(localized: "\(install) 앱에서 VPN을 켜고 이 Mac과 같은 Tailscale 계정으로 로그인한 뒤, 페어링 QR을 찍고 여기서 허용합니다.")
        case .build:
            if isDone { return String(localized: "빌드 \(String(builds))개 게시됨") }
            if HostEdition.isSandboxed {
                return String(localized: "프로젝트 화면에서 프로젝트 폴더를 등록하면 Xcode에서 iPhone용으로 한 최근 Debug 빌드를 게시합니다. iPhone 앱의 빌드 목록에서 설치를 누르면 됩니다.")
            }
            return String(localized: "Xcode 프로젝트 폴더를 이 창에 끌어 놓으면 Debug 기기용으로 빌드해 게시합니다. iPhone 앱의 빌드 목록에서 설치를 누르면 됩니다.")
        }
    }
}
