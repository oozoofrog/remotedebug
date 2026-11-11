#if os(macOS)
import Foundation

/// 엔타이틀먼트·프로필 값을 담는 Sendable 값 형식.
public enum PlistValue: Sendable, Hashable {
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    public init?(_ any: Any) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .real(n.doubleValue)
            } else {
                self = .integer(n.intValue)
            }
        case let s as String: self = .string(s)
        case let d as Data: self = .data(d)
        case let d as Date: self = .date(d)
        case let a as [Any]: self = .array(a.compactMap(PlistValue.init))
        case let d as [String: Any]: self = .dictionary(d.compactMapValues(PlistValue.init))
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

extension Dictionary where Key == String, Value == Any {
    func plistDictionary() -> [String: PlistValue] {
        compactMapValues(PlistValue.init)
    }
}
#endif
