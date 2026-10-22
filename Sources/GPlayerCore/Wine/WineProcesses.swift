import Foundation

/// Which Windows programs run in a space, read from the Mac's process list. Installers and settings changes wait for
/// every program in a space to quit, so G-Player doesn't start them while a game or Steam is open.
public enum WineProcesses {
    /// The command line of every process on the Mac, one per line (`ps -axo command=`). It takes a moment, so the
    /// caller runs it off the main thread.
    public static func commandLines() -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// True when a program of the space runs: some command line holds the path of its `drive_c`, or sets
    /// `WINEPREFIX=<space path> ` (with the space after it, so `Main` doesn't match `Main 2`).
    public static func isRunning(in space: Space, commandLines: String) -> Bool {
        !lines(of: space, in: commandLines).isEmpty
    }

    /// True when Steam runs in the space: one of its programs (`steam.exe`, `steamwebhelper.exe`, `steamservice.exe`)
    /// is among the space's processes.
    public static func isSteamRunning(in space: Space, commandLines: String) -> Bool {
        lines(of: space, in: commandLines).contains { line in
            let lower = line.lowercased()
            return lower.contains("steam.exe") || lower.contains("steamwebhelper") || lower.contains("steamservice.exe")
        }
    }

    /// The command lines that belong to the space.
    private static func lines(of space: Space, in commandLines: String) -> [Substring] {
        let driveC = space.driveC.path
        let prefix = "WINEPREFIX=\(space.path) "
        return commandLines.split(separator: "\n").filter { $0.contains(driveC) || $0.contains(prefix) }
    }
}
