import Testing
@testable import GPlayerCore

@Suite struct AppPresetTests {
    @Test func getAppsOffersSteamAndEpicOnly() {
        #expect(AppPresets.all.map(\.id) == ["steam", "epic"])
    }

    @Test func aSpaceSetUpForARetiredLauncherKeepsItsSettings() {
        #expect(AppPresets.preset("gog")?.chromiumHelpers == AppPresets.gog.chromiumHelpers)
        #expect(AppPresets.preset("ubisoft")?.name == "Ubisoft Connect")
        #expect(AppPresets.preset("nope") == nil)
    }
}
