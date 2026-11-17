import CoreGraphics
import Foundation
import RDModels

/// QR·링크 페어링 제안 하나를 화면에 보이기 위한 값(protocol-addenda B.5). 코어가 Swiftail `PairingOffer`로 만든다.
///
/// `link`와 `qrImage`는 제안의 비밀(과 1회용 Tailscale 키)을 담는다. 화면에만 보이고 로그·에이전트 응답·활동 기록에 넣지
/// 않는다. 그래서 `description`과 `dump`는 비밀을 가린다.
public struct PairingInvite: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    /// 1회용 Tailscale 키를 QR에 실었는지.
    public enum AuthKey: Sendable, Hashable {
        /// OAuth 클라이언트가 없어 싣지 않았다.
        case none
        /// 실었다. 키는 이 시각에 끝난다.
        case included(expires: Date)
        /// 만들지 못해 키 없이 냈다.
        case failed(TailscaleAPI.Failure)
    }

    /// `remotedebug://pair#v=1&h=…`. 비밀이다.
    public var link: URL
    /// 링크를 적은 QR. 모듈 하나가 한 화소이고 둘레에 여백이 있다. 보간 없이 키워 그린다. 만들지 못했으면 nil.
    public var qrImage: CGImage?
    public var expiresAt: Date
    public var authKey: AuthKey
    /// 이 Mac의 tailnet에 tailnet lock이 켜져 있다. 키로 새로 들어온 iPhone은 서명될 때까지 이 Mac에 닿지 못한다.
    public var tailnetLockEnabled: Bool

    public init(link: URL, qrImage: CGImage?, expiresAt: Date, authKey: AuthKey, tailnetLockEnabled: Bool) {
        (self.link, self.qrImage, self.expiresAt, self.authKey, self.tailnetLockEnabled) = (link, qrImage, expiresAt, authKey, tailnetLockEnabled)
    }

    public var description: String {
        "PairingInvite(link: <가림>, expiresAt: \(RDTimestamp.string(expiresAt)), authKey: \(authKeySummary), tailnetLock: \(tailnetLockEnabled))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["link": "<가림>", "expiresAt": expiresAt, "authKey": authKeySummary, "tailnetLockEnabled": tailnetLockEnabled])
    }

    private var authKeySummary: String {
        switch authKey {
        case .none: "none"
        case .included: "included"
        case .failed: "failed"
        }
    }
}

/// 제안을 열 때 화면이 코어에 넘기는 값.
public struct PairingInviteRequest: Sendable {
    /// 제안(과 키)의 수명. 1~3600초.
    public var lifetimeSeconds: Int
    /// 키체인의 OAuth 클라이언트. 있으면 코어가 1회용 키를 만들어 제안에 싣는다.
    public var oauthClient: TailscaleAPI.OAuthClient?

    public init(lifetimeSeconds: Int, oauthClient: TailscaleAPI.OAuthClient?) {
        (self.lifetimeSeconds, self.oauthClient) = (lifetimeSeconds, oauthClient)
    }
}
