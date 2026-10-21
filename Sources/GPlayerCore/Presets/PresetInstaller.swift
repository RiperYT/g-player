import Foundation

/// Sets up a store launcher: its own space, the official installer, the helper wrapper, the first update.
public struct PresetInstaller: Sendable {
    public let paths: LibraryPaths
    public init(paths: LibraryPaths) { self.paths = paths }

    public typealias Progress = @Sendable (Double?, String) -> Void

    /// Installs `preset` into `space` (made beforehand with `SpaceManager.create`).
    public func install(_ preset: AppPreset, in space: Space, engine: Engine, progress: @escaping Progress) async throws {
        let installer = paths.downloads.appendingPathComponent(preset.installerFileName)
        progress(0, "Downloading \(preset.name)")
        try await FileDownloader.download(preset.installerURL, to: installer) { f in progress(f * 0.4, "Downloading \(preset.name)") }
        defer { try? FileManager.default.removeItem(at: installer) }

        progress(nil, "Installing \(preset.name)")
        let status = try await WineLauncher.runAndWait(
            engine: engine, space: space,
            arguments: WineLauncher.arguments(toOpen: installer, extra: preset.installerArguments),
            workingDirectory: paths.downloads, logsFolder: paths.logs, logName: "Install \(preset.name)")
        await WineLauncher.waitForAll(engine: engine, space: space)
        guard preset.isInstalled(in: space) else {
            let looked = preset.executables.map { "C:\\" + $0.replacingOccurrences(of: "/", with: "\\") }.joined(separator: ", ")
            throw ShellError.failed("The \(preset.name) installer finished (code \(status)), but \(preset.name) isn't in \(looked). The installer's log is in \(paths.logs.path).")
        }
        if preset.id == "steam" { try await finishSteamSetup(space: space, engine: engine, progress: progress) }
        progress(1, "\(preset.name) is ready")
    }

    /// The installer only leaves Steam's bootstrapper. Start it once so it downloads the real client,
    /// then stop it: from the next start on, the helper wrapper stays in place and the window draws.
    func finishSteamSetup(space: Space, engine: Engine, progress: @escaping Progress) async throws {
        guard !SteamLibrary.isClientReady(in: space) else { return }
        progress(nil, "Steam is downloading its client. This takes a few minutes.")
        let steam = AppPresets.steam
        let program = try WineLauncher.start(
            engine: engine, space: space,
            arguments: [steam.executableURL(in: space).path] + steam.launchArguments,
            workingDirectory: steam.executableURL(in: space).deletingLastPathComponent(),
            backend: .auto, tweaks: LaunchTweaks(dllOverrides: steam.dllOverrides, environment: steam.environment),
            logsFolder: paths.logs, logName: "Steam first start")
        let deadline = Date().addingTimeInterval(20 * 60)
        while !SteamLibrary.isClientReady(in: space), Date() < deadline {
            try await Task.sleep(for: .seconds(3))
            if !program.isRunning && !SteamLibrary.isClientReady(in: space) {
                throw ShellError.failed("Steam quit before it finished downloading. Open it from the library to continue.")
            }
        }
        try await Task.sleep(for: .seconds(8))      // let it finish writing the new files
        await WineLauncher.killAll(engine: engine, space: space)
        guard SteamLibrary.isClientReady(in: space) else {
            throw ShellError.failed("Steam didn't finish downloading in 20 minutes. Open it from the library to continue.")
        }
    }
}
