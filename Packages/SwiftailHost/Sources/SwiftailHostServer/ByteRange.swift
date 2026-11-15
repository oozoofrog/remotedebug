// 단일 바이트 Range(RFC 9110 14장). 계산은 UInt64이고 넘침 없이 포화한다. 4GiB를 넘는 파일의 오프셋도 같은 길이다.

/// Range 머리를 본 결과.
public enum RangeDecision: Sendable, Equatable {
    /// 전체를 200으로 보낸다(Range 없음, 해석되지 않는 Range, 여러 구간, `If-Range`).
    case full
    /// `start...end`(둘 다 포함)를 206으로 보낸다.
    case partial(start: UInt64, end: UInt64)
    /// 416과 `Content-Range: bytes */<길이>`.
    case unsatisfiable
}

public enum ByteRange {
    /// - Parameters:
    ///   - header: `Range` 머리 값. nil이면 `.full`.
    ///   - hasIfRange: `If-Range`가 왔는가. 이 서버는 검증자(ETag·Last-Modified)를 내지 않으므로 늘 맞지 않는 것으로 보고
    ///     Range를 무시한다(RFC 9110 13.1.5).
    ///   - length: 보낼 표현의 길이.
    public static func decide(header: String?, hasIfRange: Bool = false, length: UInt64) -> RangeDecision {
        guard let header, !hasIfRange else { return .full }
        let bytes = Array(header.utf8)
        // range-unit은 대소문자를 가리지 않는다. "=" 앞뒤에는 공백이 없다(RFC 9110 14.1.1).
        guard bytes.count > 6, String(decoding: bytes[0..<5], as: UTF8.self).lowercased() == "bytes", bytes[5] == 0x3D else {
            return .full
        }
        let set = bytes[6...]
        // 여러 구간은 multipart 대신 전체를 보낸다(Go 호스트와 같다).
        if set.contains(0x2C) { return .full }
        let spec = trim(set)
        guard let dash = spec.firstIndex(of: 0x2D) else { return .full }
        let firstText = spec[..<dash]
        let lastText = spec[(dash + 1)...]

        if firstText.isEmpty {
            // suffix-range: 끝에서 n바이트. 0이거나 빈 표현은 만족할 수 없다.
            guard let suffix = parseDigits(lastText) else { return .full }
            guard suffix > 0, length > 0 else { return .unsatisfiable }
            return .partial(start: length - min(suffix, length), end: length - 1)
        }
        guard let first = parseDigits(firstText) else { return .full }
        var last = UInt64.max
        if !lastText.isEmpty {
            guard let value = parseDigits(lastText) else { return .full }
            // last < first는 잘못된 range-spec이다: Range 전체를 무시한다(RFC 9110 14.1.1).
            guard value >= first else { return .full }
            last = value
        }
        guard first < length else { return .unsatisfiable }
        return .partial(start: first, end: min(last, length - 1))
    }

    /// 206의 `Content-Range` 값.
    public static func contentRange(start: UInt64, end: UInt64, length: UInt64) -> String {
        "bytes \(start)-\(end)/\(length)"
    }

    /// 416의 `Content-Range` 값.
    public static func unsatisfiedContentRange(length: UInt64) -> String { "bytes */\(length)" }

    /// 1자 이상의 ASCII 숫자. 넘치면 `UInt64.max`로 포화한다(그런 시작은 어떤 길이보다 크다).
    static func parseDigits(_ text: ArraySlice<UInt8>) -> UInt64? {
        guard !text.isEmpty, text.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        var value: UInt64 = 0
        for byte in text {
            let (shifted, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (added, overflow2) = shifted.addingReportingOverflow(UInt64(byte - 0x30))
            if overflow1 || overflow2 { return .max }
            value = added
        }
        return value
    }

    private static func trim(_ value: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var slice = value
        while let first = slice.first, first == 0x20 || first == 0x09 { slice = slice.dropFirst() }
        while let last = slice.last, last == 0x20 || last == 0x09 { slice = slice.dropLast() }
        return slice
    }
}
