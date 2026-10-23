import Foundation
import Testing
@testable import GPlayerCore

/// G-Player updates itself only in a build that has the key its releases are signed with, and the app's Info.plist asks
/// Sparkle for nothing more than that.
@Suite struct SelfUpdateTests {
    /// The shape of an EdDSA public key (32 bytes in base64), not a real one.
    let key = String(repeating: "A", count: 43) + "="

    @Test func aBuildWithoutTheKeyNeverLooksForUpdates() {
        #expect(!SelfUpdate.isEnabled(publicKey: nil))
        #expect(!SelfUpdate.isEnabled(publicKey: ""))
        #expect(!SelfUpdate.isEnabled(publicKey: "  \n"))
    }

    @Test func aBuildWithTheKeyDoes() {
        #expect(SelfUpdate.isEnabled(publicKey: key))
        #expect(SelfUpdate.isEnabled(publicKey: key + "\n"))
        #expect(SelfUpdate.publicKeyInfoKey == "SUPublicEDKey")
    }

    // MARK: What the build puts in the app

    /// …/Tests/GPlayerCoreTests/SelfUpdateTests.swift → the repository root.
    var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("scripts/Info.plist"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func theAppAsksGitHubsLatestReleaseForItsAppcastAndSendsNoProfile() throws {
        let plist = try infoPlist()
        #expect(plist["SUFeedURL"] as? String == "https://github.com/RiperYT/g-player/releases/latest/download/appcast.xml")
        #expect(plist["SUEnableSystemProfiling"] as? Bool == false)
    }

    @Test func theAppLeavesTheChoiceOfCheckingAutomaticallyToSparklesQuestionAndUsesNoSandboxServices() throws {
        let plist = try infoPlist()
        // Not set: Sparkle asks the user itself, the second time the app opens. G-Player isn't sandboxed, so its XPC services stay off.
        for key in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUEnableInstallerLauncherService", "SUEnableDownloaderService"] {
            #expect(plist[key] == nil, "\(key)")
        }
        // The public key comes from scripts/sparkle-public-key.txt when build-app.sh makes the app.
        #expect(plist[SelfUpdate.publicKeyInfoKey] == nil)
    }

    @Test func theKeyFileIsEmptyOrOneLineWithAnEdDSAPublicKey() throws {
        let text = try String(contentsOf: root.appendingPathComponent("scripts/sparkle-public-key.txt"), encoding: .utf8)
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }                      // no key yet: the builds don't update themselves
        #expect(!key.contains("\n"))
        #expect(Data(base64Encoded: key)?.count == 32)
    }
}
