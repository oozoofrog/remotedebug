import Foundation

/// 프로토콜의 시각 형식(UTC ISO-8601, `Z`).
public enum RDTimestamp {
    /// `2026-11-11T09:00:00Z` 형식 문자열.
    public static func string(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    /// 초 단위·소수 초·`+09:00` 같은 오프셋을 모두 받는다.
    public static func parse(_ text: String) -> Date? {
        if let d = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return d }
        if let d = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        // Go의 RFC3339Nano처럼 소수 자릿수가 많은 경우: 소수부를 떼어 따로 더한다.
        guard let dot = text.firstIndex(of: ".") else { return nil }
        var digits = ""
        var idx = text.index(after: dot)
        while idx < text.endIndex, text[idx].isASCII, text[idx].isNumber {
            digits.append(text[idx])
            idx = text.index(after: idx)
        }
        guard !digits.isEmpty, let fraction = Double("0." + digits) else { return nil }
        let base = String(text[text.startIndex..<dot]) + String(text[idx...])
        guard let d = try? Date(base, strategy: Date.ISO8601FormatStyle()) else { return nil }
        return d.addingTimeInterval(fraction)
    }
}

extension KeyedDecodingContainer {
    func decodeRDDate(forKey key: Key) throws -> Date {
        let text = try decode(String.self, forKey: key)
        guard let date = RDTimestamp.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "ISO-8601 시각이 아닙니다: \(text)")
        }
        return date
    }

    func decodeRDDateIfPresent(forKey key: Key) throws -> Date? {
        guard let text = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let date = RDTimestamp.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "ISO-8601 시각이 아닙니다: \(text)")
        }
        return date
    }
}

extension KeyedEncodingContainer {
    mutating func encodeRDDate(_ date: Date, forKey key: Key) throws {
        try encode(RDTimestamp.string(date), forKey: key)
    }
}

/// 테스트·호스트 앱이 공통으로 쓰는 JSON 인코더·디코더.
public enum RDJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder { JSONDecoder() }
}
