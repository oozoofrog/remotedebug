import Foundation
import Observation
import Security

/// 서명할 수 있는 개발 팀(키체인의 "Apple Development" 인증서에서 읽는다).
public struct SigningTeam: Hashable, Sendable, Identifiable {
    /// 10자 팀 ID.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// 이 Mac에 연결한 iPhone(`devicectl`).
public struct ConnectedPhone: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var osVersion: String
    /// 케이블이나 같은 네트워크로 지금 닿는다.
    public var reachable: Bool

    public init(id: String, name: String, osVersion: String, reachable: Bool) {
        self.id = id
        self.name = name
        self.osVersion = osVersion
        self.reachable = reachable
    }
}

/// iPhone 앱을 빌드하고 설치하는 도구. 시험은 가짜를 넣는다.
public protocol PhoneAppTooling: Sendable {
    func teams() -> [SigningTeam]
    func phones() async -> [ConnectedPhone]
    /// 빌드한 `.app`의 경로. 출력은 `log`에 덧붙인다.
    func build(source: URL, team: String, bundlePrefix: String, device: String, log: URL) async throws(PhoneAppInstallError) -> URL
    func install(app: URL, device: String, log: URL) async throws(PhoneAppInstallError)
    func launch(bundleID: String, device: String, log: URL) async
}

public struct PhoneAppInstallError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }

    /// `xcodebuild`·`devicectl` 출력에서 사용자가 고칠 수 있는 원인을 찾는다. 모르면 마지막 오류 줄.
    public static func explain(_ output: String, step: String) -> PhoneAppInstallError {
        let lower = output.lowercased()
        let rules: [(needles: [String], message: String)] = [
            (["no accounts", "no account for team", "sign in with your apple id", "not signed in"],
             "Xcode에 이 팀의 Apple 계정이 없습니다. Xcode > Settings > Accounts에서 계정을 추가한 뒤 다시 설치하세요."),
            (["personal development team", "does not support the network extensions capability", "network extensions capability"],
             "이 팀으로는 VPN(Network Extension) 권한을 쓸 수 없습니다. 개인(무료) 팀은 지원하지 않으니 유료 Apple Developer Program 팀을 고르세요."),
            (["failed registering bundle identifier", "cannot be registered to your development team"],
             "이 번들 ID를 이 팀에서 쓸 수 없습니다. '번들 ID 앞부분'을 이 팀만 쓰는 값(예: dev.<팀 ID 소문자>)으로 바꾸세요."),
            (["developer mode", "developermode"],
             "iPhone의 개발자 모드가 꺼져 있습니다. 설정 > 개인정보 보호 및 보안 > 개발자 모드를 켜고 iPhone을 다시 시작하세요."),
            (["device is locked", "passcode", "locked"],
             "iPhone이 잠겨 있습니다. 잠금을 풀고 다시 설치하세요."),
            (["no profiles for", "requires a provisioning profile", "provisioning profile"],
             "프로비저닝 프로파일을 만들지 못했습니다. Xcode > Settings > Accounts에서 팀을 고르고 'Download Manual Profiles'를 누른 뒤 다시 설치하세요."),
            (["unable to find a destination", "could not locate device", "device is not connected"],
             "iPhone에 닿지 못했습니다. 케이블로 연결하고 잠금을 푼 뒤 '이 컴퓨터를 신뢰'를 허용하세요."),
            (["rdcore.xcframework"],
             "Go 코어(RDCore.xcframework)가 없습니다. 저장소에서 scripts/build-core.sh를 먼저 실행하세요."),
        ]
        for rule in rules where rule.needles.contains(where: { lower.contains($0) }) {
            return PhoneAppInstallError(rule.message)
        }
        let lastError = output.split(separator: "\n").last { $0.contains("error:") || $0.contains("Error") }
        return PhoneAppInstallError("\(step)에 실패했습니다." + (lastError.map { " \($0.trimmingCharacters(in: .whitespaces))" } ?? " 기록을 확인하세요."))
    }
}

/// 실제 도구: 키체인, `xcrun devicectl`, `xcodebuild`.
public struct PhoneAppTools: PhoneAppTooling {
    public init() {}

    public func teams() -> [SigningTeam] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let identities = result as? [SecIdentity] else { return [] }
        var teams: [String: SigningTeam] = [:]
        for identity in identities {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  let summary = SecCertificateCopySubjectSummary(certificate) as String?,
                  summary.hasPrefix("Apple Development:") || summary.hasPrefix("iPhone Developer:")
            else { continue }
            let subject = Self.subject(certificate)
            guard let team = subject["OU"], team.count == 10 else { continue }
            teams[team] = SigningTeam(id: team, name: subject["O"] ?? team)
        }
        return teams.values.sorted { $0.name < $1.name }
    }

    /// 인증서 주체의 OU(팀 ID)와 O(팀 이름).
    static func subject(_ certificate: SecCertificate) -> [String: String] {
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any],
              let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let items = subject[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return [:] }
        var out: [String: String] = [:]
        for item in items {
            guard let label = item[kSecPropertyKeyLabel as String] as? String, let value = item[kSecPropertyKeyValue as String] as? String else { continue }
            if label == (kSecOIDOrganizationalUnitName as String) { out["OU"] = value }
            if label == (kSecOIDOrganizationName as String) { out["O"] = value }
        }
        return out
    }

    public func phones() async -> [ConnectedPhone] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rd-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = await Self.run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", file.path, "--quiet"], log: nil)
        guard let data = try? Data(contentsOf: file) else { return [] }
        return Self.parsePhones(data)
    }

    static func parsePhones(_ data: Data) -> [ConnectedPhone] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]]
        else { return [] }
        return devices.compactMap { device in
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            guard hardware["platform"] as? String == "iOS", hardware["reality"] as? String == "physical",
                  hardware["deviceType"] as? String == "iPhone", let udid = hardware["udid"] as? String
            else { return nil }
            let tunnel = connection["tunnelState"] as? String ?? ""
            return ConnectedPhone(id: udid, name: properties["name"] as? String ?? "iPhone",
                                  osVersion: properties["osVersionNumber"] as? String ?? "",
                                  reachable: tunnel == "connected" || tunnel == "disconnected")
        }
        .sorted { ($0.reachable ? 0 : 1, $0.name) < ($1.reachable ? 0 : 1, $1.name) }
    }

    static func buildArguments(source: URL, team: String, bundlePrefix: String, device: String) -> [String] {
        [
            "-project", source.appendingPathComponent("RemoteDebug.xcodeproj").path,
            "-scheme", "RemoteDebugPhone",
            "-configuration", "Debug",
            "-destination", "id=\(device)",
            "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration",
            "DEVELOPMENT_TEAM=\(team)",
            "RD_BUNDLE_PREFIX=\(bundlePrefix)",
            "CODE_SIGN_STYLE=Automatic",
        ]
    }

    public func build(source: URL, team: String, bundlePrefix: String, device: String, log: URL) async throws(PhoneAppInstallError) -> URL {
        let arguments = Self.buildArguments(source: source, team: team, bundlePrefix: bundlePrefix, device: device)
        let built = await Self.run("/usr/bin/xcodebuild", arguments + ["build"], log: log, cwd: source)
        guard built.code == 0 else { throw PhoneAppInstallError.explain(built.output, step: "iPhone 앱 빌드") }
        // 빌드 위치는 Xcode 설정(사용자 지정 위치 포함)을 따르므로 xcodebuild에게 묻는다.
        let settings = await Self.run("/usr/bin/xcodebuild", arguments + ["-showBuildSettings", "-json"], log: nil, cwd: source)
        guard let app = Self.productPath(settingsJSON: settings.output) else {
            throw PhoneAppInstallError("빌드한 앱을 찾지 못했습니다. 기록을 확인하세요.")
        }
        return app
    }

    /// `-showBuildSettings -json`에서 RemoteDebugPhone 대상의 `.app` 경로.
    static func productPath(settingsJSON: String) -> URL? {
        guard let start = settingsJSON.firstIndex(of: "["),
              let list = try? JSONSerialization.jsonObject(with: Data(settingsJSON[start...].utf8)) as? [[String: Any]]
        else { return nil }
        for entry in list where entry["target"] as? String == "RemoteDebugPhone" {
            guard let settings = entry["buildSettings"] as? [String: String],
                  let dir = settings["TARGET_BUILD_DIR"], let name = settings["WRAPPER_NAME"]
            else { continue }
            return URL(fileURLWithPath: dir).appendingPathComponent(name)
        }
        return nil
    }

    public func install(app: URL, device: String, log: URL) async throws(PhoneAppInstallError) {
        let result = await Self.run("/usr/bin/xcrun", ["devicectl", "device", "install", "app", "--device", device, app.path], log: log)
        guard result.code == 0 else { throw PhoneAppInstallError.explain(result.output, step: "iPhone에 설치") }
    }

    public func launch(bundleID: String, device: String, log: URL) async {
        _ = await Self.run("/usr/bin/xcrun", ["devicectl", "device", "process", "launch", "--device", device, bundleID], log: log)
    }

    /// 프로세스를 돌리고 출력(표준 출력+오류)을 돌려준다. `log`가 있으면 덧붙인다.
    static func run(_ executable: String, _ arguments: [String], log: URL?, cwd: URL? = nil) async -> (code: Int32, output: String) {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = cwd }
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var collected = Data()
            let handle = log.flatMap { url -> FileHandle? in
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                let h = try? FileHandle(forWritingTo: url)
                _ = try? h?.seekToEnd()
                try? h?.write(contentsOf: Data("$ \(([executable] + arguments).joined(separator: " "))\n".utf8))
                return h
            }
            defer { try? handle?.close() }
            do {
                try process.run()
            } catch {
                return (127, "\(executable)을 실행하지 못했습니다: \(error.localizedDescription)")
            }
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                collected.append(chunk)
                try? handle?.write(contentsOf: chunk)
            }
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: collected, as: UTF8.self))
        }.value
    }
}

/// Mac 앱이 iPhone 앱을 빌드해 연결한 iPhone에 설치한다.
@MainActor
@Observable
public final class PhoneAppInstaller {
    public enum Phase: Equatable, Sendable {
        case idle
        case building
        case installing
        case done(phone: String, bundleID: String)
        case failed(String)

        public var isWorking: Bool { self == .building || self == .installing }
    }

    struct Settings: Codable {
        var team: String?
        var bundlePrefix: String?
        var phone: String?
        var sourceRoot: String?
    }

    public private(set) var teams: [SigningTeam] = []
    public private(set) var phones: [ConnectedPhone] = []
    public private(set) var phase: Phase = .idle
    public private(set) var isRefreshing = false
    public var team: String = "" { didSet { if team != oldValue, !prefixEdited { bundlePrefix = suggestedPrefix(for: team) } } }
    public var bundlePrefix: String = ""
    public var phoneID: String?
    public var sourceRoot: URL?
    public let logURL: URL

    /// 이 저장소의 기본 번들 ID 앞부분과 그 앞부분을 쓰는 팀(`Config/Signing*.xcconfig`).
    @ObservationIgnored private var repoPrefix: (prefix: String, team: String?)?
    @ObservationIgnored private var prefixEdited = false
    @ObservationIgnored private let tools: any PhoneAppTooling
    @ObservationIgnored private let file: JSONFile<Settings>

    public init(root: URL, sourceRoot: URL?, tools: any PhoneAppTooling = PhoneAppTools()) {
        self.tools = tools
        self.file = JSONFile(url: root.appendingPathComponent("phone-app.json"))
        self.logURL = root.appendingPathComponent("ProjectLogs/PhoneApp.log")
        let saved = (try? file.load()) ?? nil
        self.sourceRoot = saved?.sourceRoot.map { URL(fileURLWithPath: $0) } ?? sourceRoot
        self.phoneID = saved?.phone
        self.repoPrefix = self.sourceRoot.flatMap(Self.readRepoSigning)
        if let prefix = saved?.bundlePrefix, !prefix.isEmpty {
            bundlePrefix = prefix
            prefixEdited = true
        }
        team = saved?.team ?? repoPrefix?.team ?? ""
        if bundlePrefix.isEmpty { bundlePrefix = suggestedPrefix(for: team) }
    }

    /// 저장소가 RemoteDebug 소스인지(`RemoteDebug.xcodeproj`가 있는지).
    public var hasSource: Bool {
        guard let sourceRoot else { return false }
        return FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("RemoteDebug.xcodeproj").path)
    }

    public var phoneBundleID: String { "\(bundlePrefix).RemoteDebugPhone" }

    public var canInstall: Bool {
        hasSource && !team.isEmpty && Self.isValidPrefix(bundlePrefix) && phones.contains { $0.id == phoneID && $0.reachable } && !phase.isWorking
    }

    /// 저장소 설정의 팀과 같으면 저장소의 앞부분, 다르면 그 팀만 쓰는 `dev.<팀 ID 소문자>`.
    func suggestedPrefix(for team: String) -> String {
        if let repo = repoPrefix, repo.team == team || team.isEmpty { return repo.prefix }
        return team.isEmpty ? "" : "dev.\(team.lowercased())"
    }

    public func editPrefix(_ text: String) {
        prefixEdited = true
        bundlePrefix = text.trimmingCharacters(in: .whitespaces)
    }

    public static func isValidPrefix(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    public func chooseSource(_ url: URL) {
        sourceRoot = url
        repoPrefix = Self.readRepoSigning(url)
        if !prefixEdited { bundlePrefix = suggestedPrefix(for: team) }
        save()
    }

    /// 팀과 iPhone 목록을 새로 읽는다.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let tools = self.tools
        teams = await Task.detached { tools.teams() }.value
        if team.isEmpty || !teams.contains(where: { $0.id == team }), let first = teams.first { team = first.id }
        phones = await tools.phones()
        if phoneID == nil || !phones.contains(where: { $0.id == phoneID && $0.reachable }) {
            phoneID = phones.first { $0.reachable }?.id ?? phoneID
        }
    }

    public func install() async {
        guard canInstall, let source = sourceRoot, let phoneID, let phone = phones.first(where: { $0.id == phoneID }) else { return }
        save()
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: logURL)
        let (team, prefix, bundleID) = (team, bundlePrefix, phoneBundleID)
        do {
            phase = .building
            let app = try await tools.build(source: source, team: team, bundlePrefix: prefix, device: phoneID, log: logURL)
            phase = .installing
            try await tools.install(app: app, device: phoneID, log: logURL)
            await tools.launch(bundleID: bundleID, device: phoneID, log: logURL)
            phase = .done(phone: phone.name, bundleID: bundleID)
        } catch {
            phase = .failed(error.message)
        }
    }

    private func save() {
        try? file.save(Settings(team: team, bundlePrefix: bundlePrefix, phone: phoneID, sourceRoot: sourceRoot?.path))
    }

    /// `Config/Signing.xcconfig`의 `RD_BUNDLE_PREFIX`와 `Signing.local.xcconfig`의 값(있으면 덮어씀)·`DEVELOPMENT_TEAM`.
    static func readRepoSigning(_ root: URL) -> (prefix: String, team: String?)? {
        func values(_ name: String) -> [String: String] {
            guard let text = try? String(contentsOf: root.appendingPathComponent("Config/\(name)"), encoding: .utf8) else { return [:] }
            var out: [String: String] = [:]
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), let eq = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                out[key] = value
            }
            return out
        }
        let base = values("Signing.xcconfig"), local = values("Signing.local.xcconfig")
        guard let prefix = local["RD_BUNDLE_PREFIX"] ?? base["RD_BUNDLE_PREFIX"] else { return nil }
        return (prefix, local["DEVELOPMENT_TEAM"])
    }
}
