#if os(macOS)
import Foundation
import RDBuildInspection
import RDModels
import RDPackaging

// rdvalidate: 킷 검증용 CLI.
//   rdvalidate inspect <.app|.ipa> [--json] [--confirm-debug] [--allow-config NAME]... [--udid UDID] [--work-dir DIR]
//   rdvalidate package <app> --out <file.ipa>
//   rdvalidate manifest --bundle-id B --version V --title T --ipa-url U --out FILE
// 종료 코드: 0 수락 / 2 거부 / 64 사용법 오류 / 66 입력을 읽을 수 없음 / 1 그 밖의 실패

let usage = """
사용법:
  rdvalidate inspect <.app|.ipa> [--json] [--confirm-debug] [--allow-config NAME]... [--udid UDID] [--work-dir DIR]
  rdvalidate package <app> --out <file.ipa>
  rdvalidate manifest --bundle-id B --version V --title T --ipa-url U --out FILE

"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func usageError(_ message: String) -> Never {
    fail("rdvalidate: \(message)\n\n\(usage)", code: 64)
}

struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: [String]] = [:]

    init(_ raw: [String], valueOptions: Set<String>, flagOptions: Set<String>) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if flagOptions.contains(a) {
                flags.insert(a)
            } else if valueOptions.contains(a) {
                guard i + 1 < raw.count else { usageError("\(a)에 값이 필요합니다") }
                options[a, default: []].append(raw[i + 1])
                i += 1
            } else if a.hasPrefix("--") {
                usageError("알 수 없는 옵션: \(a)")
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func one(_ name: String) -> String? { options[name]?.last }
}

func runInspect(_ raw: [String]) -> Never {
    let args = Args(raw, valueOptions: ["--allow-config", "--udid", "--work-dir"], flagOptions: ["--json", "--confirm-debug"])
    guard args.positional.count == 1 else { usageError("inspect에는 .app 또는 .ipa 경로 하나가 필요합니다") }
    let input = URL(fileURLWithPath: args.positional[0])
    let options = InspectionOptions(
        confirmedDebug: args.flags.contains("--confirm-debug"),
        targetUDID: args.one("--udid"),
        allowedConfigurations: Set(args.options["--allow-config"] ?? []),
        now: Date()
    )

    let result: InspectionResult
    do {
        if input.pathExtension.lowercased() == "ipa" {
            let base = args.one("--work-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory
            let work = base.appendingPathComponent("rdvalidate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? ZipReader.removeTree(at: work) }
            result = try BuildInspector.inspect(ipaAt: input, options: options, workDirectory: work)
        } else {
            result = try BuildInspector.inspect(appAt: input, options: options)
        }
    } catch {
        fail("rdvalidate: \(error)", code: 66)
    }

    if args.flags.contains("--json") {
        // 팀 ID·프로필 이름은 descriptor에 포함된다. 기기 UDID는 어디에도 없다.
        let data = (try? RDJSON.encoder(pretty: true).encode(result)) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    } else {
        // 사람이 읽는 출력에는 UDID·팀 ID·프로필 이름을 쓰지 않는다.
        let id = result.bundleId ?? "(번들 ID 없음)"
        if result.accepted, let d = result.descriptor {
            print("accepted \(id) 구성=\(d.configuration) 근거=\(d.configurationEvidence.rawValue)")
        } else {
            print("rejected \(id)")
            for r in result.reasons { print("  - \(r.code.rawValue): \(r.detail)") }
        }
        for w in result.warnings { print("  ! \(w)") }
    }
    exit(result.accepted ? 0 : 2)
}

func runPackage(_ raw: [String]) -> Never {
    let args = Args(raw, valueOptions: ["--out"], flagOptions: [])
    guard args.positional.count == 1, let out = args.one("--out") else { usageError("package <app> --out <file.ipa>") }
    do {
        let (size, sha) = try IPABuilder.package(appAt: URL(fileURLWithPath: args.positional[0]), to: URL(fileURLWithPath: out))
        print("{\"size\":\(size),\"sha256\":\"\(sha)\"}")
        exit(0)
    } catch {
        fail("rdvalidate: \(error)", code: 1)
    }
}

func runManifest(_ raw: [String]) -> Never {
    let args = Args(raw, valueOptions: ["--bundle-id", "--version", "--title", "--ipa-url", "--out"], flagOptions: [])
    guard args.positional.isEmpty,
          let bundleId = args.one("--bundle-id"), let version = args.one("--version"),
          let title = args.one("--title"), let ipaURL = args.one("--ipa-url").flatMap(URL.init(string:)),
          let out = args.one("--out") else {
        usageError("manifest --bundle-id B --version V --title T --ipa-url U --out FILE")
    }
    let data = OTAManifest.make(bundleId: bundleId, version: version, title: title, ipaURL: ipaURL)
    do {
        try data.write(to: URL(fileURLWithPath: out))
        exit(0)
    } catch {
        fail("rdvalidate: \(error)", code: 1)
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { usageError("명령이 필요합니다") }
let rest = Array(argv.dropFirst())
switch command {
case "inspect": runInspect(rest)
case "package": runPackage(rest)
case "manifest": runManifest(rest)
case "-h", "--help", "help":
    print(usage)
    exit(0)
default: usageError("알 수 없는 명령: \(command)")
}
#else
print("rdvalidate는 macOS 전용입니다")
#endif
