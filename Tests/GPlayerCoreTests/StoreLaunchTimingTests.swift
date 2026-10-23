import Foundation
import Testing
@testable import GPlayerCore

@Suite struct StoreLaunchTimingTests {
    /// A Steam that starts cold took over a minute before it started the game; that was called "didn't open".
    @Test func aLaunchThatStartsTheLauncherGetsLongerToShowUp() {
        #expect(GraphicsRetry.secondsToShowUp(launcherWasRunning: true) == 60)
        #expect(GraphicsRetry.secondsToShowUp(launcherWasRunning: false) >= 180)
    }
}
