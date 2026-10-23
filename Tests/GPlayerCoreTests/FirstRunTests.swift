import Foundation
import Testing
@testable import GPlayerCore

/// What a newcomer is told: the figures of the first run, what the library says while it works, what to know before
/// bringing bottles over, what switching an engine means, and what the graphics words promise.
@Suite struct FirstRunTests {
    let staging = EngineCatalog.wineStaging
    let gplayerWine = EngineCatalog.crossover

    // MARK: Sizes

    // What the screens say, worked out here from the pinned sizes: G-Player Wine's archive is pinned when it is published,
    // and the figures follow it. On a clean Mac G-Player Wine downloads Gcenx's archive for its libraries too; a Wine
    // Staging that is installed already has them, so those aren't downloaded.
    private func megabytes(_ downloads: [PinnedDownload]) -> Int { EngineCatalog.megabytes(downloads.reduce(0) { $0 + $1.approximateBytes }) }
    private var withoutLibraries: [PinnedDownload] { gplayerWine.downloads.filter { $0.role != .runtimeLibraries } }
    private var stagingInstalledMB: Int { megabytes(withoutLibraries) }
    private var downloadMB: Int { megabytes(gplayerWine.downloads) }

    @Test func sizesAreRoundedNotCutOff() {
        #expect(EngineCatalog.megabytes(484_886_864) == 485)
        #expect(EngineCatalog.megabytes(287_881_528) == 288)
        #expect(EngineCatalog.megabytes(499_999) == 0)
        #expect(EngineCatalog.megabytes(500_000) == 1)
        // The engine of the first run: the figure the screens say.
        #expect(EngineCatalog.megabytes(EngineCatalog.firstRunBytes(installed: [])) == downloadMB)
        #expect(EngineCatalog.megabytes(gplayerWine.downloadBytes(wineStagingInstalled: true)) == stagingInstalledMB)
        #expect(EngineCatalog.megabytes(staging.downloadBytes(wineStagingInstalled: false)) == 197)
    }

    @Test func theEngineStepSaysTheDownloadAndTheDisk() {
        #expect(FirstRunSetup.engineSizes(installed: []) ==
                "The download is about \(downloadMB) MB, and G-Player Wine needs about 2.6 GB on this disk. G-Player checks every file before it uses it.")
        // With a Wine Staging that an earlier version installed, it says what is left, so the figure never looks like the whole.
        #expect(FirstRunSetup.engineSizes(installed: [staging])?.hasPrefix("\(stagingInstalledMB) MB is still to download") == true)
        #expect(FirstRunSetup.engineSizes(installed: [gplayerWine]) == nil)
        #expect(FirstRunSetup.engineSizes(installed: [staging, gplayerWine]) == nil)
        #expect(FirstRunSetup.diskBytes == EngineCatalog.firstRunDiskBytes(installed: []))
    }

    @Test func continueSaysItStartsTheDownloads() {
        #expect(FirstRunSetup.continueNote(installed: []) == "Continue downloads about \(downloadMB) MB and needs about 2.6 GB on this disk.")
        #expect(FirstRunSetup.continueNote(installed: [staging]) == "Continue downloads \(stagingInstalledMB) MB more and needs about 2.6 GB on this disk.")
        #expect(FirstRunSetup.continueNote(installed: [gplayerWine]) == nil)
    }

    // MARK: The library while the first run works

    @Test func theLibraryTellsWhatTheFirstRunDoes() {
        func status(_ installed: [EngineInfo], downloading: Bool = false, _ pending: [String]) -> String? {
            FirstRunSetup.libraryStatus(installed: installed, downloading: downloading, pendingSpaces: pending)
        }
        #expect(status([], downloading: true, ["main", "steam"])
                == "G-Player is downloading G-Player Wine, about \(downloadMB) MB. Then it sets up Main and Steam.")
        #expect(status([], downloading: true, []) == "G-Player is downloading G-Player Wine, about \(downloadMB) MB.")
        #expect(status([staging], downloading: true, ["main"]) == "G-Player is downloading G-Player Wine, about \(stagingInstalledMB) MB. Then it sets up Main.")
        #expect(status([gplayerWine], downloading: true, ["steam"]) == "G-Player Wine is almost ready. Then it sets up Steam.")
        // G-Player Wine is in: the spaces are made.
        #expect(status([gplayerWine], ["main", "steam"])?.hasPrefix("G-Player is getting Windows ready for Main and installing Steam.") == true)
        #expect(status([gplayerWine], ["steam"])?.hasPrefix("G-Player is installing Steam.") == true)
        #expect(status([gplayerWine], ["main"]) == "G-Player is getting Windows ready for Main. This takes about a minute.")
    }

    @Test func theLibraryStaysQuietWhenNothingIsGoingOn() {
        #expect(FirstRunSetup.libraryStatus(installed: [gplayerWine], downloading: false, pendingSpaces: []) == nil)
        // The downloads failed: the spaces wait for the next start, and the library is as usual (Add Game works, and downloads).
        #expect(FirstRunSetup.libraryStatus(installed: [], downloading: false, pendingSpaces: ["main", "steam"]) == nil)
    }

    // MARK: Updating

    @Test func theNoteAboutGPlayerWineIsForSpacesOnAnotherEngineAndShowsOnce() {
        func space(_ engine: EngineInfo) -> Space { Space(name: "S", path: "/tmp/s", engineID: engine.id, origin: .managed) }
        #expect(FirstRunSetup.upgradeNoteApplies(spaces: [space(staging)], seen: false))
        #expect(FirstRunSetup.upgradeNoteApplies(spaces: [space(gplayerWine), space(staging)], seen: false))
        #expect(!FirstRunSetup.upgradeNoteApplies(spaces: [space(staging)], seen: true))
        #expect(!FirstRunSetup.upgradeNoteApplies(spaces: [space(gplayerWine)], seen: false))
        #expect(!FirstRunSetup.upgradeNoteApplies(spaces: [], seen: false))
        // A space on the earlier revision of G-Player Wine already runs G-Player Wine: nothing is new to it.
        #expect(!FirstRunSetup.upgradeNoteApplies(spaces: [space(EngineCatalog.crossoverRevision1), space(gplayerWine)], seen: false))
        #expect(FirstRunSetup.upgradeNoteApplies(spaces: [space(EngineCatalog.crossoverRevision1), space(staging)], seen: false))
    }

    // MARK: Bottles

    func found(_ name: String, _ note: String, engine: EngineInfo) -> FoundEnvironment {
        FoundEnvironment(name: name, url: URL(fileURLWithPath: "/tmp/\(name)"), originNote: note, suggestedEngineID: engine.id,
                         presetID: nil, games: [], size: nil)
    }

    @Test func bottlesAreWarnedAboutBeforeG_PlayerWineUpdatesThem() {
        let crossOver = found("A", "CrossOver", engine: gplayerWine), whisky = found("B", "Whisky", engine: gplayerWine)
        let prefix = found("C", "~/Games", engine: staging)
        #expect(crossOver.isAnotherAppsBottle && whisky.isAnotherAppsBottle && !prefix.isAnotherAppsBottle)
        // A bottle that got the earlier revision (the only one installed) is warned about too: it is G-Player Wine all the same.
        #expect(found("D", "CrossOver", engine: EngineCatalog.crossoverRevision1).isAnotherAppsBottle)
        #expect(FirstRunSetup.bottleWarning(for: [prefix]) == nil)
        #expect(FirstRunSetup.bottleWarning(for: []) == nil)
        let one = FirstRunSetup.bottleWarning(for: [crossOver, prefix])
        #expect(one?.contains("G-Player Wine updates a CrossOver bottle's files the first time it starts there") == true)
        #expect(one?.contains("CrossOver may not open the bottle afterwards") == true)
        #expect(FirstRunSetup.bottleWarning(for: [crossOver, whisky, crossOver])?.contains("CrossOver or Whisky may not open") == true)
    }

    // MARK: Switching an engine

    @Test func engineAgeFollowsTheWineRelease() {
        let toolkit = EngineCatalog.gptk
        #expect(EngineSwitch.age(of: gplayerWine, comparedTo: staging) == .older)        // Wine 11.0 against 11.18
        #expect(EngineSwitch.age(of: staging, comparedTo: gplayerWine) == .newer)
        #expect(EngineSwitch.age(of: gplayerWine, comparedTo: toolkit) == .newer)         // against wine 7.7
        #expect(EngineSwitch.age(of: toolkit, comparedTo: staging) == .older)
        #expect(EngineSwitch.age(of: staging, comparedTo: staging) == .same)
    }

    @Test func theSwitchQuestionNamesTheTargetItsSizeAndWhetherItIsNewer() {
        #expect(EngineSwitch.title(space: "Main", to: gplayerWine) == "Move “Main” to G-Player Wine?")
        let toGPlayerWine = EngineSwitch.message(space: "Main", from: staging, to: gplayerWine, downloadBytes: 287_881_528)
        #expect(toGPlayerWine.hasPrefix("Every program in “Main” will run on G-Player Wine (Wine 11 from CrossOver 26.3) instead of Wine Staging 11.18."))
        #expect(toGPlayerWine.contains("G-Player Wine downloads first, about 288 MB."))      // from the bytes the question is given
        #expect(toGPlayerWine.contains("older Wine than the space has now"))
        let toStaging = EngineSwitch.message(space: "Main", from: gplayerWine, to: staging, downloadBytes: 0)
        #expect(!toStaging.contains("downloads first"))
        #expect(toStaging.contains("newer Wine than the space has now") && toStaging.contains("the older Wine may not open the space afterwards"))
        // An engine nobody knows has no age to compare.
        let unknown = EngineSwitch.message(space: "Main", from: nil, to: staging, downloadBytes: 0)
        #expect(unknown == "Every program in “Main” will run on Wine Staging 11.18.")
        #expect(EngineSwitch.busyMessage(space: "Main").contains("Programs are running in “Main”"))
    }

    @Test func aSpacesPageOffersTheMenuOnlyToThoseWhoAskedForIt() {
        let toolkit = EngineCatalog.gptk, revision1 = EngineCatalog.crossoverRevision1
        func offer(_ engineID: String, choosing: Bool) -> EngineSwitch.PageOffer {
            EngineSwitch.pageOffer(engineID: engineID, choosingEngines: choosing)
        }
        // On G-Player Wine (either revision) the page says nothing about engines, unless the menu was asked for.
        #expect(offer(gplayerWine.id, choosing: false) == .nothing && offer(revision1.id, choosing: false) == .nothing)
        #expect(offer(gplayerWine.id, choosing: true) == .picker(selected: gplayerWine.id))
        #expect(offer(revision1.id, choosing: true) == .picker(selected: gplayerWine.id))            // the menu never lists a retired engine
        // A space on Wine Staging says so and offers the move; with the menu on, the menu does it.
        #expect(offer(staging.id, choosing: false) == .move)
        #expect(offer(staging.id, choosing: true) == .picker(selected: staging.id))
        // Apple's toolkit isn't in the menu, so its space is offered the move either way.
        #expect(offer(toolkit.id, choosing: false) == .move && offer(toolkit.id, choosing: true) == .move)
        // An engine nobody knows has nothing to say.
        #expect(offer("wine-from-the-future", choosing: false) == .nothing && offer("wine-from-the-future", choosing: true) == .nothing)
    }

    @Test func movingASpaceOffTheToolkitIsToANewerWineAndOffStagingToAnOlderOne() {
        let toolkit = EngineCatalog.gptk
        let fromToolkit = EngineSwitch.message(space: "Main", from: toolkit, to: gplayerWine, downloadBytes: 0)
        #expect(fromToolkit.hasPrefix("Every program in “Main” will run on G-Player Wine (Wine 11 from CrossOver 26.3) instead of Game Porting Toolkit (D3DMetal)."))
        #expect(fromToolkit.contains("newer Wine than the space has now") && fromToolkit.contains("the older Wine may not open the space afterwards"))
        // From Wine Staging 11.18 to G-Player Wine's Wine 11.0 the warning is the old-Wine one: nothing moves without it.
        let fromStaging = EngineSwitch.message(space: "Main", from: staging, to: gplayerWine, downloadBytes: 0)
        #expect(fromStaging.contains("older Wine than the space has now") && fromStaging.contains("may not open on it"))
    }

    @Test func pickersUseShortNames() {
        #expect(gplayerWine.shortName == "G-Player Wine")
        #expect(staging.shortName == "Wine Staging 11.18")
        #expect(EngineCatalog.gptk.shortName == "Game Porting Toolkit (D3DMetal)")
    }

    // MARK: Words about graphics

    @Test func automaticGraphicsAreNotNamedAfterWhatTheyPickFirst() {
        #expect(GraphicsBackend.auto.displayName == "Automatic")
        let hint = "G-Player picks the graphics and, if the game doesn't start, tries the next ones by itself."
        #expect(gplayerWine.graphicsHint(for: .auto, profile: .recommended) == hint)
        #expect(staging.graphicsHint(for: .auto, profile: .fast) == hint)
        // A choice the engine doesn't have shows as Automatic, as the picker does.
        #expect(staging.graphicsHint(for: .d3dmetal, profile: .recommended) == hint)
        #expect(staging.graphicsHint(for: .wined3d, profile: .recommended) == GraphicsBackend.wined3d.summary)
        // Under Custom nothing switches, and Automatic is the engine's usual graphics.
        #expect(staging.graphicsHint(for: .auto, profile: .custom) == "Uses DXVK, this engine's usual graphics. G-Player never switches it.")
    }

    @Test func profileSummariesSayWhetherGPlayerSwitchesGraphics() {
        #expect(LaunchProfile.recommended.summary.hasSuffix("If the game doesn't start, G-Player tries other graphics by itself."))
        #expect(LaunchProfile.compatible.summary
                == "Slower, but starts more games. Uses Wine's own graphics and never switches by itself. Try it when a game won't open.")
        #expect(LaunchProfile.custom.summary == "Graphics you choose under Advanced. G-Player never switches them.")
    }

    @Test func directX12SaysWhatToDoOnGPlayerWineWithoutD3DMetal() {
        let dx12 = GameAnalysis(graphics: [.d3d12], architecture: .x64)
        func warning(on engine: EngineInfo) -> String? {
            CompatResolver.resolve(.init(engine: engine, analysis: dx12, fixes: [], options: .default))
                .warnings.first { $0.title == "Needs DirectX 12" }?.detail
        }
        let withoutD3DMetal = gplayerWine.limited(to: [.dxvk, .dxmt, .wined3d])
        #expect(warning(on: withoutD3DMetal)
                == "DirectX 12 needs Apple's D3DMetal. Turn it on in Settings › Engines, or choose DirectX 11 in the game's own settings.")
        #expect(warning(on: staging)?.hasPrefix("This space's engine has no DirectX 12.") == true)
        // With D3DMetal there is nothing to say.
        #expect(warning(on: gplayerWine) == nil)
    }

    @Test func anOldMoltenVKPointsToGPlayerWine() {
        #expect(CompatResolver.oldMoltenVK.hasSuffix("Move this space to G-Player Wine, which has a newer one."))
        #expect(!CompatResolver.oldMoltenVK.contains("Wine Staging 11.18 it downloads"))
    }
}


/// A first run whose download the user stopped waits for the engine; it says so, and doesn't make the spaces on another one.
@Suite struct FirstRunOnHoldTests {
    @Test func theNoteSaysWhatIsOnHoldAndHowItGoesOn() {
        let both = FirstRunSetup.pausedNote(pendingSpaces: ["main", "steam"])
        #expect(both.title == "Setup is on hold")
        #expect(both.text.contains("setting up Main and Steam is on hold") && both.text.contains("once G-Player Wine is installed"))
        #expect(both.text.contains("Settings › Engines") && both.text.contains("next time G-Player opens"))
        #expect(FirstRunSetup.pausedNote(pendingSpaces: ["main"]).text.contains("setting up Main is on hold"))
        #expect(FirstRunSetup.pausedNote(pendingSpaces: []).text.contains("the first spaces"))
    }
}
