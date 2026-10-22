import Foundation
import Testing
@testable import GPlayerCore

@Suite struct LaunchArgumentsTests {
    let here = URL(fileURLWithPath: "/work")

    private func folder(_ arguments: [String], _ environment: [String: String] = [:]) -> String? {
        LaunchArguments.snapshotFolder(arguments: ["GPlayer"] + arguments, environment: environment, currentDirectory: here)?.path
    }

    @Test func aNormalStartAsksForNoSnapshots() {
        #expect(folder([]) == nil)
        #expect(folder(["-selectGame", "x"]) == nil)
        #expect(folder([], ["GPLAYER_RENDER_ONBOARDING": ""]) == nil)
    }

    @Test func theFolderComesAfterTheFlagOrAfterAnEqualsSign() {
        #expect(folder(["--render-onboarding", "/tmp/shots"]) == "/tmp/shots")
        #expect(folder(["--render-onboarding=/tmp/shots"]) == "/tmp/shots")
        #expect(folder(["--render-onboarding"]) == nil)                      // no folder: start normally
    }

    @Test func aRelativeFolderIsTakenFromTheCurrentFolder() {
        #expect(folder(["--render-onboarding", "build/snapshots"]) == "/work/build/snapshots")
        #expect(folder(["--render-onboarding", "../shots"]) == "/shots")
        #expect(folder(["--render-onboarding", "~/shots"]) == NSHomeDirectory() + "/shots")
    }

    @Test func theEnvironmentVariableDoesTheSameAndTheArgumentWins() {
        #expect(folder([], ["GPLAYER_RENDER_ONBOARDING": "/tmp/env"]) == "/tmp/env")
        #expect(folder(["--render-onboarding", "/tmp/arg"], ["GPLAYER_RENDER_ONBOARDING": "/tmp/env"]) == "/tmp/arg")
    }
}
