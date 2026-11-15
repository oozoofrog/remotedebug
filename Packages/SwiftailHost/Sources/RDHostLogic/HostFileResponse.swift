import Foundation

extension HostLogic {
    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
    static func parseHTTPDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
    static func contentDisposition(_ name: String) -> String {
        if name.utf8.contains(where: { $0 >= 128 }) {
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~".utf8)
            let escaped = name.utf8.map { allowed.contains($0) ? String(Unicode.Scalar($0)) : String(format: "%%%02X", $0) }.joined()
            return "attachment; filename*=utf-8''" + escaped
        }
        let token = !name.isEmpty && name.utf8.allSatisfy { byte in
            byte > 32 && byte < 127 && !Array("()<>@,;:\\\"/[]?=".utf8).contains(byte)
        }
        return "attachment; filename=" + (token ? name : "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"")
    }

    func serveFile(_ file: Snapshot, request: HostRequest, headers: [(String, String)] = [], allowMultipleRanges: Bool = true) -> HostResponse {
        var headers = headers + [("Content-Type", "application/octet-stream"), ("Last-Modified", Self.httpDate(file.modified))]
        let etag = headers.first { $0.0 == "ETag" }?.1 ?? ""
        let modified = floor(file.modified.timeIntervalSince1970)
        func tags(_ input: String, weak: Bool) -> Bool {
            input.split(separator: ",").contains { part in
                let tag = part.trimmingCharacters(in: .whitespaces)
                if tag == "*" { return true }
                return !etag.isEmpty && (weak ? tag.replacingOccurrences(of: "W/", with: "") == etag : tag == etag)
            }
        }
        if let match = request.header("if-match"), !tags(match, weak: false) { return HostResponse(status: 412, headers: headers) }
        if request.header("if-match") == nil, let unmodified = request.header("if-unmodified-since"),
           let date = Self.parseHTTPDate(unmodified), modified > date.timeIntervalSince1970 { return HostResponse(status: 412, headers: headers) }
        if let none = request.header("if-none-match") {
            if tags(none, weak: true) {
                headers.removeAll { $0.0 == "Content-Type" || (!etag.isEmpty && $0.0 == "Last-Modified") }
                return HostResponse(status: 304, headers: headers)
            }
        } else if let since = request.header("if-modified-since"), let date = Self.parseHTTPDate(since), modified <= date.timeIntervalSince1970 {
            headers.removeAll { $0.0 == "Content-Type" || (!etag.isEmpty && $0.0 == "Last-Modified") }
            return HostResponse(status: 304, headers: headers)
        }
        var range = request.header("range") ?? ""
        if (!allowMultipleRanges && range.contains(",")) || range == "bytes=" { range = "" }
        if let ifRange = request.header("if-range"), !range.isEmpty {
            if ifRange.hasPrefix("\"") || ifRange.hasPrefix("W/") {
                if etag.isEmpty || ifRange != etag { range = "" }
            } else if let date = Self.parseHTTPDate(ifRange) {
                if modified != date.timeIntervalSince1970 { range = "" }
            } else { range = "" }
        }
        if range.contains(","), range.hasPrefix("bytes=") {
            var spans: [Range<UInt64>] = [], noOverlap = false
            for item in range.dropFirst(6).split(separator: ",", omittingEmptySubsequences: true) {
                switch Self.byteRange("bytes=" + item, size: file.size) {
                case .success(let span): spans.append(span)
                case .failure(let error):
                    if !error.noOverlap { return rangeFailure(headers: headers, size: file.size, noOverlap: false) }
                    noOverlap = true
                }
            }
            if spans.isEmpty && noOverlap && file.size != 0 { return rangeFailure(headers: headers, size: file.size, noOverlap: true) }
            var total: UInt64 = 0, tooLarge = false
            for span in spans {
                let (sum, overflow) = total.addingReportingOverflow(span.upperBound - span.lowerBound)
                if overflow || sum > file.size { tooLarge = true; break }
                total = sum
            }
            if !tooLarge && spans.count > 1 { return multipartResponse(file, spans: spans, headers: headers, head: request.method == "HEAD") }
            if !tooLarge, let span = spans.first { range = "bytes=\(span.lowerBound)-\(span.upperBound == 0 ? "-1" : String(span.upperBound - 1))" }
            else { range = "" }
        }
        var offset: UInt64 = 0, count = file.size, status = 200
        if !range.isEmpty {
            switch Self.byteRange(range, size: file.size) {
            case .success(let span):
                offset = span.lowerBound
                count = span.upperBound - span.lowerBound
                status = 206
                headers.append(("Content-Range", "bytes \(offset)-\(span.upperBound == 0 ? "-1" : String(span.upperBound - 1))/\(file.size)"))
            case .failure(let error):
                if file.size != 0 || !error.noOverlap {
                    return rangeFailure(headers: headers, size: file.size, noOverlap: error.noOverlap)
                }
            }
        }
        headers.append(("Accept-Ranges", "bytes"))
        // 응답마다 하드 링크를 잡아 게시 취소와 응답 전송 사이에도 같은 inode를 연다.
        let lease = snapshotDirectory + "/" + HostIDs.newID("transfer-")
        do { try FileManager.default.linkItem(atPath: file.path, toPath: lease) }
        catch { return failure(HostErrors.make("internal", "파일 전송 사본을 열지 못했습니다.")) }
        return HostResponse(status: status, headers: headers, body: .file(path: lease, offset: offset, count: count), onFinished: { _, _ in
            try? FileManager.default.removeItem(atPath: lease)
        })
    }
    func rangeFailure(headers: [(String, String)], size: UInt64, noOverlap: Bool) -> HostResponse {
        var headers = headers.filter { !["Content-Type", "Cache-Control", "ETag", "Last-Modified"].contains($0.0) }
        if !headers.contains(where: { $0.0 == "X-Content-Type-Options" }) { headers.append(("X-Content-Type-Options", "nosniff")) }
        headers.append(("Content-Type", "text/plain; charset=utf-8"))
        if noOverlap { headers.append(("Content-Range", "bytes */\(size)")) }
        return HostResponse(status: 416, headers: headers, body: .bytes(Array((noOverlap ? "invalid range: failed to overlap\n" : "invalid range\n").utf8)))
    }

    // 여러 구간은 조각씩 임시 파일에 기록해 고정 file 응답 접점으로 보낸다.
    func multipartResponse(_ file: Snapshot, spans: [Range<UInt64>], headers: [(String, String)], head: Bool) -> HostResponse {
        let boundary = (0..<30).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let path = snapshotDirectory + "/" + HostIDs.newID("multipart-")
        var headers = headers.filter { $0.0 != "Content-Type" }
        headers += [("Content-Type", "multipart/byteranges; boundary=" + boundary), ("Accept-Ranges", "bytes")]
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(atPath: path) } }
        do {
            guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw HostErrors.make("internal", "파일 전송 사본을 만들지 못했습니다.")
            }
            let output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? output.close() }
            let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path))
            defer { try? source.close() }
            var length: UInt64 = 0
            for (index, span) in spans.enumerated() {
                let end = span.upperBound == 0 ? "-1" : String(span.upperBound - 1)
                let prefix = (index == 0 ? "" : "\r\n") + "--" + boundary + "\r\nContent-Range: bytes \(span.lowerBound)-" + end + "/\(file.size)\r\nContent-Type: application/octet-stream\r\n\r\n"
                let data = Data(prefix.utf8)
                length += UInt64(data.count) + span.upperBound - span.lowerBound
                if !head {
                    try output.write(contentsOf: data)
                    try source.seek(toOffset: span.lowerBound)
                    var remaining = span.upperBound - span.lowerBound
                    while remaining > 0 {
                        guard let chunk = try source.read(upToCount: Int(min(remaining, 32 << 10))), !chunk.isEmpty else {
                            throw HostErrors.make("internal", "파일을 읽지 못했습니다.")
                        }
                        try output.write(contentsOf: chunk)
                        remaining -= UInt64(chunk.count)
                    }
                }
            }
            let suffix = Data(("\r\n--" + boundary + "--\r\n").utf8)
            length += UInt64(suffix.count)
            if head { try output.truncate(atOffset: length) }
            else { try output.write(contentsOf: suffix) }
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path)
            keep = true
            return HostResponse(status: 206, headers: headers, body: .file(path: path, offset: 0, count: length), onFinished: { _, _ in
                try? FileManager.default.removeItem(atPath: path)
            })
        } catch { return failure(HostErrors.from(error)) }
    }

    struct RangeError: Error { let noOverlap: Bool }
    static func byteRange(_ input: String, size: UInt64) -> Result<Range<UInt64>, RangeError> {
        guard input.hasPrefix("bytes=") else { return .failure(.init(noOverlap: false)) }
        let text = input.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dash = text.firstIndex(of: "-") else { return .failure(.init(noOverlap: false)) }
        let first = text[..<dash].trimmingCharacters(in: .whitespacesAndNewlines)
        let last = text[text.index(after: dash)...].trimmingCharacters(in: .whitespacesAndNewlines)
        func number(_ string: String) -> UInt64? {
            guard !string.isEmpty && string.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt64(string), value <= Int64.max else { return nil }
            return value
        }
        if first.isEmpty {
            guard let suffix = number(last) else { return .failure(.init(noOverlap: false)) }
            let length = min(suffix, size)
            return .success((size - length)..<size)
        }
        guard let start = number(first) else { return .failure(.init(noOverlap: false)) }
        // Go는 시작이 파일 뒤인 범위의 끝 문법을 살피지 않는다.
        guard start < size else { return .failure(.init(noOverlap: true)) }
        if last.isEmpty { return .success(start..<size) }
        guard let end = number(last), start <= end else { return .failure(.init(noOverlap: false)) }
        return .success(start..<(min(end, size - 1) + 1))
    }
}
