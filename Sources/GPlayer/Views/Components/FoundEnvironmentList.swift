import GPlayerCore
import SwiftUI

/// Windows environments already on this Mac, each with a checkbox, and what to know before bringing bottles over.
/// Onboarding and "Add Existing Space" show the same list.
struct FoundEnvironmentList: View {
    let found: [FoundEnvironment]
    @Binding var chosen: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let warning = FirstRunSetup.bottleWarning(for: found) { PathWarning(text: warning) }
            VStack(spacing: 0) {
                ForEach(found) { f in
                    Toggle(isOn: Binding(get: { chosen.contains(f.id) },
                                         set: { if $0 { chosen.insert(f.id) } else { chosen.remove(f.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(f.name).font(.body.weight(.medium))
                                Text(f.originNote).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(Self.describe(f)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(f.pathProblem != nil)
                    if let problem = f.pathProblem { PathWarning(text: problem, font: .caption).padding(.bottom, 8) }
                    if f.id != found.last?.id { Divider() }
                }
            }
        }
    }

    /// "Steam, Sample Game · runs on G-Player Wine".
    static func describe(_ f: FoundEnvironment) -> String {
        var parts: [String] = []
        if f.presetID == "steam" { parts.append("Steam") }
        parts += f.games.map(\.title)
        let engine = EngineCatalog.info(f.suggestedEngineID)?.name ?? f.suggestedEngineID
        let runs = String(localized: "runs on \(engine)", comment: "Ends a line like “Steam, Game · runs on G-Player Wine”")
        return parts.isEmpty ? runs : "\(parts.joined(separator: ", ")) · \(runs)"
    }
}
