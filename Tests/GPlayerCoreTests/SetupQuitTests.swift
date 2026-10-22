import Foundation
import Testing
@testable import GPlayerCore

/// Quitting in the middle of setup asks first, and says it in the words of the sidebar.
@Suite struct SetupQuitTests {
    @Test func theSidebarsTitlesReadAsAPhrase() {
        #expect(SetupQuit.summary(of: ["Downloading G-Player Wine"]) == "downloading G-Player Wine")
        #expect(SetupQuit.summary(of: ["Creating “Main”", "Setting up Steam"]) == "creating “Main” and setting up Steam")
        #expect(SetupQuit.summary(of: ["A one", "B two", "C three", "D four"]) == "a one, b two and 2 more")
        // The same title twice is said once.
        #expect(SetupQuit.summary(of: ["Setting up Steam", "Setting up Steam"]) == "setting up Steam")
        #expect(SetupQuit.summary(of: []) == "setting up")
    }

    @Test func theQuestionSaysWhatRunsAndWhetherSetupGoesOnByItself() {
        let resumes = SetupQuit.question(titles: ["Downloading G-Player Wine"], resumes: true)
        #expect(resumes.title == "G-Player is still setting up (downloading G-Player Wine).")
        #expect(resumes.detail == "Quit anyway? Setup continues the next time G-Player opens.")
        // Only the first run is started again by itself; the rest has to be asked for.
        let by_hand = SetupQuit.question(titles: ["Installing Windows components for “Main”"], resumes: false)
        #expect(by_hand.detail.hasPrefix("Quit anyway?") && !by_hand.detail.contains("continues"))
    }
}
