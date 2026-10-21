import Foundation

/// Valve's KeyValues text format (`libraryfolders.vdf`, `appmanifest_*.acf`).
public indirect enum VDF: Sendable, Equatable {
    case string(String)
    case object([(String, VDF)])

    public static func == (a: VDF, b: VDF) -> Bool {
        switch (a, b) {
        case let (.string(x), .string(y)): x == y
        case let (.object(x), .object(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    /// Case-insensitive lookup, like Steam itself.
    public subscript(key: String) -> VDF? {
        guard case .object(let entries) = self else { return nil }
        return entries.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var entries: [(String, VDF)] { if case .object(let e) = self { e } else { [] } }

    public enum ParseError: Error { case unexpectedEnd, unexpectedToken(String) }

    public static func parse(_ text: String) throws -> VDF {
        var tokens = Tokens(Array(text.unicodeScalars))
        var entries: [(String, VDF)] = []
        while let key = try tokens.next() {
            guard case .text(let k) = key else { throw ParseError.unexpectedToken("}") }
            entries.append((k, try value(&tokens)))
        }
        return .object(entries)
    }

    private static func value(_ tokens: inout Tokens) throws -> VDF {
        guard let t = try tokens.next() else { throw ParseError.unexpectedEnd }
        switch t {
        case .text(let s): return .string(s)
        case .close: throw ParseError.unexpectedToken("}")
        case .open:
            var entries: [(String, VDF)] = []
            while true {
                guard let next = try tokens.next() else { throw ParseError.unexpectedEnd }
                switch next {
                case .close: return .object(entries)
                case .open: throw ParseError.unexpectedToken("{")
                case .text(let k): entries.append((k, try value(&tokens)))
                }
            }
        }
    }

    private enum Token { case text(String), open, close }

    private struct Tokens {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func next() throws -> Token? {
            while i < s.count {
                let c = s[i]
                if c.properties.isWhitespace { i += 1; continue }
                if c == "/", i + 1 < s.count, s[i + 1] == "/" {           // comment to end of line
                    while i < s.count, s[i] != "\n" { i += 1 }
                    continue
                }
                if c == "{" { i += 1; return .open }
                if c == "}" { i += 1; return .close }
                if c == "\"" {
                    i += 1
                    var out = String.UnicodeScalarView()
                    while i < s.count, s[i] != "\"" {
                        if s[i] == "\\", i + 1 < s.count {
                            i += 1
                            switch s[i] { case "n": out.append("\n"); case "t": out.append("\t"); default: out.append(s[i]) }
                        } else { out.append(s[i]) }
                        i += 1
                    }
                    guard i < s.count else { throw ParseError.unexpectedEnd }
                    i += 1
                    return .text(String(out))
                }
                var out = String.UnicodeScalarView()                      // unquoted token
                while i < s.count, !s[i].properties.isWhitespace, s[i] != "{", s[i] != "}", s[i] != "\"" {
                    out.append(s[i]); i += 1
                }
                return .text(String(out))
            }
            return nil
        }
    }
}
