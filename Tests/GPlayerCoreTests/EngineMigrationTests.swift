import Foundation
import Testing
@testable import GPlayerCore

/// After an update, spaces on the retired G-Player Wine revision move to the new one without breaking anything.
@Suite struct EngineMigrationTests {
    let old = EngineCatalog.crossoverRevision1
    let new = EngineCatalog.crossover
    let staging = EngineCatalog.wineStaging

    func space(_ name: String, on engine: String, origin: Space.Origin = .managed) -> Space {
        Space(name: name, path: "/tmp/\(name)", engineID: engine, origin: origin)
    }

    func plan(_ spaces: [Space], installed: [EngineInfo], busy: [Space] = []) -> EngineMigration.Plan {
        EngineMigration.plan(spaces: spaces, installed: Set(installed.map(\.id)), busy: Set(busy.map(\.id)))
    }

    // MARK: Planning

    @Test func nothingIsDoneWhenNoSpaceIsOnARetiredEngine() {
        let spaces = [space("Main", on: new.id), space("Old", on: staging.id), space("Odd", on: "wine-from-the-future"),
                      space("Toolkit", on: EngineCatalog.gptk.id)]
        #expect(plan(spaces, installed: [new, staging]).isEmpty)
        #expect(plan([], installed: []).isEmpty)
        #expect(plan(spaces, installed: []).isEmpty)
    }

    @Test func anIdleSpaceMovesOnceTheReplacementIsInstalledAndTheOldEngineGoesWhenNothingUsesIt() {
        let main = space("Main", on: old.id), steam = space("Steam", on: old.id), other = space("Other", on: staging.id)
        let p = plan([main, steam, other], installed: [old, new, staging])
        #expect(p.switches == [.init(space: main.id, from: old.id, to: new.id), .init(space: steam.id, from: old.id, to: new.id)])
        #expect(p.install.isEmpty)
        #expect(p.remove == [old.id])
    }

    @Test func aSpaceWithProgramsRunningStaysAndKeepsTheOldEngine() {
        let main = space("Main", on: old.id), steam = space("Steam", on: old.id)
        let p = plan([main, steam], installed: [old, new], busy: [steam])
        #expect(p.switches == [.init(space: main.id, from: old.id, to: new.id)])
        #expect(p.install.isEmpty)                                  // the replacement is there; the space moves once it is idle
        #expect(p.remove.isEmpty)                                   // a space still runs on the old one
        // Idle again: it moves, and the old engine goes.
        #expect(plan([steam], installed: [old, new]).remove == [old.id])
    }

    @Test func withoutTheReplacementTheSpacesStayAndOneDownloadIsAskedFor() {
        let a = space("A", on: old.id), b = space("B", on: old.id)
        let p = plan([a, b], installed: [old])
        #expect(p.switches.isEmpty && p.remove.isEmpty)
        #expect(p.install == [new.id])                              // once, not per space
        // Busy or not makes no difference without the replacement: games keep running on the old revision meanwhile.
        #expect(plan([a, b], installed: [old, staging], busy: [a]).install == [new.id])
        // A space on another engine asks for nothing; it is the old engine installed that does (anOldEngineGoesOnlyOnceItsReplacementIsInstalled).
        #expect(plan([space("S", on: staging.id)], installed: [staging]).install.isEmpty)
    }

    @Test func aSpaceWhoseOldEngineIsGoneMovesAtOnceAndLaunchingInstallsTheNewOne() {
        let busyOne = space("Busy", on: old.id), idle = space("Idle", on: old.id)
        // Neither engine installed (the user removed the old one): no fall back to Wine Staging, no background download.
        let p = plan([busyOne, idle], installed: [staging], busy: [busyOne])
        #expect(p.switches.map(\.to) == [new.id, new.id] && p.switches.map(\.from) == [old.id, old.id])
        #expect(p.install.isEmpty && p.remove.isEmpty)
        #expect(plan([idle], installed: []).switches.count == 1)
        // The replacement installed, the old one gone: moves even when busy (nothing can run from an engine that isn't there).
        #expect(plan([busyOne], installed: [new], busy: [busyOne]).switches.count == 1)
    }

    @Test func anOldEngineNobodyUsesIsRemovedOnlyWhileItIsInstalled() {
        #expect(plan([], installed: [old, new, staging]).remove == [old.id])
        #expect(plan([space("Main", on: new.id)], installed: [old, new]).remove == [old.id])
        #expect(plan([space("Main", on: new.id)], installed: [new]).remove.isEmpty)
        // Not while a space is still on it, whatever the reason.
        #expect(plan([space("Main", on: old.id)], installed: [old]).remove.isEmpty)
        // Never an engine that isn't retired.
        #expect(!plan([], installed: [new, staging, EngineCatalog.gptk]).remove.contains(new.id))
        #expect(plan([], installed: [new, staging, EngineCatalog.gptk]).isEmpty)
    }

    @Test func anOldEngineGoesOnlyOnceItsReplacementIsInstalled() {
        // Nothing is on it (all spaces on Wine Staging, an empty library, or the only one was switched away): it stays, and the
        // replacement is installed first so that the Mac isn't left without G-Player Wine.
        for spaces in [[], [space("Staging", on: staging.id)]] {
            let p = plan(spaces, installed: [old, staging])
            #expect(p.remove.isEmpty && p.switches.isEmpty)
            #expect(p.install == [new.id])
        }
        // Offline, say: the same at every look, until the replacement is there. Then the old one goes.
        #expect(plan([], installed: [old]).install == [new.id])
        #expect(plan([], installed: [old, new]).remove == [old.id])
        #expect(plan([], installed: [old, new]).install.isEmpty)
        // An old engine that isn't installed asks for nothing: there is nothing to replace.
        #expect(plan([], installed: [staging]).isEmpty)
        #expect(plan([space("Staging", on: staging.id)], installed: [staging]).isEmpty)
        // The replacement is asked for once, however many spaces and reasons there are.
        let p = plan([space("A", on: old.id), space("B", on: old.id)], installed: [old])
        #expect(p.install == [new.id])
    }

    // MARK: Spaces of other apps

    func bottle(_ name: String, on engine: String, allows: Bool? = nil) -> Space {
        var s = space(name, on: engine, origin: .external)
        s.originNote = "CrossOver"; s.allowsChanges = allows
        return s
    }

    @Test func aSpaceOfAnotherAppIsNeverMovedWithoutItsOwnersYes() {
        // The first start on the new Wine updates the bottle's files: not before the user allowed changes there.
        for allows in [nil, false] as [Bool?] {
            let b = bottle("Bottle", on: old.id, allows: allows)
            let p = plan([b], installed: [old, new])                 // idle, and the replacement is there
            #expect(p.switches.isEmpty)
            #expect(p.remove.isEmpty)                                // it is still on the old engine, which stays for it
            #expect(p.install.isEmpty)
            // The replacement still comes: that is what the offer on the space's page waits for.
            #expect(plan([b], installed: [old]).install == [new.id])
        }
        // Allowed: it moves like a space G-Player made, and the old engine goes.
        let allowed = bottle("Allowed", on: old.id, allows: true)
        let p = plan([allowed], installed: [old, new])
        #expect(p.switches == [.init(space: allowed.id, from: old.id, to: new.id)] && p.remove == [old.id])
    }

    @Test func aSpaceOfAnotherAppHoldsTheOldEngineWhileOthersMove() {
        let mine = space("Mine", on: old.id), bottle = bottle("Bottle", on: old.id)
        let p = plan([mine, bottle], installed: [old, new])
        #expect(p.switches == [.init(space: mine.id, from: old.id, to: new.id)])
        #expect(p.remove.isEmpty)
        // Once it is allowed, the next look moves it and removes the old engine.
        var allowed = bottle; allowed.allowsChanges = true
        let next = plan([allowed], installed: [old, new])
        #expect(next.switches.map(\.space) == [allowed.id] && next.remove == [old.id])
    }

    @Test func aSpaceOfAnotherAppWhoseOldEngineIsGoneWaitsForItsOwnersYesToo() {
        // Its engine isn't there, but moving it is what the first start on the new Wine would do to it.
        let b = bottle("Bottle", on: old.id)
        #expect(plan([b], installed: [new]).isEmpty)
        #expect(plan([b], installed: []).install == [new.id])
        var allowed = b; allowed.allowsChanges = true
        #expect(plan([allowed], installed: [new]).switches.count == 1)
    }

    @Test func aStartOnTheReplacementMovesTheSpaceOfARetiredEngineThatIsGone() {
        func start(_ s: Space, on engine: EngineInfo, installed: [EngineInfo]) -> EngineMigration.Plan.Switch? {
            EngineMigration.moveForStart(s, on: engine, installed: Set(installed.map(\.id)))
        }
        let main = space("Main", on: old.id)
        // The old engine isn't installed, so the start runs on the replacement: the space moves with it, here and now.
        #expect(start(main, on: new, installed: [new]) == .init(space: main.id, from: old.id, to: new.id))
        #expect(start(main, on: new, installed: []) == .init(space: main.id, from: old.id, to: new.id))
        // The old engine is there: the start runs on it, and the space stays (it moves when it is quiet).
        #expect(start(main, on: old, installed: [old, new]) == nil)
        #expect(start(main, on: new, installed: [old, new]) == nil)
        // Not a start on the replacement, or not a space on a retired engine.
        #expect(start(main, on: staging, installed: [staging]) == nil)
        #expect(start(space("Now", on: new.id), on: new, installed: [new]) == nil)
        #expect(start(space("Staging", on: staging.id), on: new, installed: [new]) == nil)
        // A space of another app moves only with its owner's yes.
        let b = bottle("Bottle", on: old.id)
        #expect(start(b, on: new, installed: [new]) == nil)
        var allowed = b; allowed.allowsChanges = true
        #expect(start(allowed, on: new, installed: [new]) == .init(space: b.id, from: old.id, to: new.id))
    }

    @Test func aSwitchByHandFromTheOldRevisionToTheNewOneIsTheSameMoveAsTheAutomaticOne() {
        let main = space("Main", on: old.id)
        #expect(EngineMigration.switchBetweenRevisions(of: main, to: new) == .init(space: main.id, from: old.id, to: new.id))
        // Any other switch is another Wine: nothing carries over.
        #expect(EngineMigration.switchBetweenRevisions(of: main, to: staging) == nil)
        #expect(EngineMigration.switchBetweenRevisions(of: main, to: EngineCatalog.gptk) == nil)
        #expect(EngineMigration.switchBetweenRevisions(of: space("Now", on: new.id), to: new) == nil)
        #expect(EngineMigration.switchBetweenRevisions(of: space("Now", on: new.id), to: old) == nil)         // back: not a revision's replacement
        #expect(EngineMigration.switchBetweenRevisions(of: space("Staging", on: staging.id), to: new) == nil)
        #expect(EngineMigration.switchBetweenRevisions(of: space("Odd", on: "wine-from-the-future"), to: new) == nil)
    }

    @Test func whatWasLearnedOnTheOldRevisionHoldsAfterASwitchByHand() throws {
        let main = space("Main", on: old.id)
        var game = Game(title: "Learned", spaceID: main.id)
        game.autoGraphics = AutoGraphics(engineID: old.id, worked: .dxmt, failed: [.dxvk])
        var state = LibraryState()
        state.spaces = [main]; state.games = [game]
        let move = try #require(EngineMigration.switchBetweenRevisions(of: main, to: new))
        EngineMigration.apply(.init(switches: [move]), to: &state)
        #expect(state.spaces[0].engineID == new.id)
        #expect(state.games[0].autoGraphics?.current(on: new.id) == AutoGraphics(engineID: new.id, worked: .dxmt, failed: [.dxvk]))
    }

    @Test func theOfferIsForABottleOfAnotherAppNotAskedYetOnceTheNewEngineIsThere() {
        func offers(_ s: Space, _ installed: [EngineInfo]) -> Bool { EngineMigration.offersMove(s, installed: Set(installed.map(\.id))) }
        let b = bottle("Bottle", on: old.id)
        #expect(offers(b, [old, new]))
        #expect(offers(b, [new]))                                    // its own engine gone: still the way forward
        #expect(!offers(b, [old]))                                   // "ready" means installed
        // Said no: no offer; allowing changes in its settings is the way, and then it moves like any other space.
        #expect(!offers(bottle("No", on: old.id, allows: false), [old, new]))
        // Allowed (it moves by itself), made by G-Player, or not on a retired engine: nothing to offer.
        #expect(!offers(bottle("Yes", on: old.id, allows: true), [old, new]))
        #expect(!offers(space("Mine", on: old.id), [old, new]))
        #expect(!offers(bottle("Now", on: new.id), [old, new]))
        #expect(!offers(bottle("Staging", on: staging.id), [old, new, staging]))
    }

    @Test func theOfferIsOnePlainSentenceAboutOneUpdateOfWinesFiles() {
        #expect(EngineMigration.moveOffer(to: new)
                == "A newer G-Player Wine is ready. Moving this bottle to it updates Wine's files in it once.")
    }

    @Test func aStartAsksFirstOnlyForABottleWhoseRetiredEngineIsGone() {
        func asks(_ s: Space, _ installed: [EngineInfo]) -> Bool { EngineMigration.startNeedsConsent(s, installed: Set(installed.map(\.id))) }
        let b = bottle("Bottle", on: old.id)
        #expect(asks(b, [new]) && asks(b, []))                       // the start would run the new engine in it
        #expect(!asks(b, [old, new]) && !asks(b, [old]))             // it runs on the old one, which is there
        #expect(asks(bottle("No", on: old.id, allows: false), [new]))
        #expect(!asks(bottle("Yes", on: old.id, allows: true), [new]))
        #expect(!asks(space("Mine", on: old.id), [new]))
        #expect(!asks(bottle("Now", on: new.id), [new]) && !asks(bottle("Staging", on: staging.id), [staging]))
    }

    // MARK: In use

    func program(_ command: String, in space: Space, folder: String = "drive_c/windows/system32") -> WineProcess {
        WineProcess(pid: 100, command: command, directory: space.path + "/" + folder)
    }

    @Test func aSpaceIsInUseWhileAnyProgramOfItsOwnRuns() {
        let main = space("Main", on: old.id), other = space("Other", on: old.id)
        #expect(!EngineMigration.isInUse(main, processes: [], activity: .init()))
        // A game, a launcher, a tool: all are programs of the space.
        let game = program(#"C:\Games\Made Up\game.exe"#, in: main, folder: "drive_c/Games/Made Up")
        #expect(EngineMigration.isInUse(main, processes: [game], activity: .init()))
        // Wine's own services stay as long as anything runs, and its Wine server may still wind down behind them: they hold the
        // space too (the one thing that isn't a Windows program, the server, is caught by the engine's folder, see below).
        for service in [#"C:\windows\system32\services.exe"#, #"C:\windows\system32\explorer.exe /desktop"#] {
            #expect(EngineMigration.isInUse(main, processes: [program(service, in: main)], activity: .init()), "\(service)")
        }
        // Another space's programs are none of its business.
        #expect(!EngineMigration.isInUse(main, processes: [program(#"C:\Games\game.exe"#, in: other)], activity: .init()))
    }

    @Test func aSpaceIsInUseWhileTheAppHasWorkBegunInIt() {
        let main = space("Main", on: old.id)
        typealias Activity = EngineMigration.SpaceActivity
        let busy: [Activity] = [
            .init(movingEngine: true), .init(installing: true), .init(queued: true), .init(launchesStarting: 1),
            .init(launchesStarting: 3), .init(gameStarting: true), .init(gameRunning: true), .init(addingGame: true),
        ]
        for activity in busy { #expect(EngineMigration.isInUse(main, processes: [], activity: activity), "\(activity)") }
        #expect(!EngineMigration.isInUse(main, processes: [], activity: .init(launchesStarting: 0)))
        #expect(!Activity().isActive)
    }

    @Test func anEngineFolderMayGoOnlyWhenThePlanSaysSoAndNothingRunsFromIt() {
        let folder = URL(fileURLWithPath: "/tmp/Library/Engines/\(old.id)")
        let removal = EngineMigration.Plan(remove: [old.id])
        func running(_ path: String) -> [ProcessExecutable] { [.init(pid: 7, path: path)] }
        #expect(EngineMigration.mayRemove(old.id, plan: removal, folder: folder, executables: []))
        #expect(EngineMigration.mayRemove(old.id, plan: removal, folder: folder, executables: running("/usr/bin/sleep")))
        // Wine's own programs are not Windows programs, and still hold the folder: the loader and the server.
        for name in ["wine64-preloader", "wine-preloader", "wineserver"] {
            let path = folder.path + "/wine/bin/" + name
            #expect(!EngineMigration.mayRemove(old.id, plan: removal, folder: folder, executables: running(path)), "\(name)")
        }
        // A fresh look that finds a space on the engine again says no, whatever runs.
        #expect(!EngineMigration.mayRemove(old.id, plan: .init(), folder: folder, executables: []))
        #expect(!EngineMigration.mayRemove(old.id, plan: .init(remove: ["another"]), folder: folder, executables: []))
    }

    // MARK: Carrying it out

    @Test func theSpaceKeepsEverythingButItsEngineAndTheGamesKeepWhatWasLearned() {
        var steam = space("Steam", on: old.id, origin: .external)
        steam.originNote = "CrossOver"; steam.allowsChanges = true; steam.presetID = "steam"
        let other = space("Other", on: old.id)
        var learned = Game(title: "Learned", spaceID: steam.id)
        learned.autoGraphics = AutoGraphics(engineID: old.id, worked: .dxmt, failed: [.dxvk])
        var elsewhere = Game(title: "Elsewhere", spaceID: steam.id)
        elsewhere.autoGraphics = AutoGraphics(engineID: staging.id, worked: .dxvk)           // learned on another Wine: not the same
        var untouched = Game(title: "Untouched", spaceID: other.id)
        untouched.autoGraphics = AutoGraphics(engineID: old.id, worked: .dxvk)
        let plain = Game(title: "Plain", spaceID: steam.id)

        var state = LibraryState()
        state.spaces = [steam, other]
        state.games = [learned, elsewhere, untouched, plain]
        let p = EngineMigration.Plan(switches: [.init(space: steam.id, from: old.id, to: new.id)])
        EngineMigration.apply(p, to: &state)

        var moved = steam; moved.engineID = new.id
        #expect(state.spaces == [moved, other])                                              // path, origin, notes, answers: as they were
        #expect(state.games[0].autoGraphics == AutoGraphics(engineID: new.id, worked: .dxmt, failed: [.dxvk]))
        #expect(state.games[1].autoGraphics == AutoGraphics(engineID: staging.id, worked: .dxvk))
        #expect(state.games[2].autoGraphics?.engineID == old.id)                              // a space that didn't move
        #expect(state.games[3].autoGraphics == nil)
        // What was learned counts on the new engine, so the next launch starts from it.
        #expect(state.games[0].autoGraphics?.current(on: new.id).worked == .dxmt)
    }

    @Test func aSpaceThatMayNotBeChangedIsLeftAloneEvenIfAPlanNamesIt() {
        // The plan was made before the user said no (or a plan from elsewhere): applying it never writes to such a space.
        for allows in [nil, false] as [Bool?] {
            let b = bottle("Bottle", on: old.id, allows: allows)
            var game = Game(title: "G", spaceID: b.id)
            game.autoGraphics = AutoGraphics(engineID: old.id, worked: .dxvk)
            var state = LibraryState()
            state.spaces = [b]; state.games = [game]
            EngineMigration.apply(.init(switches: [.init(space: b.id, from: old.id, to: new.id)]), to: &state)
            #expect(state.spaces == [b] && state.games[0].autoGraphics?.engineID == old.id)
        }
    }

    @Test func aSpaceThatChangedEngineSincePlanningIsLeftAlone() {
        var s = space("Main", on: staging.id)                                                // the user switched it meanwhile
        var game = Game(title: "G", spaceID: s.id)
        game.autoGraphics = AutoGraphics(engineID: staging.id, worked: .dxvk)
        var state = LibraryState()
        state.spaces = [s]; state.games = [game]
        EngineMigration.apply(.init(switches: [.init(space: s.id, from: old.id, to: new.id)]), to: &state)
        #expect(state.spaces[0].engineID == staging.id && state.games[0].autoGraphics?.engineID == staging.id)
        // A space that is gone is no error either.
        s.id = UUID()
        EngineMigration.apply(.init(switches: [.init(space: s.id, from: old.id, to: new.id)]), to: &state)
        #expect(state.spaces.count == 1)
    }

    @Test func aPlanThenItsApplicationLeavesNothingOnTheRetiredEngine() {
        var state = LibraryState()
        state.spaces = [space("A", on: old.id), space("B", on: old.id), space("C", on: staging.id)]
        let p = plan(state.spaces, installed: [old, new, staging])
        EngineMigration.apply(p, to: &state)
        #expect(state.spaces.map(\.engineID) == [new.id, new.id, staging.id])
        // The next look has nothing to do but the removal, and then nothing at all.
        #expect(plan(state.spaces, installed: [old, new, staging]).remove == [old.id])
        #expect(plan(state.spaces, installed: [new, staging]).isEmpty)
    }

    @Test func theUpdateNoteIsOnePlainSentence() {
        #expect(EngineMigration.updateNote(for: new)
                == "Updating G-Player Wine (adds video playback in games). Your games keep working meanwhile.")
    }
}
