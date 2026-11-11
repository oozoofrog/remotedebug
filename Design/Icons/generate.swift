import AppKit

// 저장소 루트에서 실행: swift Design/Icons/generate.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func render(size: Int, mac: Bool, variant: String = "") -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let inset: CGFloat = mac ? 100 : 0
    let rect = NSRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: mac ? 180 : 0, yRadius: mac ? 180 : 0)
    let dark = variant == "dark"
    let tinted = variant == "tinted"
    let top = NSColor(srgbRed: tinted ? 0.24 : 0.08, green: tinted ? 0.24 : 0.24, blue: tinted ? 0.24 : 0.38, alpha: 1)
    let bottom = NSColor(srgbRed: 0.025, green: 0.055, blue: tinted ? 0.055 : 0.14, alpha: 1)
    NSGradient(starting: dark ? bottom : top, ending: bottom)!.draw(in: bg, angle: -90)
    // 양 끝의 꺾쇠는 개발 도구, 가운데 화살표는 빌드 전달 방향을 나타낸다.
    let color = tinted ? NSColor.white : NSColor(srgbRed: 0.32, green: 0.94, blue: 0.84, alpha: 1)
    color.setStroke()
    func stroke(_ points: [NSPoint], _ width: CGFloat) {
        let p = NSBezierPath(); p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: points[0]); for pt in points.dropFirst() { p.line(to: pt) }; p.stroke()
    }
    stroke([NSPoint(x: 350,y: 670), NSPoint(x: 220,y: 512), NSPoint(x: 350,y: 354)], 58)
    stroke([NSPoint(x: 674,y: 670), NSPoint(x: 804,y: 512), NSPoint(x: 674,y: 354)], 58)
    NSColor.white.setStroke()
    if mac {
        stroke([NSPoint(x: 512,y: 338), NSPoint(x: 512,y: 696)], 66)
        stroke([NSPoint(x: 418,y: 598), NSPoint(x: 512,y: 696), NSPoint(x: 606,y: 598)], 66)
    } else {
        stroke([NSPoint(x: 512,y: 696), NSPoint(x: 512,y: 338)], 66)
        stroke([NSPoint(x: 418,y: 436), NSPoint(x: 512,y: 338), NSPoint(x: 606,y: 436)], 66)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for mac in [true, false] {
    let folder = root.appendingPathComponent("Apps/\(mac ? "Mac" : "iOS")/Assets.xcassets")
    let icons = folder.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
    let info: [String: Any] = ["author": "xcode", "version": 1]
    try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
    var images: [[String: Any]] = []
    if mac {
        for size in [16,32,128,256,512] {
            for scale in [1,2] {
                let name = "icon_\(size)x\(size)@\(scale)x.png"
                try render(size: size * scale, mac: true).write(to: icons.appendingPathComponent(name))
                images.append(["filename": name, "idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x"])
            }
        }
    } else {
        for variant in ["", "dark", "tinted"] {
            let name = "icon_1024\(variant.isEmpty ? "" : "_" + variant).png"
            try render(size: 1024, mac: false, variant: variant).write(to: icons.appendingPathComponent(name))
            var entry: [String: Any] = ["filename": name, "idiom": "universal", "platform": "ios", "size": "1024x1024"]
            if !variant.isEmpty { entry["appearances"] = [["appearance": "luminosity", "value": variant]] }
            images.append(entry)
        }
    }
    try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys]).write(to: icons.appendingPathComponent("Contents.json"))
}
