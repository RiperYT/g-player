import GPlayerCore
import SwiftUI

/// Design tokens. Native macOS first: system type, materials and the user's accent colour.
/// The one expressive element is the cover: typographic covers in a space's colour, and the
/// cartridge label strip that says which space and engine a game runs in.
enum Theme {
    static let coverAspect: CGFloat = 2 / 3
    static let coverRadius: CGFloat = 8
    static let tileMinWidth: CGFloat = 148
    static let gridSpacing: CGFloat = 22
    static let pagePadding: CGFloat = 28
    /// A program's icon on a text cover: its size and its distance from the top, as fractions of the cover width.
    static let coverIconScale: CGFloat = 0.44
    static let coverIconTopInset: CGFloat = 0.26
    /// The icon on a launcher tile: its size as a fraction of the tile width, and how far it sits above the centre.
    static let tileIconScale: CGFloat = 0.5
    static let tileIconLift: CGFloat = 10

    static func spaceColor(_ index: Int) -> Color {
        let c = SpaceColor.palette[index % SpaceColor.palette.count]
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    /// Big condensed title used on typographic covers.
    static func coverTitle(size: CGFloat) -> Font { .system(size: size, weight: .heavy).width(.condensed) }
    /// The cartridge label and paths.
    static let label = Font.system(size: 9, weight: .semibold, design: .monospaced)
    static let path = Font.system(size: 11, design: .monospaced)
}

extension Space {
    var color: Color { Theme.spaceColor(colorIndex) }
}

extension Game {
    var symbol: String {
        switch source {
        case .steam: "cloud"
        case .epic: "shippingbox"
        case .executable: kind == .app ? "macwindow" : "gamecontroller"
        }
    }
}

extension View {
    /// The quiet uppercase section title used across the app.
    func sectionTitle() -> some View {
        font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.4)
    }
}
