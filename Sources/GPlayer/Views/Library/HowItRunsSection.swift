import GPlayerCore
import SwiftUI

/// "How it runs": a ready-made profile and a few plain switches instead of Wine settings.
/// Shows what G-Player found out about the game and what it does about it.
struct HowItRunsSection: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let space: Space
    @State private var showAdvanced = false

    var body: some View {
        let options = game.launchOptions
        let preview = model.compatPreview(for: game)
        VStack(alignment: .leading, spacing: 12) {
            Text("How it runs").sectionTitle()
            if let diagnoses = model.diagnoses[game.id], !diagnoses.isEmpty {
                ForEach(diagnoses) { DiagnosisBanner(game: game, diagnosis: $0) }
                TryOtherGraphicsButton(game: game)
            }
            if model.changesRefused(for: game) { RefusedChangesNote(space: space) }
            AnalysisLine(game: game)
            if let preview {
                ForEach(preview.blockers + preview.warnings) { NoteRow(note: $0) }
            }
            ProfilePicker(game: game, options: options)
            AutomaticGraphicsRow(game: game)
            OptionToggles(game: game, options: options, fixCount: model.fixes(for: game).filter { $0.macStatus != .broken }.count)
            if let applied = preview?.notes.filter({ $0.kind == .applied }), !applied.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What G-Player does").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(applied) { NoteRow(note: $0) }
                }
            }
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                AdvancedGraphics(game: game, space: space).padding(.top, 6)
            }
            .font(.callout)
        }
    }
}

/// The game's space belongs to another app and the user chose to keep it as it is.
struct RefusedChangesNote: View {
    @Environment(AppModel.self) private var model
    let space: Space

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption)
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(space.name)” is kept as it is").font(.callout.weight(.medium))
                Text("You chose not to let G-Player change this space, so its Windows components, .NET (Wine Mono) for programs that need it, settings, graphics files and Steam's window fix aren't applied.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let preset = AppPresets.preset(space.presetID), let purpose = preset.dotNetReason {
                    Text(WineMono.refusedLine(program: preset.name, purpose: purpose))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button("Allow Changes") { model.setAllowsChanges(true, for: space) }.controlSize(.small)
            }
        }
    }
}

/// "Unity · DirectX 11 · 64-bit", or a button to look.
private struct AnalysisLine: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var working = false

    var body: some View {
        if let a = game.analysis {
            let parts = [a.engineName, a.graphicsLabel,
                         a.isDotNet ? ".NET" : a.architecture?.displayName].compactMap { $0 }
            HStack(spacing: 6) {
                ForEach(parts, id: \.self) { part in
                    Text(part).font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                if parts.isEmpty { Text("Nothing special found").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Button { Task { working = true; await model.analyze(game, force: true); working = false } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless).help("Look at the game's files again").disabled(working)
            }
        } else {
            HStack {
                Text(working ? "Looking at the game's files…" : "Not looked at yet").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Look Now") { Task { working = true; await model.analyze(game, force: true); working = false } }
                    .controlSize(.small).disabled(working)
            }
        }
    }
}

private struct ProfilePicker: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let options: LaunchOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let engine = model.space(game.spaceID).map(model.engineInfo) ?? EngineCatalog.wineStaging
            let shown = options.profile.effective(on: engine)
            Picker("Profile", selection: Binding(get: { shown }, set: { p in
                var o = options; o.profile = p; model.setOptions(o, for: game)
            })) {
                ForEach(LaunchProfile.available(for: engine)) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Label(shown.summary, systemImage: shown.symbol)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "Graphics: DXMT — picked automatically, worked last time", with a way to forget what was learned.
private struct AutomaticGraphicsRow: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        if let choice = model.graphicsChoice(for: game) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label("Graphics: " + choice.summary, systemImage: "display")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if choice.hasLearned {
                    Button("Start Over") { model.forgetGraphics(for: game) }
                        .buttonStyle(.link).controlSize(.small).font(.caption)
                        .help("Forget which graphics worked and which didn't, and start with the best again")
                }
            }
        }
    }
}

private struct OptionToggles: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let options: LaunchOptions
    let fixCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Window", selection: bind(\.windowMode)) {
                ForEach(WindowMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Sharper on Retina displays", isOn: bind(\.retina))
            Toggle("Show frame rate", isOn: bind(\.showFrameRate))
            if fixCount > 0 {
                Toggle("Use \(fixCount == 1 ? "the known fix" : "\(fixCount) known fixes") for this game", isOn: bind(\.useKnownFixes))
            }
        }
        .font(.callout)
        .toggleStyle(.switch).controlSize(.small)
    }

    private func bind<T>(_ key: WritableKeyPath<LaunchOptions, T>) -> Binding<T> {
        Binding(get: { options[keyPath: key] }, set: { v in
            var o = options; o[keyPath: key] = v; model.setOptions(o, for: game)
        })
    }
}

private struct NoteRow: View {
    let note: CompatNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title).font(.callout.weight(note.kind == .applied ? .regular : .medium))
                if let d = note.detail { Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private var icon: String {
        switch note.kind {
        case .blocker: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .applied: "checkmark.circle"
        }
    }
    private var color: Color {
        switch note.kind {
        case .blocker: .red
        case .warning: .orange
        case .applied: .secondary
        }
    }
}

/// What went wrong last time, with one button for the next thing to try.
private struct DiagnosisBanner: View {
    let game: Game
    let diagnosis: Diagnosis

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(diagnosis.title, systemImage: "stethoscope").font(.callout.weight(.semibold))
            Text(diagnosis.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            RemedyButton(game: game, diagnosis: diagnosis, large: false)
            RemedyNote(diagnosis: diagnosis)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The next thing to try for a diagnosis, as one button (nothing when there is nothing to try).
struct RemedyButton: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let diagnosis: Diagnosis
    let large: Bool
    var then: () -> Void = {}

    var body: some View {
        switch diagnosis.remedy {
        case .installComponents(let ids):
            Button(model.isCommonSet(ids) ? "Install Common Windows Parts\(model.sizeLabel(ids)) and Play"
                                          : "Install \(model.componentsLabel(ids)) and Play") {
                model.applyRemedy(diagnosis.remedy, for: game); then()
            }
            .buttonStyle(.borderedProminent).controlSize(large ? .large : .regular)
        case .useProfile(let p):
            Button("Try \(p.title) and Play") { model.applyRemedy(diagnosis.remedy, for: game); then() }
                .buttonStyle(.borderedProminent).controlSize(large ? .large : .regular)
        case .none:
            EmptyView()
        }
    }
}

/// What the common set is, under the button that installs it (nothing for another remedy).
struct RemedyNote: View {
    @Environment(AppModel.self) private var model
    let diagnosis: Diagnosis

    var body: some View {
        if case .installComponents(let ids) = diagnosis.remedy, model.isCommonSet(ids) {
            Text("DirectX 9 and 11 helpers, game audio, controller support, OpenAL and Windows fonts. Many older games need some of these.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// After a failure no log explained (the game closed in seconds, or never opened), a way to try other graphics: the user's
/// word that they are to blame. Nothing shows when there is nothing else to try.
private struct TryOtherGraphicsButton: View {
    @Environment(AppModel.self) private var model
    let game: Game
    var then: () -> Void = {}

    var body: some View {
        if let next = model.graphicsOffer(for: game) {
            Button("Try Other Graphics") { model.tryOtherGraphicsAfterFailure(game); then() }
                .help("Plays the game again with \(next.displayName).")
        }
    }
}

/// After a launch the user just made fails: what happened and what to try, in front of everything.
struct FailedLaunchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: Game

    var body: some View {
        let found = (model.diagnoses[game.id] ?? []).filter { $0.title != AppModel.componentsLaterTitle }
        let otherGraphics = model.graphicsOffer(for: game) != nil
        let remedy = found.first(where: { $0.remedy != .none })
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(game.title)” didn't start").font(.title3.weight(.semibold))
                    Text(found.first?.title ?? "").font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(found) { d in
                Text(d.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let remedy { RemedyNote(diagnosis: remedy) }
            // Both buttons try something else, and they aren't the same thing.
            if otherGraphics, remedy?.remedy == .useProfile(.compatible) {
                Text("Try Other Graphics plays the game again with the next graphics G-Player knows. Try Compatible and Play uses Wine's own graphics, which are slower but start more games.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Show in Library") { model.selectedGameID = game.id; dismiss() }
                Spacer()
                Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                TryOtherGraphicsButton(game: game) { dismiss() }
                if let first = remedy {
                    RemedyButton(game: game, diagnosis: first, large: false) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else if !otherGraphics {
                    // Nothing else to try: the log is what is left to read.
                    Button("Show Log") { model.showLog(for: game) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 580)
    }
}

/// The old graphics picker, for people who want to choose by hand. Choosing one switches to Custom.
private struct AdvancedGraphics: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let space: Space

    var body: some View {
        let info = model.engineInfo(for: space)
        VStack(alignment: .leading, spacing: 6) {
            // A choice the space's engine doesn't have (it was switched) shows as Automatic.
            Picker("Graphics", selection: Binding(get: { info.backends.contains(game.graphics) ? game.graphics : .auto },
                                                  set: { model.setGraphics($0, for: game) })) {
                Text(GraphicsBackend.auto.displayName).tag(GraphicsBackend.auto)
                ForEach(info.backends) { Text($0.displayName).tag($0) }
            }
            Text(info.graphicsHint(for: game.graphics, profile: game.launchOptions.profile))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Choosing graphics here switches the profile to Custom.").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
