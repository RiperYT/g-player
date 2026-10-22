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

    @Test func theQuestionSaysWhatRunsAndWhatQuittingCosts() {
        let resumes = SetupQuit.question(titles: ["Downloading G-Player Wine"], outcome: .resumes)
        #expect(resumes.title == "G-Player is still setting up (downloading G-Player Wine).")
        #expect(resumes.detail == "Quit anyway? Setup continues the next time G-Player opens.")
        // Nothing but the first run's list is picked up at the next start: the rest says what stops.
        let stops = SetupQuit.question(titles: ["Installing Windows components for “Main”"], outcome: .stops)
        #expect(stops.detail == "Quit anyway? The setup stops now, and you can start it again later.")
        #expect(!stops.detail.contains("continues"))
        // During the welcome steps the download goes on once the steps are gone through again.
        let welcome = SetupQuit.question(titles: ["Downloading Wine Staging"], outcome: .continuesInWelcome)
        #expect(welcome.detail.contains("What came is kept") && welcome.detail.contains("welcome steps") && !welcome.detail.contains("next time G-Player opens"))
    }

    @Test func onlyAPendingFirstRunListMeansSetupGoesOnByItself() {
        #expect(SetupQuit.outcome(onboardingDone: true, pendingFirstRunSpaces: true) == .resumes)
        // Done onboarding and nothing on the list (a store app from Get Apps, components, a new space): nothing resumes.
        #expect(SetupQuit.outcome(onboardingDone: true, pendingFirstRunSpaces: false) == .stops)
        #expect(SetupQuit.outcome(onboardingDone: false, pendingFirstRunSpaces: false) == .continuesInWelcome)
        #expect(SetupQuit.outcome(onboardingDone: false, pendingFirstRunSpaces: true) == .continuesInWelcome)
    }

    @Test func aQuitFromTheSystemGoingDownIsNeverAsked() {
        func code(_ text: String) -> UInt32 { SetupQuit.fourCharCode(text) }
        // The codes of the Apple event's quit reason: shut down, restart, log out.
        for reason in ["shut", "rest", "rlgo", "logo"] { #expect(SetupQuit.isSystemQuit(reason: code(reason))) }
        // The user's own Quit (kAEQuitAll), another reason, or none at all.
        #expect(!SetupQuit.isSystemQuit(reason: code("quia")))
        #expect(!SetupQuit.isSystemQuit(reason: code("what")))
        #expect(!SetupQuit.isSystemQuit(reason: nil))
        #expect(code("shut") == 0x73687574)
    }
}
