import CoreGraphics
import Foundation
import ImageIO

/// 기기가 보낸 사진을 화면에 보일 그림으로 바꾼다.
///
/// 받은 파일은 이름과 확장자를 믿지 않는다. 파일의 앞머리가 JPEG나 PNG일 때만 풀고, 그 두 형식의 디코더만 쓰며,
/// 원본을 통째로 그리지 않고 긴 변 `maxPixelSize` 픽셀 아래로 줄인 그림만 만든다. 그 밖의 파일은 미리 보이지 않는다.
/// 디코딩은 느릴 수 있으므로 메인 스레드 밖에서 부른다.
public enum ReceivedPicture {
    public enum Format: Sendable, Equatable {
        case jpeg, png

        /// ImageIO가 쓰는 형식 이름.
        var typeIdentifier: String {
            switch self {
            case .jpeg: "public.jpeg"
            case .png: "public.png"
            }
        }
    }

    /// 화면에 보일 그림의 긴 변 한도(픽셀).
    public static let maxPixelSize = 1600
    /// 풀어 볼 파일의 크기 한도(바이트). 코어가 받는 사진과 첨부 하나의 한도(1MB)보다 넉넉하다.
    public static let maxFileBytes = 4 << 20
    /// 풀어 볼 원본의 긴 변 한도(픽셀). 작은 파일이 아주 큰 그림으로 풀리는 것을 막는다.
    public static let maxSourcePixelSize = 20_000

    /// 줄인 그림. `CGImage`는 만든 뒤에 바뀌지 않는다.
    public struct Thumbnail: @unchecked Sendable {
        public let image: CGImage
    }

    /// 앞머리(매직 바이트)로 본 형식. JPEG는 `FF D8 FF`, PNG는 `89 50 4E 47 0D 0A 1A 0A`. 아니면 `nil`.
    public static func format(of data: Data) -> Format? {
        let head = [UInt8](data.prefix(8))
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if head == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        return nil
    }

    /// 파일이 JPEG나 PNG면 줄인 그림을 만든다. 형식이 다르거나, 너무 크거나, 읽을 수 없으면 `nil`.
    public static func thumbnail(at url: URL, maxPixelSize: Int = maxPixelSize) -> Thumbnail? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])).flatMap({ $0.isRegularFile == true ? $0.fileSize : nil }),
              size > 0, size <= maxFileBytes, let data = try? Data(contentsOf: url) else { return nil }
        return thumbnail(of: data, maxPixelSize: maxPixelSize)
    }

    public static func thumbnail(of data: Data, maxPixelSize: Int = maxPixelSize) -> Thumbnail? {
        guard data.count <= maxFileBytes, let format = format(of: data) else { return nil }
        // 형식을 알려 주고, ImageIO가 고른 디코더가 그 형식인지 다시 본다(앞머리만 흉내 낸 다른 형식을 풀지 않는다).
        let hint = [kCGImageSourceTypeIdentifierHint: format.typeIdentifier as CFString, kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, hint),
              (CGImageSourceGetType(source) as String?) == format.typeIdentifier, CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, max(width, height) <= maxSourcePixelSize else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map(Thumbnail.init)
    }
}
