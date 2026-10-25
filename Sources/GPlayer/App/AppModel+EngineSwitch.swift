import Foundation
import GPlayerCore

/// Switching the engine of a space from its own page.
extension AppModel {
    /// What switching a space to `info` downloads first, in bytes: nothing when it is installed.
    func downloadSize(of info: EngineInfo) -> Int64 {
        isInstalled(info) ? 0 : info.downloadBytes(wineStagingInstalled: isInstalled(EngineCatalog.wineStaging))
    }

    /// True while a program runs in a game's place in the space.
    func hasRunningGames(in space: Space) -> Bool {
        state.games(in: space).contains { isRunning($0) }
    }

    /// Switches the space to `info` once the user has confirmed. The engine downloads first (nothing changes if that
    /// fails), and nothing may run in the space: a newer Wine updates its files on the first start. A space that belongs
    /// to another app follows the same rule as everything else G-Player changes in one: ask first, and not at all after a no.
    func switchEngine(of space: Space, to info: EngineInfo) {
        guard let current = self.space(space.id), current.engineID != info.id, !movingSpaces.contains(current.id) else { return }
        if !current.mayChange {
            guard current.allowsChanges == nil else {
                errorMessage = String(localized: "G-Player doesn't change “\(current.name)”: you said so. Allow changes in the space's settings first.")
                return
            }
            askToChange(current) { [weak self] allowed in if allowed { self?.switchEngine(of: current, to: info) } }
            return
        }
        movingSpaces.insert(current.id)
        Task {
            defer { movingSpaces.remove(current.id) }
            if !isInstalled(info), await ensureEngine(info) == nil { return }
            if await Self.isBusy(current) {
                errorMessage = EngineSwitch.busyMessage(space: current.name)
                return
            }
            guard var latest = self.space(current.id) else { return }
            // From the old revision of an engine to its newer one it is the move the app makes by itself: what G-Player learned
            // about the games' graphics goes with the space.
            if let move = EngineMigration.switchBetweenRevisions(of: latest, to: info) {
                moveSpaces([move], userAsked: true)
                return
            }
            latest.engineID = info.id
            update(latest)
        }
    }
}
