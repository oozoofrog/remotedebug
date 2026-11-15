import Foundation
import SwiftailCertificates
import SwiftailHostServer

/// 명령줄 옵션. 인증 키는 명령줄로 받지 않고 파일 경로만 받는다(프로세스 목록과 셸 기록에 남지 않게).
struct Options {
    static let stagingDirectoryURL = URL(string: "https://acme-staging-v02.api.letsencrypt.org/directory")!
    static let productionHost = "acme-v02.api.letsencrypt.org"

    var stateDirectory: URL
    var hostname = "rd-mac-1a2b3c4d"
    var authKeyFile: URL?
    var controlURL: URL?
    var filePath: String?
    var app: AppPackage?
    var acmeDirectory: URL = stagingDirectoryURL
    var isProduction = false
    /// 시험 디렉터리의 루트 인증서 PEM 파일. 운영에서는 쓰지 않는다.
    var acmeRoots: URL?

    static let usage = """
        쓰는 법: rd-swiftail-host --state-dir <폴더> [옵션]

          --state-dir <폴더>        노드 상태 폴더. 없으면 0700으로 만든다. 지우지 않는다.
          --hostname <이름>         노드 호스트 이름(기본 rd-mac-1a2b3c4d)
          --auth-key-file <파일>    인증 키가 든 파일. 처음 등록할 때만 필요하다(상태 폴더에 등록된 신원이
                                    있으면 빼도 된다)
          --control-url <URL>       제어 서버(기본 Tailscale)
          --file <파일>             /file로 내보낼 파일(Range 지원)
          --ipa <파일> --bundle-id <ID> --bundle-version <버전> --title <이름>
                                    /manifest.plist, /app.ipa로 내보낼 앱(넷을 함께 준다)
          --acme-directory <URL>    ACME 디렉터리(기본 Let's Encrypt 스테이징)
          --acme-roots <PEM 파일>   그 디렉터리가 내는 인증서를 검증할 루트(파일의 CERTIFICATE 블록 모두)
          --acme-production         Let's Encrypt 운영 디렉터리로 발급한다(같은 이름 7일에 5장 제한)

        스테이징·시험 디렉터리에는 --acme-roots가 꼭 필요하다. 운영은 시스템 루트로만 검증하므로 --acme-roots를 받지 않는다.

        100MB 전송 시험: --file만 주면 IPA 없이 / 와 /file만 내보낸다.

        Ctrl-C로 멈춘다. 노드와 인증서 관리자가 끝나기를 기다린 뒤 끝난다.
        """

    enum ParseError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    static func parse(_ arguments: [String]) throws(ParseError) -> Options {
        var values: [String: String] = [:]
        var production = false
        let valued: Set<String> = ["--state-dir", "--hostname", "--auth-key-file", "--control-url", "--file", "--ipa",
                                   "--bundle-id", "--bundle-version", "--title", "--acme-directory",
                                   "--acme-roots"]
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            if name == "--acme-production" {
                production = true
                index += 1
                continue
            }
            if name == "--help" || name == "-h" { throw .message(usage) }
            guard valued.contains(name) else { throw .message("모르는 옵션: \(name)\n\n\(usage)") }
            guard index + 1 < arguments.count else { throw .message("\(name)에 값이 없다") }
            guard values[name] == nil else { throw .message("\(name)이 두 번 왔다") }
            values[name] = arguments[index + 1]
            index += 2
        }

        guard let state = values["--state-dir"], !state.isEmpty else { throw .message("--state-dir가 필요하다\n\n\(usage)") }
        var options = Options(stateDirectory: URL(filePath: state, directoryHint: .isDirectory))
        if let hostname = values["--hostname"] {
            guard !hostname.isEmpty else { throw .message("--hostname이 비었다") }
            options.hostname = hostname
        }
        options.authKeyFile = values["--auth-key-file"].map { URL(filePath: $0) }
        if let control = values["--control-url"] {
            guard let url = URL(string: control), url.scheme == "https" || url.scheme == "http" else {
                throw .message("--control-url은 http(s) URL이어야 한다")
            }
            options.controlURL = url
        }
        options.filePath = values["--file"]
        options.acmeRoots = values["--acme-roots"].map { URL(filePath: $0) }

        let appKeys = ["--ipa", "--bundle-id", "--bundle-version", "--title"]
        let given = appKeys.filter { values[$0] != nil }
        if !given.isEmpty {
            guard given.count == appKeys.count else { throw .message("--ipa, --bundle-id, --bundle-version, --title은 함께 준다") }
            options.app = AppPackage(ipaPath: values["--ipa"]!, bundleIdentifier: values["--bundle-id"]!,
                                     bundleVersion: values["--bundle-version"]!, title: values["--title"]!)
        }

        if production {
            guard values["--acme-directory"] == nil else { throw .message("--acme-production과 --acme-directory는 함께 쓰지 않는다") }
            options.acmeDirectory = CertificateConfiguration.letsEncryptDirectoryURL
            options.isProduction = true
        } else if let directory = values["--acme-directory"] {
            guard let url = URL(string: directory), url.scheme == "https" else { throw .message("--acme-directory는 https URL이어야 한다") }
            guard url.host()?.lowercased() != productionHost else {
                throw .message("운영 디렉터리로 발급하려면 --acme-directory 대신 --acme-production을 준다")
            }
            options.acmeDirectory = url
        }
        return options
    }
}
