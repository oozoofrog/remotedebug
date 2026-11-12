import CoreGraphics
import Foundation
import ImageIO
import RDModels
import UniformTypeIdentifiers

/// iOS 앱 번들 안의 기본 아이콘.
public enum AppIconFile {
    /// 게시할 때 빌드 정보에 담는 아이콘의 한 변 길이(픽셀).
    public static let publishedSide = 120

    /// `Info.plist`의 `CFBundleIcons > CFBundlePrimaryIcon > CFBundleIconFiles`가 가리키는 PNG 가운데 가장 큰 것.
    public static func load(appPath: String) -> CGImage? {
        let app = URL(fileURLWithPath: appPath)
        guard app.pathExtension.lowercased() == "app",
              let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let icons = plist["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let names = primary["CFBundleIconFiles"] as? [String],
              let files = try? FileManager.default.contentsOfDirectory(atPath: appPath)
        else { return nil }
        // 번들 폴더에 실제로 있는 파일 이름만 쓴다(plist의 이름을 경로로 쓰지 않는다).
        let candidates = files.filter { file in
            file.lowercased().hasSuffix(".png") && names.contains { !$0.isEmpty && file.hasPrefix($0) }
        }
        var best: CGImage?
        for file in candidates {
            guard let image = decode(contentsOf: app.appendingPathComponent(file)) else { continue }
            if image.width > (best?.width ?? 0) { best = image }
        }
        return best
    }

    /// 빌드 정보에 담을 아이콘: 가장 큰 아이콘을 `publishedSide` 픽셀 정사각형의 표준 PNG로 다시 쓴다.
    /// Xcode가 iOS용으로 바꾼 PNG(CgBI)는 iPhone 밖에서 읽지 못하는 곳이 있어서 그대로 보내지 않는다.
    /// 아이콘이 없거나 `BuildDescriptor.maxIconBytes`를 넘으면 `nil`.
    public static func publishedPNG(appPath: String) -> Data? {
        guard let image = load(appPath: appPath) else { return nil }
        let side = publishedSide
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let data = out as Data
        guard data.count <= BuildDescriptor.maxIconBytes, BuildDescriptor.isPNG(data) else { return nil }
        return data
    }

    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func decode(contentsOf url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
