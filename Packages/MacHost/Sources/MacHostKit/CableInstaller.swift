import Foundation
import IOKit

// USB 케이블 설치(docs/protocol-addenda.md R)의 Mac 쪽: 요청이 들어온 네트워크 인터페이스가 어느 iPhone의 케이블인지
// 알아내고, 게시한 IPA를 풀어 `devicectl`로 그 iPhone에 설치한다.

/// 네트워크 인터페이스가 USB로 꽂은 iPhone의 것인지 알아낸다. 시험은 가짜를 넣는다.
public protocol CableDeviceFinding: Sendable {
    /// 그 인터페이스를 만든 USB 기기의 일련번호(USB Serial Number). Apple 기기가 아니거나 USB 인터페이스가 아니면 nil.
    func usbSerial(ofInterface name: String) -> String?
}

/// IPA를 풀고 설치하는 도구. 시험은 가짜를 넣는다.
public protocol CableInstallTooling: Sendable {
    /// IPA를 `directory`에 풀고 그 안의 `.app` 경로를 돌려준다.
    func unpack(ipa: URL, into directory: URL) async -> URL?
    /// 설치한다. 실패면 사용자에게 보일 이유, 성공이면 nil.
    func install(app: URL, device: String) async -> String?
}

/// IORegistry에서 인터페이스(`anri0`, `en11`)의 조상 가운데 USB 기기를 찾는다.
/// iPhone을 꽂으면 생기는 네트워크 인터페이스는 모두 그 iPhone의 USB 기기 아래에 있다.
public struct USBDeviceRegistry: CableDeviceFinding {
    /// Apple의 USB 제조사 번호.
    static let appleVendorID = 0x05AC

    public init() {}

    public func usbSerial(ofInterface name: String) -> String? {
        guard CableInstaller.isInterfaceName(name), let matching = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let found = Self.appleUSBSerial(above: entry)
            IOObjectRelease(entry)
            if let found { return found }
            entry = IOIteratorNext(iterator)
        }
        return nil
    }

    /// `entry`에서 위로 올라가며 처음 만나는 USB 기기의 일련번호. Apple 기기가 아니면 nil.
    private static func appleUSBSerial(above entry: io_registry_entry_t) -> String? {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<32 {
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                let vendor = property(current, "idVendor") as? Int
                let serial = property(current, "USB Serial Number") as? String
                return vendor == appleVendorID ? serial : nil
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// `ditto`로 풀고 `xcrun devicectl`로 설치한다. 둘 다 기한이 있어, 멈춘 도구는 끝내고 실패로 돌려준다.
public struct CableInstallTools: CableInstallTooling {
    /// IPA를 푸는 `ditto`의 기한(초).
    public static let unpackTimeout: TimeInterval = 300
    /// `devicectl device install app`의 기한(초). 큰 앱은 옮기는 데 오래 걸려 넉넉하게 둔다.
    /// 둘을 더해도 호스트 로직이 세션을 끝내는 기한(`HostLogic.Limits.cableInstallTimeout`, 1800초)보다 짧다.
    public static let installTimeout: TimeInterval = 1200

    public typealias Run = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async -> (code: Int32, output: String)
    private let run: Run

    public init() {
        self.init(run: { await PhoneAppTools.run($0, $1, log: nil, timeout: $2) })
    }

    /// 시험은 도구 대신 가짜를 넣는다.
    init(run: @escaping Run) {
        self.run = run
    }

    public func unpack(ipa: URL, into directory: URL) async -> URL? {
        let result = await run("/usr/bin/ditto", ["-x", "-k", ipa.path, directory.path], Self.unpackTimeout)
        guard result.code == 0 else { return nil }
        let payload = directory.appendingPathComponent("Payload")
        let apps = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        return apps.count == 1 ? apps[0] : nil
    }

    public func install(app: URL, device: String) async -> String? {
        let result = await run("/usr/bin/xcrun", ["devicectl", "device", "install", "app", "--device", device, app.path], Self.installTimeout)
        if result.code == PhoneAppTools.timedOutCode {
            return String(localized: "설치가 \(Int(Self.installTimeout / 60))분 안에 끝나지 않아 멈췄습니다. iPhone의 잠금을 풀고 케이블을 확인한 뒤 다시 설치하세요.")
        }
        // 이 글은 iPhone으로 간다. 도구가 낸 줄을 그대로 쓰는 경우에는 이 Mac의 경로와 기기 식별자를 가린다.
        return result.code == 0 ? nil : PhoneAppInstallError.explain(result.output, step: String(localized: "iPhone에 설치"), redacting: true).message
    }
}

/// 케이블로 꽂은 iPhone에 게시한 빌드를 설치한다.
public struct CableInstaller: Sendable {
    private let finder: any CableDeviceFinding
    private let tools: any CableInstallTooling
    private let workRoot: URL

    public init(finder: any CableDeviceFinding = USBDeviceRegistry(), tools: any CableInstallTooling = CableInstallTools(),
                workRoot: URL = FileManager.default.temporaryDirectory) {
        self.finder = finder
        self.tools = tools
        self.workRoot = workRoot
    }

    /// 인터페이스 이름으로 쓸 수 있는 글자인가(영문자·숫자, 15자까지).
    static func isInterfaceName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 15 && name.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."z").contains($0) || ("A"..."Z").contains($0)
        }
    }

    /// USB 일련번호를 `devicectl`이 받는 UDID로 바꾼다.
    /// 요즘 기기는 16진수 24자이고 UDID는 8자 뒤에 `-`가 들어간다. 예전 기기는 16진수 40자 그대로다.
    static func udid(fromUSBSerial serial: String) -> String? {
        guard serial.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }) else { return nil }
        switch serial.count {
        case 24: return serial.prefix(8) + "-" + serial.dropFirst(8)
        case 40: return serial
        default: return nil
        }
    }

    /// 이 인터페이스가 USB로 꽂은 iPhone의 것이면 그 기기의 UDID.
    public func device(onInterface name: String) -> String? {
        guard Self.isInterfaceName(name), let serial = finder.usbSerial(ofInterface: name) else { return nil }
        return Self.udid(fromUSBSerial: serial)
    }

    /// 푼 폴더 이름의 앞부분.
    static let workPrefix = "rd-cable-"

    /// 앞선 실행이 남긴 푼 폴더(`rd-cable-*`)를 지운다. 앱을 켤 때 부른다(설치 도중에 앱이 꺼지면 남는다).
    public static func removeLeftovers(in root: URL = FileManager.default.temporaryDirectory) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(workPrefix) { try? FileManager.default.removeItem(at: entry) }
    }

    /// IPA를 풀어 설치한다. 실패면 사용자에게 보일 이유, 성공이면 nil. 푼 폴더는 끝나면(실패와 기한 넘김 포함) 지운다.
    public func install(ipa: URL, device: String) async -> String? {
        let work = workRoot.appendingPathComponent(Self.workPrefix + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            return String(localized: "설치할 빌드를 풀 폴더를 만들지 못했습니다.")
        }
        guard let app = await tools.unpack(ipa: ipa, into: work) else {
            return String(localized: "빌드 파일(IPA)을 풀지 못했습니다. 다시 게시한 뒤 설치하세요.")
        }
        return await tools.install(app: app, device: device)
    }
}
