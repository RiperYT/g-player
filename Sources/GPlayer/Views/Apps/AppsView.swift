import GPlayerCore
import SwiftUI

/// One-click setup for store launchers. Each gets its own space. Epic's games without its launcher open over this list.
struct AppsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.appsPath) {
            AppsList()
                .navigationDestination(for: AppsDestination.self) { destination in
                    switch destination {
                    case .epicLibrary: EpicView()
                    }
                }
        }
    }
}

private struct AppsList: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Get Apps").font(.largeTitle.weight(.semibold))
                    Text("Each app gets its own space. Games you install through it show up in your library.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(AppPresets.all) { preset in
                        // Epic has two ways, in one card: its own launcher, and its games without it.
                        if preset.id == AppPresets.epic.id { EpicCard() } else { PresetCard(preset: preset) }
                    }
                }
                Text("Experimental apps install, but haven't been checked from start to finish on Apple Silicon yet. Games with kernel anti-cheat (EasyAntiCheat, BattlEye, Vanguard) don't run under Wine.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 620, alignment: .leading)
            }
            .padding(Theme.pagePadding)
        }
        .navigationTitle("Get Apps")
    }
}

struct PresetCard: View {
    let preset: AppPreset

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CardSymbol(name: preset.symbol)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(preset.name).font(.headline)
                    if preset.experimental { CardBadge(text: "Experimental", tint: .orange) }
                }
                Text(preset.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                PresetButtons(preset: preset).padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Install, or Open and Show Space once the app is set up.
private struct PresetButtons: View {
    @Environment(AppModel.self) private var model
    let preset: AppPreset

    var body: some View {
        let installed = model.isInstalled(preset)
        let busy = model.isInstalling(preset)
        HStack {
            if installed {
                Button("Open") { model.openLauncher(of: preset) }
                    .buttonStyle(.borderedProminent)
                Button("Show Space") { if let s = model.presetSpace(preset) { model.selection = .space(s.id) } }
            } else {
                Button(busy ? "Installing…" : "Install") { Task { await model.installPreset(preset) } }
                    .buttonStyle(.borderedProminent).disabled(busy)
            }
        }
    }
}

private struct CardSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name).font(.system(size: 22, weight: .regular))
            .frame(width: 44, height: 44)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Epic Games, one card with its two ways: Epic's own launcher (recommended), and the games without it, through Legendary.
private struct EpicCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CardSymbol(name: AppPresets.epic.symbol)
            VStack(alignment: .leading, spacing: 12) {
                Text("Epic Games").font(.headline)
                EpicWayRow(way: .launcher) { PresetButtons(preset: AppPresets.epic) }
                Divider()
                EpicWayRow(way: .legendary) { OpenEpicLibraryButton() }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One way to Epic's games: what it is called, what it trades, and its buttons.
private struct EpicWayRow<Buttons: View>: View {
    let way: EpicWay
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(way.title).font(.callout.weight(.semibold))
                CardBadge(text: way.badge, tint: way == .launcher ? .accentColor : .secondary)
            }
            Text(way.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons.padding(.top, 2)
        }
    }
}

private struct OpenEpicLibraryButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Open…") { model.openEpicLibrary() }
    }
}

/// A small label next to a title: "Recommended", "Alternative", "Experimental".
struct CardBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2).background(tint.opacity(0.12), in: Capsule())
    }
}
