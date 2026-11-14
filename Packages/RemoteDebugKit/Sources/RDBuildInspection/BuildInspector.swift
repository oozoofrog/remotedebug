#if os(macOS)
import Foundation
import RDModels
import RDPackaging

/// protocol §7 `DebugBuildPolicy`.
///
/// 동시성: 모든 진입점은 어느 스레드에서든 동시에 불러도 된다. 코드 서명 검사(Security.framework)는 프로세스 전체에서
/// 하나인 전용 직렬 큐에서만 돌아가므로(`SecurityGate`) 협력 스레드 풀이 모두 막혀 교착하는 일이 없다.
/// 동기 판은 그 큐의 결과를 기다리는 동안 호출 스레드를 막는다. Swift 동시성 코드(TaskGroup·`async let`·`Task {}`)에서는
/// 협력 스레드를 막지 않는 `async` 판을 쓴다. `async` 판은 파일 I/O도 협력 풀 밖의 큐에서 하고 태스크 취소를 따른다.
public enum BuildInspector {
    /// `.app` 폴더를 검사한다. 경로가 심볼릭 링크이면 실제 번들(과 그 번들이 놓인 폴더)을 기준으로 판정한다(규칙 7).
    public static func inspect(appAt appURL: URL, options: InspectionOptions) throws -> InspectionResult {
        let appURL = resolvedAppURL(appURL)
        let gathered = try gather(appURL, options: options, folderConfiguration: true)
        let signature = try CodeSignatureInspector.inspect(bundleAt: appURL)
        return evaluate(gathered, signature: signature, options: options)
    }

    /// `inspect(appAt:options:)`의 비동기 판. 협력 스레드를 막지 않는다.
    public static func inspect(appAt appURL: URL, options: InspectionOptions) async throws -> InspectionResult {
        let appURL = resolvedAppURL(appURL)
        let gathered = try await BlockingWork.run { _ in try gather(appURL, options: options, folderConfiguration: true) }
        let signature = try await CodeSignatureInspector.inspect(bundleAt: appURL)
        return evaluate(gathered, signature: signature, options: options)
    }

    /// `.ipa`의 `Payload/*.app`을 `workDirectory` 아래 새 폴더에 풀어 검사하고, 풀어 낸 폴더는 지운다
    /// (지우지 못하면 `warnings`에 알린다). IPA에는 `<Config>-iphoneos` 폴더 정보가 없으므로 규칙 7의 폴더 판정은 건너뛴다.
    /// 수락 결과의 `descriptor.ipa`에는 이 `.ipa` 파일의 실제 크기와 SHA-256이 들어간다.
    /// 풀기 한도는 `ZipLimits.ipaInspection`(4 GiB, 압축률·항목 수 제한, 겹친 항목 거부)이다.
    /// `control`: 청크마다 취소(`CancellationError`)를 확인하고 풀기·해시 진행 상황을 보고한다.
    public static func inspect(
        ipaAt ipaURL: URL, options: InspectionOptions, workDirectory: URL, control: OperationControl = .default
    ) throws -> InspectionResult {
        let staged = try stageIPA(ipaURL, workDirectory: workDirectory, control: control)
        var result: InspectionResult
        do {
            let gathered = try gather(staged.appURL, options: options, folderConfiguration: false)
            let signature = try CodeSignatureInspector.inspect(bundleAt: staged.appURL)
            result = evaluate(gathered, signature: signature, options: options)
            if let descriptor = result.descriptor {
                let digest = try digestIPA(ipaURL, control: control)
                result.descriptor = descriptor.withIPA(size: digest.size, sha256: digest.sha256)
            }
        } catch {
            try? ZipReader.removeTree(at: staged.root)
            throw error
        }
        return cleanUp(staged.root, result)
    }

    /// `inspect(ipaAt:options:workDirectory:control:)`의 비동기 판. 풀기·해시는 협력 풀 밖에서 하고 태스크 취소를 따른다.
    public static func inspect(
        ipaAt ipaURL: URL, options: InspectionOptions, workDirectory: URL,
        progress: (@Sendable (ArchiveProgress) -> Void)? = nil
    ) async throws -> InspectionResult {
        let staged = try await BlockingWork.run(progress: progress) { control in
            try stageIPA(ipaURL, workDirectory: workDirectory, control: control)
        }
        var result: InspectionResult
        do {
            let gathered = try await BlockingWork.run { _ in try gather(staged.appURL, options: options, folderConfiguration: false) }
            let signature = try await CodeSignatureInspector.inspect(bundleAt: staged.appURL)
            result = evaluate(gathered, signature: signature, options: options)
            if let descriptor = result.descriptor {
                let digest = try await BlockingWork.run(progress: progress) { control in
                    let d = try digestIPA(ipaURL, control: control)
                    return IPADigest(size: d.size, sha256: d.sha256)
                }
                result.descriptor = descriptor.withIPA(size: digest.size, sha256: digest.sha256)
            }
        } catch {
            _ = try? await BlockingWork.run(cancellable: false) { _ in try ZipReader.removeTree(at: staged.root) }
            throw error
        }
        let finished = result
        return try await BlockingWork.run(cancellable: false) { _ in cleanUp(staged.root, finished) }
    }

    // MARK: IPA

    private struct Staged: Sendable {
        var root: URL
        var appURL: URL
    }

    private struct IPADigest: Sendable {
        var size: Int64
        var sha256: String
    }

    private static func stageIPA(_ ipaURL: URL, workDirectory: URL, control: OperationControl) throws -> Staged {
        let reader: ZipReader
        do { reader = try ZipReader(url: ipaURL) } catch { throw InspectionError.unreadable(String(localized: "IPA를 열 수 없습니다(\(String(describing: error)))")) }

        var appNames = Set<String>()
        for entry in reader.entries {
            let comps: [String]
            do { comps = try ZipReader.safeComponents(entry.name) } catch { throw InspectionError.unreadable(String(localized: "IPA에 안전하지 않은 경로가 있습니다")) }
            if comps.count >= 2, comps[0] == "Payload", comps[1].hasSuffix(".app") { appNames.insert(comps[1]) }
        }
        guard appNames.count == 1, let appName = appNames.first else {
            throw InspectionError.unreadable(String(localized: "Payload/ 아래에 .app이 정확히 하나여야 합니다(\(String(appNames.count))개)"))
        }

        let root = workDirectory.appendingPathComponent("rd-ipa-\(UUID().uuidString)", isDirectory: true)
        do {
            try reader.extractAll(to: root, limits: .ipaInspection, control: control) { entry in entry.name.hasPrefix("Payload/") }
        } catch {
            try? ZipReader.removeTree(at: root)
            if error is CancellationError { throw error }
            throw InspectionError.unreadable(String(localized: "IPA를 풀 수 없습니다(\(String(describing: error)))"))
        }
        return Staged(root: root, appURL: root.appendingPathComponent("Payload").appendingPathComponent(appName, isDirectory: true))
    }

    private static func digestIPA(_ ipaURL: URL, control: OperationControl) throws -> (size: Int64, sha256: String) {
        do { return try IPABuilder.fileDigest(at: ipaURL, control: control) } catch let e as CancellationError { throw e } catch {
            throw InspectionError.unreadable("\(error)")
        }
    }

    private static func cleanUp(_ root: URL, _ result: InspectionResult) -> InspectionResult {
        do {
            try ZipReader.removeTree(at: root)
            return result
        } catch {
            var r = result
            r.warnings.append(String(localized: "풀어 낸 임시 폴더를 지우지 못했습니다(\(root.lastPathComponent)): \(String(describing: error))"))
            return r
        }
    }

    // MARK: 본체

    private static func resolvedAppURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private enum ProfileState: Sendable {
        case missing
        case unreadable(String)
        case loaded(ProvisioningProfile)
    }

    /// 서명 외에 필요한 것을 모두 읽은 결과(파일 I/O는 여기서만 한다).
    private struct Gathered: Sendable {
        var appURL: URL
        var bundleId: String?
        var platformName: String?
        var supportedPlatforms: [String]
        var displayName: String
        var version: String
        var buildNumber: String
        var minOS: String
        var profile: ProfileState
        var configuration: ConfigOutcome
    }

    private static func gather(_ appURL: URL, options: InspectionOptions, folderConfiguration: Bool) throws -> Gathered {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: appURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw InspectionError.unreadable(String(localized: "\(appURL.lastPathComponent)은(는) 폴더가 아닙니다"))
        }
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL),
              let info = (try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil)) as? [String: Any] else {
            throw InspectionError.unreadable(String(localized: "Info.plist를 읽을 수 없습니다"))
        }

        let profile: ProfileState
        let profileURL = appURL.appendingPathComponent("embedded.mobileprovision")
        if !fm.fileExists(atPath: profileURL.path) {
            profile = .missing
        } else {
            do { profile = .loaded(try ProvisioningProfile(contentsOf: profileURL)) } catch { profile = .unreadable("\(error)") }
        }

        return Gathered(
            appURL: appURL,
            bundleId: info["CFBundleIdentifier"] as? String,
            platformName: info["DTPlatformName"] as? String,
            supportedPlatforms: info["CFBundleSupportedPlatforms"] as? [String] ?? [],
            displayName: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? appURL.deletingPathExtension().lastPathComponent,
            version: (info["CFBundleShortVersionString"] as? String) ?? "",
            buildNumber: (info["CFBundleVersion"] as? String) ?? "",
            minOS: (info["MinimumOSVersion"] as? String) ?? "",
            profile: profile,
            configuration: detectConfiguration(appURL: appURL, options: options, folderConfiguration: folderConfiguration)
        )
    }

    /// 순수 판정(I/O 없음). 사유 순서: 번들 ID, 규칙 1, 2·3, 4~6, 7, 8.
    private static func evaluate(_ g: Gathered, signature: CodeSignatureInfo, options: InspectionOptions) -> InspectionResult {
        var reasons: [Rejection] = []
        var warnings: [String] = []
        let bundleId = g.bundleId

        // 코어의 게시(rd_host_publish)는 빈 bundleId를 bad_request로 거부한다. 수락 규칙을 맞추려고 여기서 거부한다.
        if (bundleId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append(Rejection(code: .unreadable, detail: "Info.plist에 CFBundleIdentifier가 없거나 비어 있어 게시할 수 없습니다"))
        }

        // 규칙 1: iOS 앱 번들
        if !(g.platformName == "iphoneos" || g.supportedPlatforms.contains("iPhoneOS")) {
            reasons.append(Rejection(code: .notIOSApp, detail: "DTPlatformName=\(g.platformName ?? "없음")"))
        }

        // 규칙 2·3: 서명
        switch signature.status {
        case .valid: break
        case .unsigned: reasons.append(Rejection(code: .unsigned, detail: "코드 서명이 없습니다"))
        case .invalid(_, let message): reasons.append(Rejection(code: .invalidSignature, detail: message))
        }
        // 서명이 없으면 서명된 엔타이틀먼트도 없으므로 규칙 3은 `unsigned`가 대신 설명한다.
        if signature.status != .unsigned, signature.getTaskAllow != true {
            reasons.append(Rejection(code: .getTaskAllowMissing, detail: "서명된 엔타이틀먼트에 get-task-allow=true가 없습니다"))
        }

        // 규칙 4~6, 8: 프로필
        var profile: ProvisioningProfile?
        switch g.profile {
        case .missing:
            reasons.append(Rejection(code: .noProvisioningProfile, detail: "embedded.mobileprovision이 없습니다"))
        case .unreadable(let message):
            reasons.append(Rejection(code: .noProvisioningProfile, detail: "embedded.mobileprovision을 읽을 수 없습니다(\(message))"))
        case .loaded(let p):
            profile = p
            // 규칙 5
            if let problem = developmentProfileProblem(p) {
                reasons.append(Rejection(code: .notDevelopmentProfile, detail: problem))
            }
            // 규칙 6
            if p.expirationDate <= options.now {
                reasons.append(Rejection(code: .profileExpired, detail: "프로필이 만료됐습니다"))
            } else if p.expirationDate.timeIntervalSince(options.now) < 7 * 86_400 {
                warnings.append(String(localized: "프로필이 7일 안에 만료됩니다"))
            }
        }

        // 규칙 7: 구성
        var configuration: (name: String, evidence: BuildDescriptor.ConfigurationEvidence)?
        switch g.configuration {
        case .accepted(let name, let evidence): configuration = (name, evidence)
        case .rejected(let r): reasons.append(r)
        }

        // 규칙 8: 대상 기기
        if let udid = options.targetUDID, let profile {
            let devices = (profile.provisionedDevices ?? []).map { $0.lowercased() }
            if !devices.contains(udid.lowercased()) {
                reasons.append(Rejection(code: .deviceNotProvisioned, detail: "대상 기기가 프로필의 기기 목록에 없습니다"))
            }
        }

        guard reasons.isEmpty, let profile, let configuration, let bundleId else {
            return InspectionResult(accepted: false, reasons: reasons, warnings: warnings, descriptor: nil, bundleId: bundleId)
        }

        let descriptor = BuildDescriptor(
            id: BuildDescriptor.makeID(bundleId: bundleId, ipaSHA256: ""),
            bundleId: bundleId,
            displayName: g.displayName,
            version: g.version,
            buildNumber: g.buildNumber,
            minOS: g.minOS,
            debug: true,
            configuration: configuration.name,
            configurationEvidence: configuration.evidence,
            signing: BuildDescriptor.Signing(
                teamId: signature.teamIdentifier ?? profile.teamIdentifier ?? "",
                profileName: profile.name,
                profileExpires: profile.expirationDate,
                provisionedDeviceCount: profile.provisionedDevices?.count ?? 0,
                getTaskAllow: true
            ),
            ipa: BuildDescriptor.IPAInfo(size: 0, sha256: ""),
            publishedAt: options.now
        )
        return InspectionResult(accepted: true, reasons: [], warnings: warnings, descriptor: descriptor, bundleId: bundleId)
    }

    /// 규칙 5. 개발 프로필이면 nil, 아니면 분류 값(`enterprise`·`ad_hoc`·`app_store` 등).
    private static func developmentProfileProblem(_ p: ProvisioningProfile) -> String? {
        if p.provisionsAllDevices { return "enterprise" }
        switch p.kind {
        case .adHoc: return "ad_hoc"
        case .appStore: return "app_store"
        case .enterprise: return "enterprise"
        case .unknown: return "no_provisioned_devices"
        case .development: break
        }
        if let aps = p.apsEnvironment, aps != "development" { return "aps_environment_\(aps)" }
        return nil
    }

    private enum ConfigOutcome: Sendable {
        case accepted(String, BuildDescriptor.ConfigurationEvidence)
        case rejected(Rejection)
    }

    private static func detectConfiguration(appURL: URL, options: InspectionOptions, folderConfiguration: Bool) -> ConfigOutcome {
        // (1) 부모 폴더 `<Config>-iphoneos`. `appURL`은 이미 심볼릭 링크를 푼 실제 위치다.
        if folderConfiguration {
            let parent = appURL.deletingLastPathComponent().lastPathComponent
            let suffix = "-iphoneos"
            if parent.hasSuffix(suffix), parent.count > suffix.count {
                let config = String(parent.dropLast(suffix.count))
                if config == "Debug" || options.allowedConfigurations.contains(config) {
                    return .accepted(config, .path)
                }
                return .rejected(Rejection(code: .configurationNotDebug, detail: "빌드 폴더의 구성이 \(config)입니다"))
            }
        }
        // (2) *.debug.dylib
        let names = (try? FileManager.default.contentsOfDirectory(atPath: appURL.path)) ?? []
        if names.contains(where: { $0.hasSuffix(".debug.dylib") }) { return .accepted("Debug", .debugDylib) }
        // (3) 사용자 확인
        if options.confirmedDebug { return .accepted("Debug", .userConfirmed) }
        // (4)
        return .rejected(Rejection(code: .configurationUnverified, detail: "구성을 확인할 근거가 없습니다(폴더 이름·debug dylib·사용자 확인 모두 없음)"))
    }
}
#endif
