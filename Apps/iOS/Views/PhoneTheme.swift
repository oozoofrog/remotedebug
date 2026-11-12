import RDModels
import SwiftUI
import UIKit

/// 앱 아이콘과 같은 계열의 색과 모양.
enum PhoneTheme {
    static let tint = Color(red: 0.04, green: 0.55, blue: 0.58)
    static let glow = Color(red: 0.30, green: 0.90, blue: 0.84)
    static let hero = LinearGradient(
        colors: [Color(red: 0.04, green: 0.09, blue: 0.18), Color(red: 0.05, green: 0.24, blue: 0.34), Color(red: 0.04, green: 0.40, blue: 0.44)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// 화면 맨 위의 판: 앱 표시와 지금 연결된 Mac.
struct PhoneHero: View {
    var hostName: String?

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.12))
                .frame(width: 54, height: 54)
                .overlay {
                    HStack(spacing: 1) {
                        Image(systemName: "chevron.left").foregroundStyle(PhoneTheme.glow)
                        Image(systemName: "arrow.down").foregroundStyle(.white)
                        Image(systemName: "chevron.right").foregroundStyle(PhoneTheme.glow)
                    }
                    .font(.system(size: 16, weight: .heavy))
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("RemoteDebug")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Label(hostName ?? "페어링한 Mac 없음", systemImage: hostName == nil ? "desktopcomputer.trianglebadge.exclamationmark" : "desktopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(PhoneTheme.hero)
                .overlay(alignment: .trailing) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 110, weight: .black))
                        .foregroundStyle(.white.opacity(0.06))
                        .offset(x: 24)
                        .accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }
}

/// 이름 첫 글자를 넣은 앱 타일. 색은 번들 ID에서 정해져 같은 앱은 늘 같은 색이다.
struct PhoneAppTile: View {
    let name: String
    let seed: String
    var size: CGFloat = 48

    private var hue: Double {
        Double(seed.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.92),
                                          Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.62)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Mac이 빌드 정보에 담아 보낸 앱 아이콘. 없거나 읽지 못하면 색 타일을 보여 준다.
struct PhoneBuildIcon: View {
    let build: BuildDescriptor
    var size: CGFloat = 48

    var body: some View {
        if let image = Self.image(for: build) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                .accessibilityHidden(true)
        } else {
            PhoneAppTile(name: build.displayName, seed: build.bundleId, size: size)
        }
    }

    /// 화면은 설치 진행을 1초마다 다시 그리므로 빌드 id별로 한 번만 디코딩한다.
    @MainActor private static let cache = NSCache<NSString, UIImage>()

    @MainActor private static func image(for build: BuildDescriptor) -> UIImage? {
        guard let data = build.icon else { return nil }
        let key = build.id as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
