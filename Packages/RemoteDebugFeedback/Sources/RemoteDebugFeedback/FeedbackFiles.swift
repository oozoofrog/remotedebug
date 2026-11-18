import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 사용자가 피드백에 붙인 사진이나 파일 하나. 보낼 때까지 메모리에만 둔다.
public struct FeedbackFile: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let name: String
    /// MIME 종류.
    public let type: String
    public let data: Data

    public init(name: String, type: String = "application/octet-stream", data: Data) {
        self.name = name
        self.type = type
        self.data = data
    }

    public var isImage: Bool { type.hasPrefix("image/") }
}

/// 피드백 하나에 붙는 사진과 파일. 수와 크기에 한도가 있어 기록이 끝없이 커지지 않는다.
///
/// 한도는 Mac의 `POST /v1/crashes` 본문 한도 4MiB에 맞춘 것이다: 첨부 합계 1536KiB는 base64로 2MiB,
/// 여기에 글(1536KiB까지)을 더해도 4MiB 안이다.
public struct FeedbackFiles: Equatable, Sendable {
    /// 붙일 수 있는 수.
    public static let maxCount = 5
    /// 파일 하나의 크기 한도(바이트). 넘는 파일은 자르지 않고 받지 않는다.
    public static let maxBytes = 1 << 20
    /// 모두 합친 크기 한도(바이트).
    public static let maxTotalBytes = 1536 << 10
    /// 사진 한 장을 줄여 맞추는 크기(바이트). 다섯 장을 붙여도 합계 한도에 들어간다.
    public static let maxImageBytes = 300 << 10
    /// 줄이려고 읽는 사진 파일의 크기 한도(바이트).
    static let maxSourceImageBytes = 50 << 20

    public enum Refusal: Error, Equatable, Sendable {
        case tooMany, tooLarge, totalTooLarge, unreadable
    }

    public private(set) var items: [FeedbackFile] = []
    private var photoNumber = 0

    public init() {}

    public var totalBytes: Int { items.reduce(0) { $0 + $1.data.count } }
    public var isFull: Bool { items.count >= Self.maxCount }

    /// 한도 안이면 붙인다.
    public mutating func add(_ file: FeedbackFile) throws(Refusal) {
        guard !isFull else { throw .tooMany }
        guard !file.data.isEmpty else { throw .unreadable }
        guard file.data.count <= Self.maxBytes else { throw .tooLarge }
        guard totalBytes + file.data.count <= Self.maxTotalBytes else { throw .totalTooLarge }
        items.append(file)
    }

    /// 사진을 줄여서 붙인다. 다시 인코딩하면서 위치 같은 사진 정보는 빠진다. `name`이 없으면 `photo-N.jpg`.
    public mutating func addImage(_ data: Data, name: String? = nil) throws(Refusal) {
        guard !isFull else { throw .tooMany }
        guard let jpeg = Self.shrunk(data) else { throw .unreadable }
        var fileName = name.map { ($0 as NSString).deletingPathExtension + ".jpg" }
        if fileName == nil {
            photoNumber += 1
            fileName = "photo-\(photoNumber).jpg"
        }
        try add(FeedbackFile(name: fileName ?? "photo.jpg", type: "image/jpeg", data: jpeg))
    }

    /// 사용자가 고른 파일을 읽어 붙인다. 다른 곳에 복사해 두지 않는다. 사진 파일은 줄이고, 나머지는 크기를 먼저 보고 읽는다.
    public mutating func addFile(at url: URL) throws(Refusal) {
        guard !isFull else { throw .tooMany }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { throw .unreadable }
        if type?.conforms(to: .image) == true, size <= Self.maxSourceImageBytes, let data = try? Data(contentsOf: url),
           Self.shrunk(data) != nil {
            try addImage(data, name: url.lastPathComponent)
            return
        }
        guard size <= Self.maxBytes else { throw .tooLarge }
        guard totalBytes + size <= Self.maxTotalBytes else { throw .totalTooLarge }
        guard let data = try? Data(contentsOf: url) else { throw .unreadable }
        try add(FeedbackFile(name: url.lastPathComponent, type: type?.preferredMIMEType ?? "application/octet-stream", data: data))
    }

    public mutating func remove(_ id: FeedbackFile.ID) {
        items.removeAll { $0.id == id }
    }

    /// 긴 변을 1600픽셀 아래로 줄인 JPEG. `maxBytes`에 들어올 때까지 품질과 크기를 낮추고, 그래도 넘으면 `nil`.
    static func shrunk(_ data: Data, maxBytes: Int = maxImageBytes) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        for side in [1600, 1200, 800, 480] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: side]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            for quality in [0.7, 0.5, 0.3] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { return nil }
                if output.count <= maxBytes { return output as Data }
            }
        }
        return nil
    }
}
