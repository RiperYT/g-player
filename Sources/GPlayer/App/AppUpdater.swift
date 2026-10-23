import Foundation
import GPlayerCore
import Observation
import Sparkle

/// G-Player's own updates, by Sparkle: it asks GitHub for the appcast, shows its own windows and installs a new version over
/// this one. Sparkle only exists here, and only runs, in a build that carries the key the releases are signed with
/// (`SelfUpdate.isEnabled`): a development build never looks for updates.
@MainActor @Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    /// Sparkle's controller; nil in a build that doesn't update itself.
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// This build updates itself (the menu item and the Settings toggle only exist then).
    private(set) var isEnabled = false
    /// Sparkle can start a check now (not while one is already showing).
    private(set) var canCheck = false
    /// Sparkle asked G-Player to quit to install an update, which the user chose: the question on quitting must not stop it.
    private(set) var isInstalling = false
    /// Checks in the background by itself. Sparkle keeps the answer, and asks for it once itself, the second time G-Player opens.
    var automaticallyChecks = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    /// Starts Sparkle when the bundle has the key; does nothing otherwise.
    func start() {
        let key = Bundle.main.object(forInfoDictionaryKey: SelfUpdate.publicKeyInfoKey) as? String
        guard controller == nil, SelfUpdate.isEnabled(publicKey: key) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        isEnabled = true
        let updater = controller.updater
        canCheck = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyChecks = updater.automaticallyChecksForUpdates }
            },
        ]
    }

    /// "Check for Updates…": shows Sparkle's window, with the answer.
    func check() { controller?.checkForUpdates(nil) }

    // MARK: SPUUpdaterDelegate

    /// The user chose to install: Sparkle's installer is about to ask G-Player to quit, and relaunches it once it has.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { isInstalling = true }

    /// A check or install that ended without quitting (nothing new, a failure, a cancel): quitting asks as usual again.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) { isInstalling = false }
}
