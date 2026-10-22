import CoreGraphics
import Foundation

/// A Unity game that once failed to start can save a screen size of 0×0 in its settings, and then crashes on every
/// start ("Failed to create RenderTexture (0 x 0 …)"). G-Player passes a size on the command line instead, which
/// Unity uses and saves. Nothing in the space is changed.
public enum UnityScreen {
    /// `-screen-width W -screen-height H` for a Unity game whose saved size is 0×0, else nothing.
    /// - Parameters:
    ///   - program: the game's .exe (its `<Name>_Data/app.info` names the settings' registry key).
    ///   - windowed: what the command line asks for (`-screen-fullscreen`), or nil to go by the saved setting. A window
    ///     gets 80% of the screen, so it fits beside the menu bar and the Dock.
    ///   - retina: Wine's Retina mode is on, so the game sees the screen in pixels rather than points.
    ///   - screen: the full-screen size to start from; the main display's when nil.
    public static func repairArguments(program: URL, space: Space, windowed: Bool?, retina: Bool,
                                       screen: CGSize? = nil) -> [String] {
        // Wine writes the registry to user.reg every 30 seconds and when the space's last program quits, so a value
        // saved moments ago by a game that is still running may not be there yet.
        guard let (company, product) = appInfo(forProgram: program),
              let userReg = try? String(contentsOf: space.url.appendingPathComponent("user.reg"), encoding: .utf8)
        else { return [] }
        let saved = savedSettings(userReg: userReg, company: company, product: product)
        guard saved["Screenmanager Resolution Width"] == zero, saved["Screenmanager Resolution Height"] == zero else { return [] }
        let full = screen ?? mainDisplaySize(retina: retina)
        let inWindow = windowed ?? (saved["Screenmanager Is Fullscreen mode"] == zero
                                    || saved["Screenmanager Fullscreen mode"] == "dword:00000003")
        // Full screen is the display's own size; a window is rounded to even numbers.
        let width = inWindow ? Int(full.width * 0.8) / 2 * 2 : Int(full.width)
        let height = inWindow ? Int(full.height * 0.8) / 2 * 2 : Int(full.height)
        guard width >= 2, height >= 2 else { return [] }
        return ["-screen-width", String(width), "-screen-height", String(height)]
    }

    static let zero = "dword:00000000"

    /// The main display's size as Wine shows it to games: points, or pixels in Retina mode.
    static func mainDisplaySize(retina: Bool) -> CGSize {
        let display = CGMainDisplayID()
        if retina, let mode = CGDisplayCopyDisplayMode(display) { return CGSize(width: mode.pixelWidth, height: mode.pixelHeight) }
        return CGDisplayBounds(display).size
    }

    /// The company and product from `<Name>_Data/app.info`, which Unity writes as two lines.
    static func appInfo(forProgram program: URL) -> (company: String, product: String)? {
        let name = program.deletingPathExtension().lastPathComponent
        let file = program.deletingLastPathComponent().appendingPathComponent("\(name)_Data/app.info")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
        return (lines[0], lines[1])
    }

    /// The values of `HKCU\Software\<company>\<product>` in Wine's `user.reg`, by name without the hash Unity adds
    /// (`Screenmanager Resolution Width_h182942802` → `Screenmanager Resolution Width`), as Wine writes them
    /// (`dword:00000000`).
    static func savedSettings(userReg: String, company: String, product: String) -> [String: String] {
        guard let company = escapedKeyPart(company), let product = escapedKeyPart(product) else { return [:] }
        let header = "[software\\\\\(company.lowercased())\\\\\(product.lowercased())]"
        var inKey = false
        var values: [String: String] = [:]
        for line in userReg.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                if inKey { break }
                inKey = line.lowercased().hasPrefix(header)
                continue
            }
            guard inKey, line.hasPrefix("\""), let eq = line.range(of: "\"=") else { continue }
            var name = line[line.index(after: line.startIndex)..<eq.lowerBound]
            if let hash = name.range(of: "_h", options: .backwards), !name[hash.upperBound...].isEmpty,
               name[hash.upperBound...].allSatisfy(\.isNumber) {
                name = name[..<hash.lowerBound]
            }
            values[String(name)] = String(line[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// A key name part as Wine writes it in .reg files (`dump_strW` with `[]`): `\`, `[` and `]` get a backslash,
    /// and UTF-16 units above 127 become `\x` and hex (four digits when a hex digit follows). Nil for control
    /// characters, which game names don't have.
    static func escapedKeyPart(_ s: String) -> String? {
        let units = Array(s.utf16)
        var out = ""
        for (i, u) in units.enumerated() {
            if u < 32 { return nil }
            if u > 127 {
                let nextIsHex = i + 1 < units.count && units[i + 1] < 128
                    && Character(Unicode.Scalar(UInt8(units[i + 1]))).isHexDigit
                out += nextIsHex ? String(format: "\\x%04x", u) : String(format: "\\x%x", u)
                continue
            }
            let c = Character(Unicode.Scalar(UInt8(u)))
            if c == "\\" || c == "[" || c == "]" { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
