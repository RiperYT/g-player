import GPlayerCore
import SwiftUI

/// What the empty library shows while the first run works: what is happening, how big it is, and how far it is.
struct SettingUpView: View {
    let message: String
    let activity: Activity?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gearshape.2").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text("Setting up G-Player…").font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            VStack(spacing: 4) {
                if let p = activity?.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                if let activity { Text(activity.message).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: 320).padding(.vertical, 2)
            Text("You can add a game when that's done.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

/// A one-time note above the games: what is new, or what to do next.
struct LibraryNoteBanner: View {
    @Environment(AppModel.self) private var model
    let note: LibraryNote

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("OK") { model.close(note) }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var symbol: String {
        switch note {
        case .gplayerWine: "sparkles"
        case .storeReady: "checkmark.circle"
        case .setupOnHold: "pause.circle"
        }
    }

    private var title: String {
        switch note {
        case .gplayerWine: "G-Player Wine is new and recommended"
        case .storeReady(let name): "\(name) is ready"
        case .setupOnHold(let pending): FirstRunSetup.pausedNote(pendingSpaces: pending).title
        }
    }

    private var text: String {
        switch note {
        case .gplayerWine: "Spaces you have keep their engine. You can switch a space in its settings."
        case .storeReady(let name): "Open it from All Games, sign in, and your \(name) games appear here."
        case .setupOnHold(let pending): FirstRunSetup.pausedNote(pendingSpaces: pending).text
        }
    }
}
