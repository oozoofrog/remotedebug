import MacHostKit
import SwiftUI

/// 앱 아이콘과 같은 계열의 색.
enum RDTheme {
    /// 버튼·선택 표시에 쓰는 청록(밝은 배경에서 글자가 읽히는 농도).
    static let tint = Color(red: 0.04, green: 0.55, blue: 0.58)
    /// 어두운 바탕 위의 밝은 청록.
    static let glow = Color(red: 0.30, green: 0.90, blue: 0.84)
    static let navy = Color(red: 0.04, green: 0.09, blue: 0.18)
    static let deep = Color(red: 0.05, green: 0.24, blue: 0.34)

    static let hero = LinearGradient(colors: [navy, deep, Color(red: 0.04, green: 0.40, blue: 0.44)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
}

extension View {
    /// 목록 안의 카드. 구분선과 기본 배경을 없애고 둥근 판 위에 올린다.
    func rdCard(padding: CGFloat = 16) -> some View {
        rdCardSurface(padding: padding).rdListRow()
    }

    /// 카드의 둥근 판. `fillHeight`면 같은 줄의 다른 카드와 높이를 맞춘다.
    func rdCardSurface(padding: CGFloat = 16, fillHeight: Bool = false) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(.background.secondary, in: RDTheme.cardShape)
            .overlay(RDTheme.cardShape.strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }

    /// 카드를 담는 목록 줄: 구분선과 기본 배경을 없앤다.
    func rdListRow() -> some View {
        self.listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 5, leading: 4, bottom: 5, trailing: 4))
    }
}

/// 게시한 앱의 실제 아이콘. 원본 `.app`에서 읽지 못하면(`.ipa` 원본, 원본이 사라짐, 아이콘 없음) 색 타일을 보여 준다.
struct BuildIcon: View {
    let name: String
    let seed: String
    /// 빌드 정보에 담긴 아이콘. 없으면 원본 `.app`에서 읽는다(아이콘을 담기 전에 게시한 빌드).
    var icon: Data?
    let sourcePath: String
    var size: CGFloat = 46

    @State private var image: CGImage?
    private var embedded: Data? { icon }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
                    .transition(.opacity)
            } else {
                AppTile(name: name, seed: seed, size: size)
            }
        }
        .task(id: sourcePath) {
            let path = sourcePath, data = embedded
            image = await Task.detached(priority: .utility) {
                data.flatMap(AppIconFile.decode) ?? AppIconFile.load(appPath: path)
            }.value
        }
    }
}

/// 앱 아이콘 모양(꺾쇠와 위쪽 화살표). 사이드바 위에 쓴다.
struct AppMark: View {
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(RDTheme.hero)
            .overlay {
                HStack(spacing: size * 0.02) {
                    Image(systemName: "chevron.left").foregroundStyle(RDTheme.glow)
                    Image(systemName: "arrow.up").foregroundStyle(.white)
                    Image(systemName: "chevron.right").foregroundStyle(RDTheme.glow)
                }
                .font(.system(size: size * 0.30, weight: .heavy))
            }
            .frame(width: size, height: size)
            .shadow(color: RDTheme.deep.opacity(0.35), radius: size * 0.12, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

/// 이름 첫 글자를 넣은 앱 타일. 색은 식별자에서 정해져 같은 앱은 늘 같은 색이다.
struct AppTile: View {
    let name: String
    let seed: String
    var size: CGFloat = 46
    var symbol: String?

    private var hue: Double {
        // 실행마다 같은 값이 나오게 직접 더한다(String.hashValue는 실행마다 다르다).
        Double(seed.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.92),
                                          Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.62)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Group {
                    if let symbol {
                        Image(systemName: symbol)
                    } else {
                        Text(String(name.prefix(1)).uppercased())
                    }
                }
                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 짧은 속성 표시(구성, 스킴 등).
struct Chip: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}
