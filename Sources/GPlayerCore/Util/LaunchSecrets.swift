import Foundation

/// Launch arguments that are secrets or name the person, hidden wherever a command line is written down. An Epic game started
/// with Legendary's parameters carries a one-time exchange code (`-AUTH_PASSWORD=…`) that logs in as the user for a few
/// minutes, and their account name and id. The real arguments go to the program; this is for logs, errors and anything shown.
public enum LaunchSecrets {
    public static let hidden = "<hidden>"

    /// Lowercased names of the arguments whose value is hidden.
    static let names: Set<String> = ["-auth_password", "-epicusername", "-epicuserid"]

    /// `-AUTH_PASSWORD=abc` as `-AUTH_PASSWORD=<hidden>`; any other argument unchanged.
    public static func masked(_ argument: String) -> String {
        guard let equals = argument.firstIndex(of: "="), names.contains(argument[..<equals].lowercased()) else { return argument }
        return argument[...equals] + hidden
    }

    public static func masked(_ arguments: [String]) -> [String] { arguments.map(masked) }

    /// Free text (a program's output, an error) with the value of every such argument hidden, up to the next space or quote.
    public static func scrub(_ text: String) -> String {
        var result = text
        for name in names {
            let pattern = "(?i)(" + NSRegularExpression.escapedPattern(for: name) + #"=)[^\s"']+"#
            result = result.replacingOccurrences(of: pattern, with: "$1" + hidden, options: .regularExpression)
        }
        return result
    }
}
