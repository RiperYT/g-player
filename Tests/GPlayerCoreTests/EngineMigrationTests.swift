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
        // Only spaces on a retired engine ask for it.
        #expect(plan([space("S", on: staging.id)], installed: [old]).install.isEmpty)
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
        #expect(plan([], installed: [old, staging]).remove == [old.id])
        #expect(plan([space("Main", on: new.id)], installed: [old, new]).remove == [old.id])
        #expect(plan([space("Main", on: new.id)], installed: [new]).remove.isEmpty)
        // Not while a space is still on it, whatever the reason.
        #expect(plan([space("Main", on: old.id)], installed: [old]).remove.isEmpty)
        // Never an engine that isn't retired.
        #expect(!plan([], installed: [new, staging, EngineCatalog.gptk]).remove.contains(new.id))
        #expect(plan([], installed: [new, staging, EngineCatalog.gptk]).isEmpty)
    }

    // MARK: Carrying it out

    @Test func theSpaceKeepsEverythingButItsEngineAndTheGamesKeepWhatWasLearned() {
        var steam = space("Steam", on: old.id, origin: .external)
        steam.originNote = "CrossOver"; steam.allowsChanges = false; steam.presetID = "steam"
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
