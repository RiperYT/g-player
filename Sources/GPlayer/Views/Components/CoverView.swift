import GPlayerCore
import SwiftUI

/// A game's cover: its art, or a typographic cover in the space's colour. The cartridge label
/// along the bottom names the space and engine.
struct CoverView: View {
    @Environment(AppModel.self) private var model
    let game: Game
    var showLabel = true
    var hovering = false

    var body: some View {
        let space = model.space(game.spaceID)
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                if let image = model.coverImage(for: game) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                } else if game.kind == .app {
                    AppIconTile(icon: model.iconImage(for: game), color: space?.color ?? .gray, symbol: game.symbol,
                                width: geo.size.width)
                } else {
                    TypographicCover(title: game.title, color: space?.color ?? .gray, symbol: game.symbol,
                                     icon: model.iconImage(for: game), width: geo.size.width)
                }
                if showLabel, let space { CartridgeLabel(space: space, game: game, running: model.isRunning(game)) }
            }
        }
        .aspectRatio(game.kind == .app ? 1 : Theme.coverAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.coverRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.coverRadius, style: .continuous)
            .strokeBorder(.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
    }
}

struct TypographicCover: View {
    let title: String
    let color: Color
    let symbol: String
    var icon: NSImage? = nil
    let width: CGFloat

    var body: some View {
        let size = max(18, min(34, width / 5.2))
        ZStack(alignment: .topLeading) {
            color
            // A soft fold of darker colour at the bottom, so the title sits on something.
            LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .center, endPoint: .bottom)
            if let icon {
                // The program's own icon, centred in the upper part of the cover.
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: width * Theme.coverIconScale, height: width * Theme.coverIconScale)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    .frame(maxWidth: .infinity).padding(.top, width * Theme.coverIconTopInset)
            }
            VStack(alignment: .leading, spacing: 0) {
                if icon == nil {
                    Image(systemName: symbol).font(.system(size: size * 0.55, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                Text(title)
                    .font(Theme.coverTitle(size: size))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineSpacing(-size * 0.18)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                    .padding(.bottom, 26)
            }
            .padding(.horizontal, 14).padding(.top, 14)
        }
    }
}

/// A launcher (Steam, Epic…): a square tile with the program's icon, like an app on the Mac.
struct AppIconTile: View {
    let icon: NSImage?
    let color: Color
    let symbol: String
    let width: CGFloat

    var body: some View {
        ZStack {
            color
            LinearGradient(colors: [.white.opacity(0.08), .black.opacity(0.18)], startPoint: .top, endPoint: .bottom)
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                } else {
                    Image(systemName: symbol).resizable().aspectRatio(contentMode: .fit)
                        .fontWeight(.light).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: width * Theme.tileIconScale, height: width * Theme.tileIconScale)
            .offset(y: -Theme.tileIconLift)
        }
    }
}

/// The strip at the bottom of every cover: SPACE · ENGINE, or RUNNING.
struct CartridgeLabel: View {
    @Environment(AppModel.self) private var model
    let space: Space
    let game: Game
    let running: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(running ? Color.green : space.color).frame(width: 5, height: 5)
            Text(running ? "RUNNING" : "\(space.name) · \(engineName)")
                .font(Theme.label).tracking(0.6).lineLimit(1)
            Spacer(minLength: 0)
        }
        .textCase(.uppercase)
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 9).frame(height: 20)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.42))
    }

    private var engineName: String {
        guard let info = EngineCatalog.info(space.engineID) else { return "?" }
        // G-Player Wine's own number (11.0) would look older than Wine Staging's (11.18) on the strip.
        return info.kind == .gptk ? "D3DMetal" : info.kind == .crossover ? "G-Player" : "Wine \(info.version)"
    }
}
