import Foundation

/// A Windows program G-Player started. Ends when the program's Wine process exits.
public final class RunningProgram: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let process: Process
    public let logFile: URL
    public let startedAt = Date()
    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    init(process: Process, logFile: URL) { self.process = process; self.logFile = logFile }

    public func terminate() { if process.isRunning { process.terminate() } }
}

public enum WineLauncher {
    /// Starts `arguments` under Wine (x86_64, through Rosetta) and returns at once.
    /// `onExit` runs on a background queue with the exit status.
    public static func start(engine: Engine, space: Space, arguments: [String], workingDirectory: URL?,
                             backend: GraphicsBackend, tweaks: LaunchTweaks = LaunchTweaks(),
                             logsFolder: URL, logName: String,
                             onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProgram {
        try FileManager.default.createDirectory(at: logsFolder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let log = logsFolder.appendingPathComponent("\(Files.safeName(logName)) \(stamp).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let env = WineEnvironment.make(engine: engine, space: space, backend: backend, tweaks: tweaks)
        handle.write(Data(logHeader(engine: engine, space: space, backend: backend, arguments: arguments, environment: env).utf8))

        let process = Process()
        process.executableURL = Shell.tool("arch")
        process.arguments = ["-x86_64", engine.wine.path] + arguments
        process.environment = env
        process.currentDirectoryURL = workingDirectory ?? space.driveC
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { p in
            try? handle.close()
            onExit?(p.terminationStatus)
        }
        try process.run()
        return RunningProgram(process: process, logFile: log)
    }

    /// The first lines of a launch's log. The command is written with the secrets of its arguments hidden (`LaunchSecrets`: the
    /// one-time code an Epic game is started with); the program gets the real ones.
    static func logHeader(engine: Engine, space: Space, backend: GraphicsBackend, arguments: [String],
                          environment: [String: String]) -> String {
        "G-Player launch\nengine: \(engine.info.name) \(engine.info.version)\nspace: \(space.path)\n"
            + "backend: \(engine.resolve(backend).displayName)\ncommand: \(LaunchSecrets.masked(arguments).joined(separator: " "))\n"
            + "WINEDLLOVERRIDES=\(environment["WINEDLLOVERRIDES"] ?? "")\n\n"
    }

    /// Runs a Wine tool (wineboot, reg, winecfg) and waits for it.
    @discardableResult
    public static func runTool(engine: Engine, space: Space, _ arguments: [String],
                               backend: GraphicsBackend = .wined3d) async throws -> ProcessResult {
        let env = WineEnvironment.make(engine: engine, space: space, backend: backend)
        return try await Shell.run(Shell.tool("arch"), ["-x86_64", engine.wine.path] + arguments, environment: env,
                                   currentDirectory: space.url)
    }

    /// Stops every Windows program in the space.
    public static func killAll(engine: Engine, space: Space) async {
        let env = WineEnvironment.make(engine: engine, space: space, backend: .wined3d)
        _ = try? await Shell.run(Shell.tool("arch"), ["-x86_64", engine.wineserver.path, "-k"], environment: env)
    }

    /// Waits until every Windows program in the space has quit (installers that hand off to a child process).
    /// With a `timeout` it gives up after that many seconds and returns false; it also returns false when the
    /// calling task is cancelled. Only the waiting `wineserver -w` is stopped, never the programs or the server.
    @discardableResult
    public static func waitForAll(engine: Engine, space: Space, timeout: TimeInterval? = nil) async -> Bool {
        let env = WineEnvironment.make(engine: engine, space: space, backend: .wined3d)
        return await Supervised.exits(Shell.tool("arch"), ["-x86_64", engine.wineserver.path, "-w"],
                                      environment: env, timeout: timeout)
    }

    /// The command line Wine needs to open a file: `.msi` through msiexec, `.bat` through cmd, the rest directly.
    public static func arguments(toOpen file: URL, extra: [String] = []) -> [String] {
        switch file.pathExtension.lowercased() {
        case "msi": ["msiexec", "/i", file.path] + extra
        case "bat", "cmd": ["cmd", "/c", file.path] + extra
        default: [file.path] + extra
        }
    }
}
