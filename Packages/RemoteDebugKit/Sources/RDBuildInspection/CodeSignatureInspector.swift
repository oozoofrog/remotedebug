#if os(macOS)
import Foundation
import Security

public struct CodeSignatureInfo: Sendable {
    public enum Status: Sendable, Equatable {
        case valid
        /// 서명이 전혀 없음.
        case unsigned
        /// 서명은 있으나 정적 검증(strict + nested) 실패.
        case invalid(code: Int32, message: String)
    }

    public var status: Status
    public var identifier: String?
    public var teamIdentifier: String?
    /// 서명에 들어 있는 엔타이틀먼트. 서명이 없으면 비어 있다.
    public var entitlements: [String: PlistValue]

    public var getTaskAllow: Bool? { entitlements["get-task-allow"]?.boolValue }
    public var isSigned: Bool { status != .unsigned }
}

public enum CodeSignatureInspector {
    private static let errSecCSUnsigned: OSStatus = -67062

    /// 번들(.app) 또는 실행 파일의 서명을 정적으로 확인한다. 인증서 신뢰는 평가하지 않고
    /// 코드 디렉터리·리소스 봉인의 일관성만 본다.
    ///
    /// 어느 스레드에서든 동시에 불러도 된다: Security 호출은 프로세스 전체에서 하나인 전용 직렬 큐(`SecurityGate`)에서만
    /// 실행되고, 이 함수는 그 결과를 기다린다. Swift 동시성 코드에서는 협력 스레드를 막지 않는 `async` 판을 쓴다.
    public static func inspect(bundleAt url: URL) throws -> CodeSignatureInfo {
        try SecurityGate.sync { try inspectOnGate(url) }
    }

    /// 비동기 판. 전용 직렬 큐에서 검사하고 checked continuation으로 기다린다(협력 스레드를 막지 않음).
    public static func inspect(bundleAt url: URL) async throws -> CodeSignatureInfo {
        try Task.checkCancellation()
        return try await SecurityGate.run { try inspectOnGate(url) }
    }

    private static func inspectOnGate(_ url: URL) throws -> CodeSignatureInfo {
        dispatchPrecondition(condition: .onQueue(SecurityGate.queue))
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard created == errSecSuccess, let code = staticCode else {
            throw InspectionError.unreadable(String(localized: "서명을 읽을 수 없습니다(\(message(for: created)))"))
        }

        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures))
        let check = SecStaticCodeCheckValidity(code, flags, nil)
        let status: CodeSignatureInfo.Status
        switch check {
        case errSecSuccess: status = .valid
        case errSecCSUnsigned: status = .unsigned
        default: status = .invalid(code: check, message: message(for: check))
        }

        var identifier: String?
        var team: String?
        var entitlements: [String: PlistValue] = [:]
        if status != .unsigned {
            var cfInfo: CFDictionary?
            let infoFlags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation | kSecCSRequirementInformation))
            if SecCodeCopySigningInformation(code, infoFlags, &cfInfo) == errSecSuccess, let info = cfInfo as? [String: Any] {
                identifier = info[kSecCodeInfoIdentifier as String] as? String
                team = info[kSecCodeInfoTeamIdentifier as String] as? String
                if let dict = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
                    entitlements = dict.plistDictionary()
                }
            }
        }
        return CodeSignatureInfo(status: status, identifier: identifier, teamIdentifier: team, entitlements: entitlements)
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
#endif
