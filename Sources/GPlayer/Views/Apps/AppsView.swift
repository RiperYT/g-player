import GPlayerCore
import SwiftUI

/// One-click setup for store launchers. Each gets its own space.
struct AppsView: View {
    @Environment(AppModel.self) private var model

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
                        PresetCard(preset: preset, badge: preset.id == AppPresets.epic.id ? EpicWay.launcher.badge : nil)
                        // Next to Epic's launcher, the other way to Epic's games.
                        if preset.id == AppPresets.epic.id { EpicGamesCard() }
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
    @Environment(AppModel.self) private var model
    let preset: AppPreset
    /// A label that tells it from the other ways to the same store ("Recommended").
    var badge: String? = nil

    var body: some View {
        let installed = model.isInstalled(preset)
        let busy = model.isInstalling(preset)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: preset.symbol).font(.system(size: 22, weight: .regular))
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(preset.name).font(.headline)
                    if let badge { CardBadge(text: badge, tint: .accentColor) }
                    if preset.experimental { CardBadge(text: "Experimental", tint: .orange) }
                }
                Text(preset.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Epic's games without Epic's launcher, through Legendary: the other way to Epic next to the launcher.
private struct EpicGamesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "bolt").font(.system(size: 22, weight: .regular))
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(EpicWay.legendary.title).font(.headline)
                    CardBadge(text: EpicWay.legendary.badge, tint: .secondary)
                }
                Text(EpicWay.legendary.detail)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open") { model.selection = .epic }
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
