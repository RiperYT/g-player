import Foundation

/// When G-Player updates itself (Sparkle). The app only wires Sparkle in (`AppUpdater`); what decides is here.
public enum SelfUpdate {
    /// The Info.plist key that holds the public half of the key the releases are signed with.
    public static let publicKeyInfoKey = "SUPublicEDKey"

    /// A build updates itself only when its Info.plist carries that public key: without it Sparkle can't tell a genuine
    /// update from any other file. So a development build, and one made before the key was put in, never look for updates.
    public static func isEnabled(publicKey: String?) -> Bool {
        guard let publicKey else { return false }
        return !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
