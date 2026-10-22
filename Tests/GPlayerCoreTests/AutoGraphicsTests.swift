import Foundation
import Testing
@testable import GPlayerCore

/// Automatic graphics: which backends are worth trying for a game, and what G-Player remembers about them.
@Suite struct AutoGraphicsTests {
    static let everything: [GraphicsBackend] = [.dxvk, .d3dmetal, .dxmt, .wined3d]
    static let noMetal: [GraphicsBackend] = [.dxvk, .dxmt, .wined3d]

    /// G-Player Wine with what it can run now (D3DMetal only once it is copied in).
    func crossover(_ ready: [GraphicsBackend] = everything) -> EngineInfo { EngineCatalog.crossover.limited(to: ready) }

    let dx11x64 = GameAnalysis(graphics: [.d3d11], architecture: .x64)
    let dx11x32 = GameAnalysis(graphics: [.d3d11], architecture: .x86)
    let unityDX12 = GameAnalysis(engine: .unity, graphics: [.d3d11, .d3d12], architecture: .x64)

    func input(_ analysis: GameAnalysis?, _ engine: EngineInfo, options: LaunchOptions = .default,
               user: GraphicsBackend = .auto, learned: AutoGraphics? = nil) -> CompatResolver.Input {
        .init(engine: engine, analysis: analysis, fixes: [], options: options, userBackend: user, autoGraphics: learned)
    }

    func candidates(_ analysis: GameAnalysis?, _ engine: EngineInfo, _ options: LaunchOptions = .default,
                    user: GraphicsBackend = .auto) -> [GraphicsBackend] {
        CompatResolver.graphicsCandidates(input(analysis, engine, options: options, user: user))
    }

    func backend(_ analysis: GameAnalysis?, _ engine: EngineInfo, options: LaunchOptions = .default,
                 user: GraphicsBackend = .auto, learned: AutoGraphics? = nil) -> GraphicsBackend {
        CompatResolver.resolve(input(analysis, engine, options: options, user: user, learned: learned)).backend
    }

    // MARK: Candidates

    @Test func a64BitDirectX11GameTriesD3DMetalThenDXMTThenDXVK() {
        #expect(candidates(dx11x64, crossover()) == [.d3dmetal, .dxmt, .dxvk])
        #expect(candidates(dx11x64, crossover(), LaunchOptions(profile: .fast)) == [.d3dmetal, .dxmt, .dxvk])
        #expect(candidates(GameAnalysis(graphics: [.d3d10], architecture: .x64), crossover()) == [.d3dmetal, .dxmt, .dxvk])
        // Without D3DMetal (not copied in yet) today's choice is DXVK, so DXMT is what is left. Never WineD3D.
        #expect(candidates(dx11x64, crossover(Self.noMetal)) == [.dxvk, .dxmt])
    }

    @Test func a32BitDirectX11GameTriesDXVKThenDXMT() {
        #expect(candidates(dx11x32, crossover()) == [.dxvk, .dxmt])
        #expect(candidates(dx11x32, crossover(), LaunchOptions(profile: .fast)) == [.dxvk, .dxmt])
        #expect(candidates(GameAnalysis(graphics: [.d3d10], architecture: .x86), crossover(Self.noMetal)) == [.dxvk, .dxmt])
        // A Unity game with only OpenGL in its imports runs DirectX 11 all the same.
        #expect(candidates(GameAnalysis(engine: .unity, graphics: [.opengl], architecture: .x86), crossover()) == [.dxvk, .dxmt])
        // A .NET program that says 32-bit is usually AnyCPU, which D3DMetal runs.
        #expect(candidates(GameAnalysis(graphics: [.d3d11], architecture: .x86, isDotNet: true), crossover()) == [.d3dmetal, .dxmt, .dxvk])
    }

    @Test func directX12TriesD3DMetalAndForUnityAndUnrealTheDirectX11Fallbacks() {
        #expect(candidates(unityDX12, crossover()) == [.d3dmetal, .dxmt, .dxvk])
        #expect(candidates(GameAnalysis(engine: .unreal, graphics: [.d3d12], architecture: .x64), crossover()) == [.d3dmetal, .dxmt, .dxvk])
        // Others have no DirectX 11 mode to fall back to, and an Unreal game built for DirectX 12 alone stops at -dx11.
        #expect(candidates(GameAnalysis(engine: .godot, graphics: [.d3d12], architecture: .x64), crossover()) == [.d3dmetal])
        #expect(candidates(GameAnalysis(engine: .unreal, graphics: [.d3d12], architecture: .x64, onlyDirect3D12: true), crossover()) == [.d3dmetal])
        // Without D3DMetal: today's choice and, for Unity, DXMT.
        #expect(candidates(unityDX12, crossover(Self.noMetal)) == [.dxvk, .dxmt])
        #expect(candidates(GameAnalysis(engine: .godot, graphics: [.d3d12], architecture: .x64), crossover(Self.noMetal)) == [.dxvk])
    }

    @Test func otherGraphicsAPIsGetNoRetries() {
        for graphics: [GraphicsAPI] in [[.d3d9], [.d3d8], [.opengl], [.vulkan], [.d3d9, .opengl], []] {
            let analysis = GameAnalysis(graphics: graphics, architecture: .x64)
            #expect(candidates(analysis, crossover()).count == 1, "\(graphics)")
            #expect(candidates(analysis, EngineCatalog.wineStaging).count == 1, "\(graphics)")
        }
        #expect(candidates(nil, crossover()) == [.dxvk])
        #expect(candidates(GameAnalysis(graphics: [.d3d9], architecture: .x64), crossover()) == [.dxvk])
    }

    @Test func wineStagingAndTheToolkitHaveFewerToTry() {
        let staging = EngineCatalog.wineStaging
        #expect(candidates(dx11x64, staging) == [.dxvk])
        #expect(candidates(dx11x32, staging) == [.dxvk])
        #expect(candidates(unityDX12, staging) == [.dxvk])
        // The toolkit runs D3DMetal and WineD3D only.
        #expect(candidates(dx11x64, EngineCatalog.gptk) == [.d3dmetal])
        #expect(candidates(GameAnalysis(engine: .unreal, graphics: [.d3d12], architecture: .x64), EngineCatalog.gptk) == [.d3dmetal])
        #expect(candidates(dx11x32, EngineCatalog.gptk) == [.wined3d])
    }

    @Test func candidatesAreUniqueAndOnlyWhatTheEngineCanRun() {
        let analyses = [dx11x64, dx11x32, unityDX12, GameAnalysis(graphics: [.d3d9]), GameAnalysis(), nil]
        let engines = [EngineCatalog.wineStaging, EngineCatalog.gptk, crossover(), crossover(Self.noMetal), crossover([.wined3d])]
        for engine in engines {
            for analysis in analyses {
                for profile in LaunchProfile.allCases {
                    let list = candidates(analysis, engine, LaunchOptions(profile: profile))
                    #expect(!list.isEmpty && Set(list).count == list.count)
                    #expect(list.allSatisfy { engine.backends.contains($0) || $0 == engine.defaultBackend })
                    #expect(!list.contains(.auto))
                }
            }
        }
    }

    @Test func theFirstCandidateIsWhatAutomaticChoosesWhenNothingIsLearned() {
        let analyses = [dx11x64, dx11x32, unityDX12, GameAnalysis(graphics: [.d3d9], architecture: .x64), GameAnalysis(), nil,
                        GameAnalysis(engine: .unreal, graphics: [.d3d12], architecture: .x64, onlyDirect3D12: true)]
        let engines = [EngineCatalog.wineStaging, EngineCatalog.gptk, crossover(), crossover(Self.noMetal)]
        for engine in engines {
            for analysis in analyses {
                for profile in LaunchProfile.allCases {
                    let options = LaunchOptions(profile: profile)
                    let plan = backend(analysis, engine, options: options, user: .dxmt)
                    #expect(candidates(analysis, engine, options, user: .dxmt).first == plan, "\(engine.name) \(profile)")
                }
            }
        }
        // Spelled out, so a change to today's choice is noticed here too.
        #expect(backend(dx11x64, crossover()) == .d3dmetal)
        #expect(backend(dx11x64, crossover(Self.noMetal)) == .dxvk)
        #expect(backend(dx11x32, crossover()) == .dxvk)
        #expect(backend(unityDX12, crossover()) == .d3dmetal)
        #expect(backend(dx11x64, EngineCatalog.wineStaging) == .dxvk)
    }

    @Test func compatibleAndCustomAreTheUsersOwnChoice() {
        #expect(candidates(dx11x64, crossover(), LaunchOptions(profile: .compatible)) == [.wined3d])
        #expect(candidates(dx11x64, crossover(), LaunchOptions(profile: .custom), user: .dxmt) == [.dxmt])
        // A backend the engine can't run now is the one it resolves to.
        #expect(candidates(dx11x64, crossover(Self.noMetal), LaunchOptions(profile: .custom), user: .d3dmetal) == [.dxvk])
    }

    // MARK: What was learned

    @Test func theBackendThatWorkedIsUsedWhileItIsStillACandidate() {
        let id = EngineCatalog.crossover.id
        #expect(backend(dx11x64, crossover(), learned: AutoGraphics(engineID: id, worked: .dxmt)) == .dxmt)
        #expect(backend(dx11x64, crossover(), learned: AutoGraphics(engineID: id, worked: .dxvk)) == .dxvk)
        #expect(backend(dx11x64, crossover(), learned: AutoGraphics(engineID: id, worked: .d3dmetal)) == .d3dmetal)
        // D3DMetal was taken out since: the next launch goes back to what Automatic would pick.
        #expect(backend(dx11x64, crossover(Self.noMetal), learned: AutoGraphics(engineID: id, worked: .d3dmetal)) == .dxvk)
        // WineD3D was never a candidate for DirectX 11, however it got in.
        #expect(backend(dx11x64, crossover(), learned: AutoGraphics(engineID: id, worked: .wined3d)) == .d3dmetal)
        // The same for Fast.
        #expect(backend(dx11x64, crossover(), options: LaunchOptions(profile: .fast),
                        learned: AutoGraphics(engineID: id, worked: .dxmt)) == .dxmt)
    }

    @Test func backendsThatFailedAreSkippedInOrderAndWhenAllFailedItStartsOver() {
        let id = EngineCatalog.crossover.id
        func pick(_ failed: [GraphicsBackend], worked: GraphicsBackend? = nil) -> GraphicsBackend {
            backend(dx11x64, crossover(), learned: AutoGraphics(engineID: id, worked: worked, failed: failed))
        }
        #expect(pick([.d3dmetal]) == .dxmt)
        #expect(pick([.d3dmetal, .dxmt]) == .dxvk)
        #expect(pick([.dxmt]) == .d3dmetal)
        #expect(pick([.d3dmetal, .dxmt, .dxvk]) == .d3dmetal)                    // everything failed: today's choice
        #expect(pick([.d3dmetal], worked: .dxvk) == .dxvk)                       // what worked wins
        #expect(pick([.d3dmetal, .dxmt, .dxvk, .wined3d]) == .d3dmetal)
        // Failures nobody can try here don't count.
        #expect(backend(dx11x64, crossover(Self.noMetal), learned: AutoGraphics(engineID: id, failed: [.d3dmetal])) == .dxvk)
        // A decoded record that contradicts itself: a failed backend isn't "the one that worked".
        #expect(pick([.dxmt], worked: .dxmt) == .d3dmetal)
    }

    @Test func theChosenBackendDecidesTheEngineFallbacks() {
        let id = EngineCatalog.crossover.id
        let onMetal = CompatResolver.resolve(input(unityDX12, crossover()))
        #expect(onMetal.backend == .d3dmetal && !onMetal.arguments.contains("-force-d3d11"))
        let after = CompatResolver.resolve(input(unityDX12, crossover(), learned: AutoGraphics(engineID: id, failed: [.d3dmetal])))
        #expect(after.backend == .dxmt && after.arguments.contains("-force-d3d11"))
    }

    @Test func whatWasLearnedOnAnotherEngineIsIgnored() {
        let learned = AutoGraphics(engineID: EngineCatalog.crossover.id, worked: .dxmt, failed: [.d3dmetal])
        #expect(backend(dx11x64, crossover(), learned: learned) == .dxmt)
        // The space moved to Wine Staging, or to a newer G-Player Wine: the record is of no use there.
        #expect(backend(dx11x64, EngineCatalog.wineStaging, learned: learned) == .dxvk)
        var newer = learned
        newer.engineID = "wine-cx-27.0.0-1"
        #expect(backend(dx11x64, crossover(), learned: newer) == .d3dmetal)
        #expect(backend(dx11x64, crossover(), learned: AutoGraphics(engineID: "", worked: .dxmt)) == .d3dmetal)
        // The record is made over for the engine it is used on.
        #expect(learned.current(on: "other") == AutoGraphics(engineID: "other"))
        #expect(learned.current(on: EngineCatalog.crossover.id) == learned)
    }

    @Test func graphicsChosenByHandAreNeverOverridden() {
        let id = EngineCatalog.crossover.id
        let learned = AutoGraphics(engineID: id, worked: .dxvk, failed: [.dxmt, .d3dmetal])
        // Custom: the backend picked under Advanced, even one that failed before.
        #expect(backend(dx11x64, crossover(), options: LaunchOptions(profile: .custom), user: .dxmt, learned: learned) == .dxmt)
        #expect(backend(dx11x64, crossover(), options: LaunchOptions(profile: .custom), user: .d3dmetal, learned: learned) == .d3dmetal)
        // Compatible is WineD3D.
        #expect(backend(dx11x64, crossover(), options: LaunchOptions(profile: .compatible), learned: learned) == .wined3d)
        // Recommended with a backend picked by hand is not automatic either: the record is left out.
        #expect(backend(dx11x64, crossover(), user: .dxmt, learned: learned) == .d3dmetal)
        let choice = CompatResolver.graphicsChoice(input(dx11x64, crossover(), options: LaunchOptions(profile: .custom), user: .dxmt, learned: learned))
        #expect(choice.backend == .dxmt && choice.failed.isEmpty && !choice.worked)

        var game = Game(title: "Indie", spaceID: UUID())
        #expect(game.graphicsAreAutomatic)
        game.options = LaunchOptions(profile: .fast)
        #expect(game.graphicsAreAutomatic)
        game.options = LaunchOptions(profile: .custom)
        #expect(!game.graphicsAreAutomatic)
        game.options = LaunchOptions(profile: .compatible)
        #expect(!game.graphicsAreAutomatic)
        game.options = nil
        game.graphics = .dxmt
        #expect(!game.graphicsAreAutomatic)
        #expect(!Game(title: "Steam", kind: .app, spaceID: UUID()).graphicsAreAutomatic)
    }

    @Test func recordingWhatWorkedAndWhatFailed() {
        var learned = AutoGraphics(engineID: "e")
        #expect(learned.isEmpty)
        learned.markFailed(.d3dmetal)
        learned.markFailed(.d3dmetal)
        learned.markFailed(.dxmt)
        #expect(learned.failed == [.d3dmetal, .dxmt] && learned.worked == nil && !learned.isEmpty)
        // Working takes a backend off the failed list; failing again takes it off "worked".
        learned.markWorked(.dxmt)
        #expect(learned.worked == .dxmt && learned.failed == [.d3dmetal])
        learned.markFailed(.dxvk)
        #expect(learned.worked == .dxmt && learned.failed == [.d3dmetal, .dxvk])
        learned.markFailed(.dxmt)
        #expect(learned.worked == nil && learned.failed == [.d3dmetal, .dxvk, .dxmt])
        learned.markWorked(.auto)
        learned.markFailed(.auto)
        #expect(learned.worked == nil && learned.failed == [.d3dmetal, .dxvk, .dxmt])
    }

    @Test func theChoiceSaysWhatIsUsedAndWhy() {
        let id = EngineCatalog.crossover.id
        func choice(_ learned: AutoGraphics?) -> CompatResolver.GraphicsChoice {
            CompatResolver.graphicsChoice(input(dx11x64, crossover(), learned: learned))
        }
        let fresh = choice(nil)
        #expect(fresh.backend == .d3dmetal && fresh.candidates == [.d3dmetal, .dxmt, .dxvk] && fresh.isUntried)
        #expect(fresh.summary == "D3DMetal — picked automatically")
        #expect(fresh.alternative(to: .d3dmetal) == .dxmt && fresh.alternative(to: .dxmt) == .d3dmetal)

        let worked = choice(AutoGraphics(engineID: id, worked: .dxmt))
        #expect(worked.worked && worked.summary == "DXMT — picked automatically, worked last time")

        let failed = choice(AutoGraphics(engineID: id, failed: [.d3dmetal]))
        #expect(failed.backend == .dxmt && failed.summary == "DXMT — picked automatically, D3DMetal didn't work")
        let two = choice(AutoGraphics(engineID: id, failed: [.d3dmetal, .dxmt]))
        #expect(two.summary == "DXVK — picked automatically, D3DMetal and DXMT didn't work")
        #expect(two.alternative(to: .dxvk) == nil)

        let none = choice(AutoGraphics(engineID: id, failed: [.d3dmetal, .dxmt, .dxvk]))
        #expect(none.backend == .d3dmetal && !none.isUntried && none.alternative(to: .d3dmetal) == nil)
        #expect(none.summary == "D3DMetal — picked automatically, though D3DMetal, DXMT and DXVK didn't work last time")
        // Only what can be tried here is mentioned.
        let gone = CompatResolver.graphicsChoice(input(dx11x64, crossover(Self.noMetal), learned: AutoGraphics(engineID: id, failed: [.d3dmetal])))
        #expect(gone.failed.isEmpty && gone.summary == "DXVK — picked automatically")
    }

    @Test func theTriedGraphicsAreAddedToAFailureOnlyWhenThereWereSeveral() {
        let found = [Diagnosis(kind: .graphics, title: "Graphics didn't start", detail: "The game couldn't create its graphics device.",
                               remedy: .useProfile(.compatible))]
        let said = LogDiagnosis.mentioning(tried: [.dxvk, .dxmt], in: found)
        #expect(said.count == 1 && said[0].kind == .graphics && said[0].title == found[0].title && said[0].remedy == found[0].remedy)
        #expect(said[0].detail == "The game couldn't create its graphics device. Graphics tried: DXVK and DXMT.")
        #expect(LogDiagnosis.mentioning(tried: [.dxvk], in: found) == found)
        #expect(LogDiagnosis.mentioning(tried: [], in: found) == found)
        #expect(LogDiagnosis.mentioning(tried: [.dxvk, .dxmt], in: []).isEmpty)
        #expect(LogDiagnosis.mentioning(tried: [.d3dmetal, .dxmt, .dxvk], in: found)[0].detail.hasSuffix("Graphics tried: D3DMetal, DXMT and DXVK."))
    }

    // MARK: When G-Player may act by itself

    func choice(_ analysis: GameAnalysis?, _ engine: EngineInfo, learned: AutoGraphics? = nil) -> CompatResolver.GraphicsChoice {
        CompatResolver.graphicsChoice(input(analysis, engine, learned: learned))
    }

    func found(_ kind: Diagnosis.Kind) -> [Diagnosis] {
        [Diagnosis(kind: kind, title: kind.rawValue, detail: "", remedy: .none)]
    }

    @Test func onlyAGameInASpaceItMayChangeAndNotEpicsIsTried() {
        var game = Game(title: "Indie", spaceID: UUID())
        #expect(GraphicsRetry.mayTry(game, spaceMayChange: true))
        #expect(!GraphicsRetry.mayTry(game, spaceMayChange: false))                  // the backend's DLLs would never reach it
        game.options = LaunchOptions(profile: .custom)
        #expect(!GraphicsRetry.mayTry(game, spaceMayChange: true))
        game.options = nil
        game.source = .epic(appName: "x", launchURI: "u")
        #expect(!GraphicsRetry.mayTry(game, spaceMayChange: true))
        game.source = .steam(appID: "1")
        #expect(GraphicsRetry.mayTry(game, spaceMayChange: true))
    }

    @Test func aFailureIsActedOnOnlyOnEvidenceFromALog() {
        let c = choice(dx11x64, crossover())                                          // d3dmetal, dxmt, dxvk
        func outcome(_ kinds: [Diagnosis.Kind], ran: Double = 8, backend: GraphicsBackend = .d3dmetal) -> GraphicsRetry.Outcome {
            GraphicsRetry.outcome(of: kinds.flatMap(found), ran: ran, choice: c, backend: backend)
        }
        #expect(outcome([.graphics]) == .retry(.dxmt))
        #expect(outcome([.crash]) == .retry(.dxmt))
        #expect(outcome([.graphics], backend: .dxmt) == .retry(.d3dmetal))            // what hasn't failed, in order
        // Evidence counts only for a game that ended before it could have been played: a crash at exit after 40 seconds, or a
        // DirectX 12 failure line followed by a working DirectX 11 fallback, is for the user to judge.
        #expect(outcome([.crash], ran: 29) == .retry(.dxmt))
        #expect(outcome([.crash], ran: 30) == .offer(.dxmt))
        #expect(outcome([.crash], ran: 40) == .offer(.dxmt))
        #expect(outcome([.graphics], ran: 40) == .offer(.dxmt))
        #expect(outcome([.graphics], ran: 59) == .offer(.dxmt))
        // Closing at once, or never opening, is not evidence: a player quitting, a slow first Steam, a program handing over.
        #expect(outcome([.closedRightAway]) == .offer(.dxmt))
        #expect(outcome([.closedRightAway], ran: 0) == .offer(.dxmt))
        // Missing components and anti-cheat have their own remedies, and a log that says nothing is nothing.
        #expect(outcome([.missingComponent]) == .nothing)
        #expect(outcome([.antiCheat]) == .nothing)
        #expect(outcome([.graphics, .missingComponent]) == .nothing)
        #expect(outcome([.crash, .antiCheat]) == .nothing)
        #expect(outcome([]) == .nothing)
        // A minute of running means it works, whatever the log says after.
        #expect(outcome([.crash], ran: 60) == .worked)
        #expect(outcome([], ran: 120) == .worked)
        #expect(outcome([.closedRightAway], ran: 59) == .offer(.dxmt))
    }

    @Test func whenNothingIsLeftToTryTheRoundHasRunOut() {
        let id = EngineCatalog.crossover.id
        let last = choice(dx11x64, crossover(), learned: AutoGraphics(engineID: id, failed: [.d3dmetal, .dxmt]))
        #expect(last.backend == .dxvk)
        #expect(GraphicsRetry.outcome(of: found(.graphics), ran: 5, choice: last, backend: .dxvk) == .exhausted)
        #expect(GraphicsRetry.outcome(of: found(.closedRightAway), ran: 5, choice: last, backend: .dxvk) == .exhausted)
        #expect(last.tried(afterFailing: .dxvk) == [.d3dmetal, .dxmt, .dxvk])
        #expect(last.tried(afterFailing: .dxmt) == [.d3dmetal, .dxmt])
        // A game with one candidate has nothing to try and learns nothing.
        let single = choice(dx11x64, EngineCatalog.wineStaging)
        #expect(GraphicsRetry.outcome(of: found(.graphics), ran: 5, choice: single, backend: .dxvk) == .exhausted)
        #expect(single.tried(afterFailing: .dxvk) == [.dxvk])
    }

    @Test func theNextBackendKeepsWhatWorkedFirstUnlessThatIsWhatFailed() {
        let id = EngineCatalog.crossover.id
        let worked = choice(dx11x64, crossover(), learned: AutoGraphics(engineID: id, worked: .dxmt))
        #expect(worked.backend == .dxmt)
        #expect(worked.next(afterFailing: .dxmt) == .d3dmetal)
        #expect(worked.next(afterFailing: .dxvk) == .dxmt)                             // what worked is still the first choice
        let fresh = choice(dx11x64, crossover())
        #expect(fresh.next(afterFailing: .d3dmetal) == .dxmt && fresh.next(afterFailing: .dxmt) == .d3dmetal)
        #expect(!fresh.hasLearned && worked.hasLearned)
        #expect(choice(dx11x64, crossover(), learned: AutoGraphics(engineID: id, failed: [.dxmt])).hasLearned)
    }

    @Test func aGameWithOneCandidateLearnsNothingAndShowsNothingLearned() {
        let id = EngineCatalog.wineStaging.id
        let record = AutoGraphics(engineID: id, worked: .dxvk, failed: [.wined3d])
        for analysis in [dx11x64, dx11x32, GameAnalysis(graphics: [.d3d9], architecture: .x64), nil] {
            let single = choice(analysis, EngineCatalog.wineStaging, learned: record)
            #expect(single.candidates == [.dxvk] && single.backend == .dxvk)
            #expect(!single.worked && single.failed.isEmpty && !single.hasLearned)
            #expect(single.summary == "DXVK — picked automatically")
            #expect(!GraphicsRetry.learns(from: Game(title: "Indie", spaceID: UUID()), spaceMayChange: true, choice: single, steam: .notSteam))
        }
        // DirectX 9 on G-Player Wine is one candidate too, with a record from a time there were more.
        let dx9 = choice(GameAnalysis(graphics: [.d3d9], architecture: .x64), crossover(),
                         learned: AutoGraphics(engineID: EngineCatalog.crossover.id, failed: [.dxvk]))
        #expect(dx9.failed.isEmpty && !dx9.hasLearned)
    }

    @Test func aLaunchIsLearnedFromOnlyWhenG_PlayerChoseAndKnowsWhatRan() {
        let game = Game(title: "Indie", spaceID: UUID(), source: .steam(appID: "1"))
        let several = choice(dx11x64, crossover())
        #expect(GraphicsRetry.learns(from: game, spaceMayChange: true, choice: several, steam: .started))
        #expect(GraphicsRetry.learns(from: game, spaceMayChange: true, choice: several, steam: .runningAsPlanned))
        #expect(GraphicsRetry.learns(from: game, spaceMayChange: true, choice: several, steam: .notSteam))
        // A running Steam with unknown or other settings gives the game its own: nothing is learned.
        #expect(!GraphicsRetry.learns(from: game, spaceMayChange: true, choice: several, steam: .runningOtherwise))
        // A space G-Player may not change never gets the backend's files.
        #expect(!GraphicsRetry.learns(from: game, spaceMayChange: false, choice: several, steam: .started))
        var custom = game
        custom.options = LaunchOptions(profile: .custom)
        #expect(!GraphicsRetry.learns(from: custom, spaceMayChange: true, choice: several, steam: .started))
        #expect(!GraphicsRetry.learns(from: game, spaceMayChange: true, choice: choice(dx11x64, EngineCatalog.wineStaging), steam: .started))
    }

    @Test func steamAtLaunchSaysWhetherTheGameRunsWithWhatItAskedFor() {
        let known = LauncherSettings(backend: .dxvk)
        func at(_ isSteam: Bool = true, running: Bool, settings: LauncherSettings?, fresh: Bool) -> GraphicsRetry.SteamAtLaunch {
            GraphicsRetry.steamAtLaunch(isSteamGame: isSteam, wasRunning: running, knownSettings: settings, needsFreshLauncher: fresh)
        }
        #expect(at(false, running: true, settings: nil, fresh: true) == .notSteam)
        #expect(at(running: false, settings: nil, fresh: true) == .started)               // G-Player starts Steam for it
        #expect(at(running: true, settings: known, fresh: false) == .runningAsPlanned)
        #expect(at(running: true, settings: nil, fresh: false) == .runningOtherwise)       // started by someone else: unknown
        #expect(at(running: true, settings: known, fresh: true) == .runningOtherwise)      // played with the Steam that was open
    }

    @Test func steamIsRestartedWithoutAskingOnlyWhenNothingElseIsOpen() {
        let game = UUID(), other = UUID()
        func may(running: [UUID] = [], busy: [UUID] = [], installs: Bool = false) -> Bool {
            GraphicsRetry.mayRestartSteamSilently(for: game, running: Set(running), busy: Set(busy), installsQueued: installs)
        }
        #expect(may())
        #expect(may(running: [game], busy: [game]))                                        // the game itself doesn't count
        #expect(!may(running: [other]))
        #expect(!may(busy: [other]))                                                       // preparing, starting, or restarting Steam
        #expect(!may(installs: true))
        #expect(!may(running: [game, other]))
    }

    @Test func aRecordOfSteamIsKeptThroughALookThatMissesIt() {
        let start = Date(timeIntervalSince1970: 1000)
        func launcher() -> KnownLauncher { KnownLauncher(settings: LauncherSettings(backend: .dxvk), startedAt: start) }
        /// The looks in order: (seconds after the record, Steam seen), and whether the record is kept after each.
        func kept(_ looks: [(Double, Bool)]) -> [Bool] {
            var record = launcher()
            return looks.map { record.look(steamRunning: $0.1, at: start.addingTimeInterval($0.0)) }
        }
        // A fresh record survives one look that misses Steam, and two looks that don't miss it twice in a row.
        #expect(kept([(3, false)]) == [true])
        #expect(kept([(3, false), (4, true), (5, false)]) == [true, true, true])
        #expect(kept([(3, false), (4, false)]) == [true, false])                             // gone on two looks in a row
        // An older record goes at the first look that misses Steam.
        #expect(kept([(60, true), (61, false)]) == [true, false])
        #expect(kept([(10, false)]) == [true])                                              // ten seconds is not older than ten
        #expect(kept([(11, false)]) == [false])
        // A look made before the record says nothing about it, and counts for nothing later.
        #expect(kept([(-5, false), (-1, false), (1, false)]) == [true, true, true])
        var record = launcher()
        _ = record.look(steamRunning: false, at: start.addingTimeInterval(-5))
        _ = record.look(steamRunning: false, at: start.addingTimeInterval(1))
        #expect(record.goneLooks == 1)
    }

    @Test func thePictureMissingButtonNeedsAnAlternativeAndARunG_PlayerStarted() {
        let id = EngineCatalog.crossover.id
        let c = choice(dx11x64, crossover())
        #expect(GraphicsRetry.otherGraphics(for: c, launched: .d3dmetal) == .dxmt)
        #expect(GraphicsRetry.otherGraphics(for: c, launched: .dxmt) == .d3dmetal)
        #expect(GraphicsRetry.otherGraphics(for: c, launched: nil) == nil)                  // not started by G-Player: unknown
        let tried = choice(dx11x64, crossover(), learned: AutoGraphics(engineID: id, failed: [.dxmt, .dxvk]))
        #expect(GraphicsRetry.otherGraphics(for: tried, launched: .d3dmetal) == nil)
        #expect(GraphicsRetry.otherGraphics(for: choice(dx11x64, EngineCatalog.wineStaging), launched: .dxvk) == nil)
    }

    // MARK: Unity's own log

    @Test func aUnityLogThatSaysItsGraphicsDidntStartIsAGraphicsFailure() {
        // Lines as Unity writes them to Player.log; each alone is enough.
        for line in ["Failed to initialize graphics.", "d3d11: failed to create device (80004005)",
                     "d3d11: failed to create device and context (80004005).", "Direct3D 11 failed.\nInitializeEngineGraphics failed"] {
            let log = "Initialize engine version: 2022.3.10f1\nGfxDevice: creating device client; threaded=1\n\(line)\nCrash!!!\n"
            let found = LogDiagnosis.diagnose(log: log, exitStatus: 1, seconds: 8, profile: .recommended)
            #expect(found.first?.kind == .graphics, "\(line)")
        }
        // Other Unity noise isn't one: a managed exception is a crash, a quiet log says nothing at all.
        let quiet = "Initialize engine version: 2022.3.10f1\nGfxDevice: creating device client; threaded=1\nSetting up 2 worker threads\n"
        #expect(LogDiagnosis.diagnose(log: quiet, exitStatus: 1, seconds: 8, profile: .recommended).first?.kind == .closedRightAway)
        #expect(LogDiagnosis.diagnose(log: quiet, exitStatus: 1, seconds: 40, profile: .recommended).isEmpty)
    }

    /// A Player.log as Unity starts one, with the folder the game was started from in its first lines.
    func playerLog(_ folder: String, _ line: String = "Failed to initialize graphics.") -> Data {
        Data("""
            Initialize engine version: 2022.3.10f1
            Forcing GfxDevice: Null
            Mono path[0] = '\(folder)/Indie_Data/Managed'
            Mono config path = '\(folder)/Indie_Data/MonoBleedingEdge/etc'
            \(line)

            """.utf8)
    }

    @Test func aUnityLogBelongsToTheGameWhoseFolderItNames() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Main"))
        let folder = s.driveC.appendingPathComponent("Games/Indie", isDirectory: true)
        func belongs(_ head: String, _ folder: URL = folder) -> Bool { LogDiagnosis.unityLog(head, belongsToGameIn: folder, in: s) }
        #expect(belongs("Mono path[0] = 'C:/Games/Indie/Indie_Data/Managed'"))
        #expect(belongs("Mono path[0] = 'c:\\games\\indie\\Indie_Data\\Managed'"))               // any case, either slash
        #expect(belongs("[Subsystems] Discovering subsystems at path C:/Games/Indie/Indie_Data/UnitySubsystems"))
        // Another Unity game in the space, or one whose folder only starts the same.
        #expect(!belongs("Mono path[0] = 'C:/Games/Other/Other_Data/Managed'"))
        #expect(!belongs("Mono path[0] = 'C:/Games/Indie 2/Indie 2_Data/Managed'"))
        #expect(!belongs("Mono path[0] = 'C:/Games/Indie'"))
        #expect(!belongs(""))
        // A game outside the space's C: is named as Z: paths.
        let outside = URL(fileURLWithPath: "/Users/me/Games/Indie", isDirectory: true)
        #expect(belongs("Mono path[0] = 'Z:/Users/me/Games/Indie/Indie_Data/Managed'", outside))
    }

    @Test func theUnityLogOfAnotherGameIsNotTaken() throws {
        let tmp = TempFolder()
        let s = space(at: tmp.prefix("Main"))
        let fm = FileManager.default
        func write(_ company: String, _ folder: String, age: TimeInterval) {
            let log = tmp.file("Main/drive_c/users/me/AppData/LocalLow/Company/\(company)/Player.log", contents: playerLog(folder))
            try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: log.path)
        }
        write("Mine", "C:/Games/Indie", age: 30)
        write("Other", "C:/Games/Other", age: 5)                                          // newer, from another game
        let folder = s.driveC.appendingPathComponent("Games/Indie", isDirectory: true)
        let found = try #require(LogDiagnosis.unityLog(in: s, gameFolder: folder, since: Date().addingTimeInterval(-120)))
        #expect(found.deletingLastPathComponent().lastPathComponent == "Mine")
        #expect(LogDiagnosis.diagnose(log: LogDiagnosis.tail(of: found), exitStatus: 1, seconds: 8, profile: .recommended).first?.kind == .graphics)
        // Nothing before `since`, and without a folder to match there is nothing to tell whose it is.
        #expect(LogDiagnosis.unityLog(in: s, gameFolder: folder, since: Date()) == nil)
        #expect(LogDiagnosis.unityLog(in: s, gameFolder: nil, since: Date().addingTimeInterval(-120)) == nil)
        #expect(LogDiagnosis.unityLog(in: s, gameFolder: s.driveC.appendingPathComponent("Games/Third"), since: Date().addingTimeInterval(-120)) == nil)
    }

    // MARK: In the library

    @Test func aLibraryWithoutTheFieldStillLoadsAndWhatWasLearnedSurvives() throws {
        let tmp = TempFolder()
        let store = LibraryStore(paths: LibraryPaths(root: tmp.url))
        var state = LibraryState()
        let s = Space(name: "Main", path: "/x", engineID: "e", origin: .managed)
        state.spaces = [s]
        state.games = [Game(title: "Old", spaceID: s.id), Game(title: "Learned", spaceID: s.id)]
        state.games[1].autoGraphics = AutoGraphics(engineID: "e", worked: .dxmt, failed: [.dxvk])
        try store.save(state)

        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.libraryFile)) as? [String: Any])
        let games = try #require(root["games"] as? [[String: Any]])
        #expect(games[0]["autoGraphics"] == nil)                                      // nothing learned: nothing written
        #expect(games[1]["autoGraphics"] != nil)
        // As a library from before the field: no key at all.
        var older = games
        older[1].removeValue(forKey: "autoGraphics")
        root["games"] = older
        try JSONSerialization.data(withJSONObject: root).write(to: store.paths.libraryFile)
        let loaded = try store.load()
        #expect(loaded.games.count == 2 && loaded.games.allSatisfy { $0.autoGraphics == nil })

        try store.save(state)
        let back = try store.load()
        #expect(back.games[1].autoGraphics == AutoGraphics(engineID: "e", worked: .dxmt, failed: [.dxvk]))
        #expect(back.games[0].autoGraphics == nil)
    }

    @Test func aRecordThisVersionCantReadMeansNothingWasLearned() throws {
        func decode(_ json: String) throws -> AutoGraphics {
            try JSONDecoder().decode(AutoGraphics.self, from: Data(json.utf8))
        }
        #expect(try decode("{}") == AutoGraphics(engineID: ""))
        #expect(try decode(#"{"engineID": "e", "worked": "dxmt", "failed": ["dxvk"], "later": 1}"#)
                == AutoGraphics(engineID: "e", worked: .dxmt, failed: [.dxvk]))
        // A newer G-Player's backend, and wrong types, fall back to nothing without spoiling the rest.
        let odd = try decode(#"{"engineID": "e", "worked": "metal4", "failed": ["dxvk", "metal4"]}"#)
        #expect(odd == AutoGraphics(engineID: "e"))
        #expect(try decode(#"{"engineID": 7, "worked": 3, "failed": "dxvk"}"#) == AutoGraphics(engineID: ""))
        // An empty engine id matches no engine, so it is never used.
        #expect(try decode(#"{"worked": "dxmt"}"#).current(on: "e").worked == nil)
    }

    // MARK: Planning

    @Test func theLaunchPlanUsesWhatWasLearned() throws {
        let tmp = TempFolder()
        var s = space(at: tmp.prefix("Main"))
        s.engineID = EngineCatalog.crossover.id
        let exe = tmp.file("Main/drive_c/Games/Indie.exe")
        var game = Game(title: "Indie", spaceID: s.id, executablePath: Game.storedPath(for: exe, in: s))
        game.analysis = dx11x64
        func plan(_ g: Game) throws -> LaunchPlan { try LaunchPlanner.plan(for: g, in: s, ready: Self.everything) }
        #expect(try plan(game).backend == .d3dmetal)
        game.autoGraphics = AutoGraphics(engineID: EngineCatalog.crossover.id, worked: .dxmt)
        #expect(try plan(game).backend == .dxmt)
        #expect(try plan(game).compat?.backend == .dxmt)
        game.autoGraphics = AutoGraphics(engineID: EngineCatalog.crossover.id, failed: [.d3dmetal])
        #expect(try plan(game).backend == .dxmt)
        // Another engine's record, or graphics chosen by hand: left alone.
        game.autoGraphics = AutoGraphics(engineID: EngineCatalog.wineStaging.id, worked: .dxmt)
        #expect(try plan(game).backend == .d3dmetal)
        game.autoGraphics = AutoGraphics(engineID: EngineCatalog.crossover.id, worked: .dxmt)
        game.options = LaunchOptions(profile: .custom)
        game.graphics = .dxvk
        #expect(try plan(game).backend == .dxvk)
        game.options = LaunchOptions(profile: .compatible)
        #expect(try plan(game).backend == .wined3d)
    }

    @Test func steamNeedsRestartingForABackendItWasntStartedWith() throws {
        let tmp = TempFolder()
        var s = space(at: tmp.prefix("Steam"), preset: "steam")
        s.engineID = EngineCatalog.crossover.id
        let steam = "Steam/drive_c/Program Files (x86)/Steam"
        tmp.file("\(steam)/steam.exe")
        tmp.file("\(steam)/steamapps/appmanifest_1.acf", contents: Data("""
            "AppState" { "appid" "1" "name" "Test Game" "StateFlags" "4" "installdir" "TestGame" }
            """.utf8))
        tmp.file("\(steam)/steamapps/common/TestGame/TestGame.exe")
        var game = Game(title: "Indie", spaceID: s.id, source: .steam(appID: "1"))
        game.analysis = dx11x64
        func plan(_ g: Game, launcher: LauncherSettings? = nil) throws -> LaunchPlan {
            try LaunchPlanner.plan(for: g, in: s, ready: Self.everything, launcher: launcher)
        }
        let first = try plan(game)
        #expect(first.backend == .d3dmetal && !first.needsFreshLauncher)
        // DXMT after D3DMetal failed: the running Steam has D3DMetal, so it has to start again; the new one needs nothing.
        game.autoGraphics = AutoGraphics(engineID: EngineCatalog.crossover.id, failed: [.d3dmetal])
        let retry = try plan(game, launcher: first.launcherSettings)
        #expect(retry.backend == .dxmt && retry.needsFreshLauncher)
        #expect(retry.launcherSettings == LauncherSettings(backend: .dxmt))
        #expect(try plan(game, launcher: retry.launcherSettings).needsFreshLauncher == false)
    }
}

/// `Game` reads every field itself, so one that was left out would be lost on every load.
@Suite struct GameDecodingTests {
    func everything() -> Game {
        var g = Game(title: "Indie", kind: .game, spaceID: UUID(), source: .steam(appID: "1"), executablePath: "drive_c/Games/Indie.exe",
                     arguments: ["-windowed"], graphics: .dxvk, environment: ["A": "B"], coverFile: "cover.png",
                     addedAt: Date(timeIntervalSince1970: 1_700_000_000), lastPlayedAt: Date(timeIntervalSince1970: 1_700_000_500),
                     secondsPlayed: 42, hidden: true, iconFile: "icon.png")
        g.options = LaunchOptions(profile: .fast, windowMode: .windowed, retina: true)
        g.analysis = GameAnalysis(engine: .unity, graphics: [.d3d11], architecture: .x64)
        g.autoGraphics = AutoGraphics(engineID: "e", worked: .dxmt, failed: [.dxvk])
        return g
    }

    @Test func everyFieldSurvivesARoundTrip() throws {
        let game = everything()
        let back = try JSONDecoder().decode(Game.self, from: JSONEncoder().encode(game))
        #expect(back == game)
        // Every key written is read: none may be left at its default.
        let keys = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(game)) as? [String: Any]).keys
        #expect(keys.count == 18)
    }

    @Test func whatG_PlayerLearnedCantCostTheGame() throws {
        let mine = everything()
        func game(_ value: String) throws -> Game {
            var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(mine)) as? [String: Any])
            object["autoGraphics"] = try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
            return try JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: object))
        }
        for odd in [#""junk""#, "7", "[1, 2]", "true", "null"] {
            let loaded = try game(odd)
            #expect(loaded.autoGraphics == nil, "\(odd)")
            var expected = mine
            expected.autoGraphics = nil
            #expect(loaded == expected, "\(odd)")                                          // the rest of the game is intact
        }
        // An object it can partly read keeps what it can.
        #expect(try game(#"{"engineID": "e", "worked": "dxmt", "failed": "oops"}"#).autoGraphics == AutoGraphics(engineID: "e", worked: .dxmt))
        // A game written before the field.
        var older = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(mine)) as? [String: Any])
        older.removeValue(forKey: "autoGraphics")
        #expect(try JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: older)).autoGraphics == nil)
    }
}
