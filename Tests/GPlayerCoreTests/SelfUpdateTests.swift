import Foundation
import Testing
@testable import GPlayerCore

/// G-Player updates itself only in a build that has the key its releases are signed with.
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
}
