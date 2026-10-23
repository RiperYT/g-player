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
                    EpicGamesCard()
                    ForEach(AppPresets.all) { PresetCard(preset: $0) }
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
                    if preset.experimental {
                        Text("Experimental").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.orange.opacity(0.12), in: Capsule())
                    }
                }
                Text(preset.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if installed {
                        Button("Open") {
                            if let s = model.presetSpace(preset),
                               let g = model.games.first(where: { $0.spaceID == s.id && $0.kind == .app }) { model.play(g) }
                        }
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

/// Epic's store through Legendary: the way G-Player recommends, since Epic's own launcher stops at its loading screen under Wine.
private struct EpicGamesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "shippingbox").font(.system(size: 22, weight: .regular))
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Epic Games").font(.headline)
                    Text("Recommended").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Text("Sign in with your Epic account and install your games without Epic's launcher, with Legendary, an open-source Epic client.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open") { model.selection = .epic }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
