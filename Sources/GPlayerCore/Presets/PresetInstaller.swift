import Foundation

/// Sets up a store launcher: its own space, the official installer, the helper wrapper, the first update.
public struct PresetInstaller: Sendable {
    public let paths: LibraryPaths
    public init(paths: LibraryPaths) { self.paths = paths }

    public typealias Progress = @Sendable (Double?, String) -> Void

    /// A store installer that runs longer than this is stopped, so a hung one can't block the space.
    public static let installerTimeout: TimeInterval = 30 * 60

    /// Installs `preset` into `space` (made beforehand with `SpaceManager.create`). `dotNetAvailable`: Wine Mono is in place, so the
    /// installer runs with `mscoree` on (`WineMono`).
    public func install(_ preset: AppPreset, in space: Space, engine: Engine, dotNetAvailable: Bool = false,
                        progress: @escaping Progress) async throws {
        let installer = paths.downloads.appendingPathComponent(preset.installerFileName)
        progress(0, String(localized: "Downloading \(preset.name)"))
        try await FileDownloader.download(preset.installerURL, to: installer) { f in progress(f * 0.4, String(localized: "Downloading \(preset.name)")) }
        defer { try? FileManager.default.removeItem(at: installer) }

        progress(nil, String(localized: "Installing \(preset.name)"))
        let status = try await WineLauncher.runAndWait(
            engine: engine, space: space,
            arguments: WineLauncher.arguments(toOpen: installer, extra: preset.installerArguments),
            workingDirectory: paths.downloads, tweaks: LaunchTweaks(dotNetAvailable: dotNetAvailable),
            logsFolder: paths.logs, logName: "Install \(preset.name)", timeout: Self.installerTimeout)
        try Task.checkCancellation()
        await WineLauncher.waitForAll(engine: engine, space: space, timeout: 120)
        try Task.checkCancellation()
        guard preset.isInstalled(in: space) else {
            let looked = preset.executables.map { "C:\\" + $0.replacingOccurrences(of: "/", with: "\\") }.joined(separator: ", ")
            throw ShellError.failed(String(localized: "The \(preset.name) installer finished (code \(status)), but \(preset.name) isn't in \(looked). The installer's log is in \(paths.logs.path)."))
        }
        if preset.id == "steam" { try await finishSteamSetup(space: space, engine: engine, progress: progress) }
        progress(1, String(localized: "\(preset.name) is ready"))
    }

    /// The installer only leaves Steam's bootstrapper. Start it once so it downloads the real client,
    /// then stop it: from the next start on, the helper wrapper stays in place and the window draws.
    func finishSteamSetup(space: Space, engine: Engine, progress: @escaping Progress) async throws {
        guard !SteamLibrary.isClientReady(in: space) else { return }
        progress(nil, String(localized: "Steam is downloading its client. This takes a few minutes."))
        let steam = AppPresets.steam
        let program = try WineLauncher.start(
            engine: engine, space: space,
            arguments: [steam.executableURL(in: space).path] + steam.launchArguments,
            workingDirectory: steam.executableURL(in: space).deletingLastPathComponent(),
            backend: .auto, tweaks: LaunchTweaks(dllOverrides: steam.dllOverrides, environment: steam.environment),
            logsFolder: paths.logs, logName: "Steam first start")
        let deadline = Date().addingTimeInterval(20 * 60)
        do {
            while !SteamLibrary.isClientReady(in: space), Date() < deadline {
                try await Task.sleep(for: .seconds(3))
                if !program.isRunning && !SteamLibrary.isClientReady(in: space) {
                    throw ShellError.failed(String(localized: "Steam quit before it finished downloading. Open it from the library to continue."))
                }
            }
            try await Task.sleep(for: .seconds(8))      // let it finish writing the new files
        } catch is CancellationError {
            // Stopped from the sidebar: Steam and its helpers go too, so the new space isn't left busy.
            await WineLauncher.killAll(engine: engine, space: space)
            throw CancellationError()
        }
        await WineLauncher.killAll(engine: engine, space: space)
        guard SteamLibrary.isClientReady(in: space) else {
            throw ShellError.failed(String(localized: "Steam didn't finish downloading in 20 minutes. Open it from the library to continue."))
        }
    }
}
