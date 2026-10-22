import Foundation

/// What G-Player says when it is asked to quit in the middle of setting something up (engine downloads, making a
/// space, installing Windows components or a store app).
public enum SetupQuit {
    /// "downloading G-Player Wine", "creating “Main” and setting up Steam", "a, b and 2 more": the sidebar's titles read as a
    /// phrase. A title that comes twice counts once.
    public static func summary(of titles: [String]) -> String {
        var seen = Set<String>()
        let phrases = titles.filter { seen.insert($0).inserted }.map { title in
            title.prefix(1).lowercased() + title.dropFirst()
        }
        switch phrases.count {
        case 0: return "setting up"
        case 1: return phrases[0]
        case 2: return "\(phrases[0]) and \(phrases[1])"
        default: return "\(phrases[0]), \(phrases[1]) and \(phrases.count - 2) more"
        }
    }

    /// The question for the Quit dialog: what is still running, and what quitting costs.
    /// - Parameter resumes: setup goes on by itself at the next start (the first run's engines and spaces do); otherwise
    ///   it has to be started again by hand.
    public static func question(titles: [String], resumes: Bool) -> (title: String, detail: String) {
        ("G-Player is still setting up (\(summary(of: titles))).",
         resumes ? "Quit anyway? Setup continues the next time G-Player opens."
                 : "Quit anyway? The setup stops now, and you can start it again later.")
    }
}
