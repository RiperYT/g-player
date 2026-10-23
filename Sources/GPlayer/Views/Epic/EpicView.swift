import GPlayerCore
import SwiftUI

/// Epic Games without Epic's launcher: who is signed in, the games the account owns, and Install, Play and Uninstall for each.
struct EpicView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Epic Games").font(.largeTitle.weight(.semibold))
                    Text("Legendary is an open-source Epic client not made by Epic. Games with anti-cheat (EasyAntiCheat, BattlEye) don't run on a Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let account = model.epic.account {
                    EpicAccountRow(account: account)
                    EpicGameList(search: search)
                } else if !model.epic.looked {
                    ProgressView().controlSize(.small)
                } else {
                    EpicSignedOut()
                }
            }
            .padding(Theme.pagePadding)
        }
        .navigationTitle("Epic Games")
        .searchable(text: $search, placement: .toolbar, prompt: "Search Epic games")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refreshEpicList() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Ask Epic for your games")
                    .disabled(!model.epic.isSignedIn || model.epic.isOccupied)
            }
        }
        .onAppear { model.openEpicPage() }
    }
}

/// Nobody is signed in: what signing in does, and the button.
private struct EpicSignedOut: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sign in to install your Epic games", systemImage: "person.crop.circle").font(.headline)
            Text("G-Player opens Epic's own sign-in page. You sign in there, with Epic, Google, Apple or whatever you use: your password goes to Epic and never to G-Player. Games install without Epic's launcher, which doesn't run under Wine yet.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(model.epic.busy == nil ? "Sign In…" : "Getting Legendary…") { model.beginEpicSignIn() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.epic.isOccupied)
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "Signed in as …" and Sign Out.
private struct EpicAccountRow: View {
    @Environment(AppModel.self) private var model
    let account: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
            Text("Signed in as **\(account)**").font(.callout)
            Spacer(minLength: 12)
            Button("Sign Out") { model.signOutOfEpic() }
                .disabled(model.epic.isOccupied)
                .help("Forgets the sign-in on this Mac. Installed games stay.")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The games the account owns: the installed ones first.
private struct EpicGameList: View {
    @Environment(AppModel.self) private var model
    let search: String

    private var shown: [EpicGame] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? model.epic.games : model.epic.games.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        if let failure = model.epic.refreshFailure {
            EpicListFailure(text: failure)
        } else if !model.epic.fetched && model.epic.games.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Getting your games…").foregroundStyle(.secondary) }
        } else if model.epic.games.isEmpty {
            ContentUnavailableView("No games found", systemImage: "shippingbox",
                                   description: Text("Epic lists no Windows games for this account. Refresh to ask again."))
        } else if shown.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            let installed = shown.filter { model.epicGame(for: $0) != nil }, others = shown.filter { model.epicGame(for: $0) == nil }
            if !installed.isEmpty { EpicSection(title: "Installed", games: installed) }
            if !others.isEmpty { EpicSection(title: "Not installed", games: others) }
        }
    }
}

private struct EpicSection: View {
    let title: String
    let games: [EpicGame]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).sectionTitle()
            LazyVStack(spacing: 8) {
                ForEach(games) { EpicGameRow(game: $0) }
            }
        }
    }
}

/// The list couldn't be fetched: why, and the way on.
private struct EpicListFailure: View {
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PathWarning(text: text)
            if text == LegendaryFailure.signedOutMessage {
                Button("Sign In…") { model.beginEpicSignIn() }.buttonStyle(.borderedProminent).disabled(model.epic.isOccupied)
            } else {
                Button("Try Again") { Task { await model.refreshEpicList() } }.disabled(model.epic.isOccupied)
            }
        }
    }
}

private struct EpicGameRow: View {
    @Environment(AppModel.self) private var model
    let game: EpicGame

    var body: some View {
        let entry = model.epicGame(for: game)
        HStack(spacing: 14) {
            EpicCover(url: game.coverURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let entry { installedButtons(entry) } else { installButton }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func subtitle(_ entry: Game?) -> String {
        if model.epic.installing == game.appName { return "Installing…" }
        guard let entry else { return "Not installed" }
        if model.isPreparing(entry) { return "Starting…" }
        if model.isRunning(entry) { return "Running" }
        return model.epic.installed[game.appName].map { $0.installSize > 0 ? "Installed · \($0.installSize.formattedBytes)" : "Installed" } ?? "Installed"
    }

    @ViewBuilder private var installButton: some View {
        if model.epic.installing == game.appName {
            ProgressView().controlSize(.small)
        } else {
            Button("Install") { model.installEpicGame(game) }
                .buttonStyle(.borderedProminent)
                .disabled(model.epic.isOccupied)
                .help(model.epic.busy.map { "Wait for “\($0)” to finish. Epic installs one at a time." } ?? "Download and install")
        }
    }

    @ViewBuilder private func installedButtons(_ entry: Game) -> some View {
        Button(model.isRunning(entry) ? "Stop" : "Play") { model.isRunning(entry) ? model.stop(entry) : model.play(entry) }
            .buttonStyle(.borderedProminent)
            .disabled(model.isPreparing(entry))
        Button("Uninstall…") { model.gamePendingUninstall = entry }
            .disabled(model.epic.isOccupied || model.isRunning(entry))
    }
}

/// A game's box art from Epic's CDN, or a plain tile while it loads or when there is none.
private struct EpicCover: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
            default: Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
            }
        }
        .frame(width: 42, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }
}
