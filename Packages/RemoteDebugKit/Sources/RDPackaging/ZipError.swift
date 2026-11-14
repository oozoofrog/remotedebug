#if os(macOS)
import Foundation

public enum ZipError: Error, Equatable, CustomStringConvertible {
    case io(String)
    case entryTooLarge(String)
    case archiveTooLarge
    case tooManyEntries
    case invalidName(String)
    case notAZip
    case corrupt(String)
    case unsupported(String)
    case unsafePath(String)
    case crcMismatch(String)
    case sizeLimitExceeded
    /// 출력 위치에 일반 파일이 아닌 것(폴더·심볼릭 링크 등)이 있다. 그 항목은 건드리지 않는다.
    case invalidDestination(String)

    public var description: String {
        switch self {
        case .io(let m): String(localized: "I/O 오류: \(m)")
        case .entryTooLarge(let n): String(localized: "항목이 4 GiB 이상입니다: \(n)")
        case .archiveTooLarge: String(localized: "아카이브가 4 GiB 이상입니다(ZIP64 미지원)")
        case .tooManyEntries: String(localized: "항목이 너무 많습니다(최대 65,534개, ZIP64 미지원)")
        case .invalidName(let n): String(localized: "잘못된 항목 이름: \(n)")
        case .notAZip: String(localized: "ZIP 파일이 아닙니다")
        case .corrupt(let m): String(localized: "손상된 ZIP: \(m)")
        case .unsupported(let m): String(localized: "지원하지 않는 ZIP 기능: \(m)")
        case .unsafePath(let n): String(localized: "안전하지 않은 경로: \(n)")
        case .crcMismatch(let n): String(localized: "CRC 불일치: \(n)")
        case .sizeLimitExceeded: String(localized: "풀린 크기가 한도를 넘었습니다")
        case .invalidDestination(let p): String(localized: "출력 위치에 일반 파일이 아닌 항목이 있습니다: \(p)")
        }
    }
}
#endif
