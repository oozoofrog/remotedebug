import CoreGraphics
import Foundation
import ImageIO
import RDModels
import Testing
import UniformTypeIdentifiers
@testable import MacHostKit

@Suite struct AppIconFileTests {
    /// 한 색으로 채운 정사각형 PNG.
    private func png(side: Int) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func makeApp(in dir: TempDir, iconFiles: [String]?, files: [String: Data]) throws -> URL {
        let app = dir.path("Icon.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "com.example.icon"]
        if let iconFiles {
            plist["CFBundleIcons"] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": iconFiles]]
        }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        for (name, data) in files { try data.write(to: app.appendingPathComponent(name)) }
        return app
    }

    @Test func publishesLargestIconAsSmallStandardPNG() throws {
        let dir = try TempDir("icon")
        let app = try makeApp(in: dir, iconFiles: ["AppIcon60x60"], files: [
            "AppIcon60x60@2x.png": try png(side: 120),
            "AppIcon60x60@3x.png": try png(side: 180),
            "Other.png": try png(side: 512),
        ])
        #expect(AppIconFile.load(appPath: app.path)?.width == 180)
        let data = try #require(AppIconFile.publishedPNG(appPath: app.path))
        #expect(BuildDescriptor.isPNG(data))
        #expect(data.count <= BuildDescriptor.maxIconBytes)
        let image = try #require(AppIconFile.decode(data))
        #expect(image.width == AppIconFile.publishedSide && image.height == AppIconFile.publishedSide)
    }

    @Test func nothingWithoutDeclaredIcon() throws {
        let dir = try TempDir("noicon")
        let app = try makeApp(in: dir, iconFiles: nil, files: ["AppIcon60x60@2x.png": try png(side: 120)])
        #expect(AppIconFile.publishedPNG(appPath: app.path) == nil)
        #expect(AppIconFile.publishedPNG(appPath: dir.path("Missing.app").path) == nil)
        #expect(AppIconFile.publishedPNG(appPath: dir.path("Build.ipa").path) == nil)
    }
}
