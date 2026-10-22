import Foundation

/// What G-Player learned about one game's graphics while Automatic chose them: the backend that ran it for a while,
/// and the ones that didn't. Kept on the game, so the next launch starts from what worked. It belongs to the engine it
/// was learned on (another engine has other backends and other bugs), so it is ignored on any other.
public struct AutoGraphics: Codable, Sendable, Hashable {
    /// `EngineInfo.id` it was learned on.
    public var engineID: String
    /// The backend that kept the game running for a minute, if one did.
    public var worked: GraphicsBackend?
    /// Backends the game failed with, in the order they failed.
    public var failed: [GraphicsBackend]

    public init(engineID: String, worked: GraphicsBackend? = nil, failed: [GraphicsBackend] = []) {
        self.engineID = engineID; self.worked = worked; self.failed = failed
    }

    /// Every field is optional on disk, so a library written by an older or newer G-Player still opens. What can't be
    /// read means nothing was learned (an empty engine id matches no engine).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engineID = c.value(.engineID, default: "")
        worked = c.value(.worked, default: nil)
        failed = c.value(.failed, default: [])
    }

    public var isEmpty: Bool { worked == nil && failed.isEmpty }

    /// What is known on `engineID`: this, or nothing when it was learned on another engine.
    public func current(on engineID: String) -> AutoGraphics {
        self.engineID == engineID ? self : AutoGraphics(engineID: engineID)
    }

    /// The game ran with `backend` and didn't work. Whatever was remembered as working with it no longer is.
    public mutating func markFailed(_ backend: GraphicsBackend) {
        guard backend != .auto else { return }
        if worked == backend { worked = nil }
        if !failed.contains(backend) { failed.append(backend) }
    }

    /// The game kept running with `backend`: it is the one to start with, and no longer counts as failed.
    public mutating func markWorked(_ backend: GraphicsBackend) {
        guard backend != .auto else { return }
        worked = backend
        failed.removeAll { $0 == backend }
    }
}

extension CompatResolver {
    /// The backends worth trying for a game, best first, when graphics are automatic (the Recommended and Fast
    /// profiles). The first is what Automatic has always chosen, so a game that works changes nothing; the rest are
    /// the other backends that change something for the game's graphics API. Only backends the engine can run are
    /// there (`Input.engine` is limited to the ready ones). Compatible and Custom are the user's own choice: they get
    /// the one backend they resolve to.
    ///
    /// G-Player swaps only `d3d11`, `d3d10core` and `dxgi`, so for DirectX 9 and older, OpenGL, Vulkan and unknown games
    /// no other backend would change anything, and WineD3D can't give DirectX 10 or 11 on Apple's OpenGL 4.1.
    public static func graphicsCandidates(_ input: Input) -> [GraphicsBackend] {
        let engine = input.engine
        let a = input.analysis ?? GameAnalysis()
        let profile = input.options.profile.effective(on: engine)
        switch profile {
        case .compatible: return [engine.resolve(.wined3d)]
        case .custom: return [engine.resolve(input.userBackend)]
        case .recommended, .fast: break
        }
        var list = [automaticBackend(on: engine, for: a, profile: profile)]
        // Unity and Unreal start in DirectX 11 when asked (`-force-d3d11`, `-dx11`), unless built for DirectX 12 alone.
        let fallsBackToDirect3D11 = a.engine == .unity || (a.engine == .unreal && !a.onlyDirect3D12)
        let others: [GraphicsBackend]
        switch a.likelyDirect3D {
        case .d3d10?, .d3d11?: others = is32Bit(a) ? [.dxvk, .dxmt] : [.d3dmetal, .dxmt, .dxvk]
        case .d3d12?: others = fallsBackToDirect3D11 ? [.d3dmetal, .dxmt, .dxvk] : [.d3dmetal]
        default: others = []
        }
        for backend in others where engine.backends.contains(backend) && !list.contains(backend)
            && (backend != .d3dmetal || supportsD3DMetal(engine, a)) {
            list.append(backend)
        }
        return list
    }

    /// What one launch with automatic graphics uses, and what G-Player knows about it.
    public struct GraphicsChoice: Sendable, Equatable {
        /// `graphicsCandidates`: today's choice first.
        public var candidates: [GraphicsBackend]
        /// What the launch uses.
        public var backend: GraphicsBackend
        /// `backend` is the one that worked last time.
        public var worked: Bool
        /// Candidates the game failed with, in the order they failed (nothing learned on another engine counts).
        public var failed: [GraphicsBackend]

        /// `backend` hasn't failed before: it is something new to try.
        public var isUntried: Bool { !failed.contains(backend) }

        /// Something is remembered that How it runs should say and "Start Over" can forget. A game with one candidate
        /// learns nothing (there is nothing else to try), so it never has.
        public var hasLearned: Bool { worked || !failed.isEmpty }

        /// What the next launch would use once `backend` has failed, or nil when nothing is left to try. The one that
        /// worked stays first, unless it is the one that failed.
        public func next(afterFailing backend: GraphicsBackend) -> GraphicsBackend? {
            if worked, self.backend != backend { return self.backend }
            return candidates.first { $0 != backend && !failed.contains($0) }
        }

        /// Every candidate that has failed once `backend` has too, in the order they failed.
        public func tried(afterFailing backend: GraphicsBackend) -> [GraphicsBackend] {
            failed.contains(backend) || !candidates.contains(backend) ? failed : failed + [backend]
        }

        /// The backend to try when `current` doesn't work: the first candidate that isn't it and hasn't failed.
        public func alternative(to current: GraphicsBackend) -> GraphicsBackend? {
            candidates.first { $0 != current && !failed.contains($0) }
        }

        /// One plain line for the inspector: what is used and why.
        public var summary: String {
            let name = backend.displayName
            if worked { return "\(name) — picked automatically, worked last time" }
            if failed.isEmpty { return "\(name) — picked automatically" }
            let list = CompatResolver.list(failed.map(\.displayName))
            return failed.contains(backend) ? "\(name) — picked automatically, though \(list) didn't work last time"
                                            : "\(name) — picked automatically, \(list) didn't work"
        }
    }

    /// The backend for a launch with automatic graphics: the one that worked, if it is still a candidate; else the first
    /// candidate that hasn't failed; else, with every candidate failed, today's choice. What was learned counts only for
    /// the Recommended and Fast profiles with no backend chosen by hand, only on the engine it was learned on, and only
    /// for a game with more than one candidate.
    public static func graphicsChoice(_ input: Input) -> GraphicsChoice {
        let candidates = graphicsCandidates(input)
        let profile = input.options.profile.effective(on: input.engine)
        // With nothing else to try there is nothing to learn: a record from a time there was more is left alone.
        guard candidates.count > 1, input.userBackend == .auto, profile == .recommended || profile == .fast,
              let learned = input.autoGraphics, learned.engineID == input.engine.id else {
            return GraphicsChoice(candidates: candidates, backend: candidates[0], worked: false, failed: [])
        }
        var seen = Set<GraphicsBackend>()
        let failed = learned.failed.filter { candidates.contains($0) && seen.insert($0).inserted }
        if let worked = learned.worked, candidates.contains(worked), !failed.contains(worked) {
            return GraphicsChoice(candidates: candidates, backend: worked, worked: true, failed: failed)
        }
        return GraphicsChoice(candidates: candidates, backend: candidates.first { !failed.contains($0) } ?? candidates[0],
                              worked: false, failed: failed)
    }

    // MARK: Pieces

    /// A 32-bit program (a .NET one may be AnyCPU, so it isn't): D3DMetal runs 64-bit programs only.
    static func is32Bit(_ a: GameAnalysis) -> Bool { a.architecture == .x86 && !a.isDotNet }

    static func supportsD3DMetal(_ engine: EngineInfo, _ a: GameAnalysis) -> Bool {
        engine.backends.contains(.d3dmetal) && !is32Bit(a)
    }

    /// What Automatic chooses before anything is learned, for the Recommended and Fast profiles.
    static func automaticBackend(on engine: EngineInfo, for a: GameAnalysis, profile: LaunchProfile) -> GraphicsBackend {
        let supportsMetal = supportsD3DMetal(engine, a)
        let newest = a.likelyDirect3D
        // On G-Player Wine D3DMetal takes 64-bit DirectX 10–12 in Recommended too: Apple's path to Metal is the most
        // direct one. DirectX 9, OpenGL and Vulkan stay on Wine's own (D3DMetal has no Direct3D 9).
        let direct3D10to12 = newest.map { $0 >= .d3d10 && $0 <= .d3d12 } ?? false
        let metalByDefault = engine.kind == .crossover && direct3D10to12
        if supportsMetal && (newest == .d3d12 || metalByDefault || (profile == .fast && (direct3D10to12 || engine.kind == .gptk))) {
            return .d3dmetal
        }
        return engine.resolve(engine.backends.first { $0 != .d3dmetal || supportsMetal } ?? .wined3d)
    }
}
