import Foundation
import Testing
@testable import GPlayerCore

// The one-time code an Epic game is started with is written nowhere: not in the launch log, not in an error.

@Suite struct LaunchSecretsTests {
    @Test func theExchangeCodeAndTheAccountAreHidden() {
        let arguments = ["-nosplash", "-AUTH_LOGIN=unused", "-AUTH_PASSWORD=abc123", "-auth_password=lower", "-AUTH_TYPE=exchangecode",
                         "-epicusername=Sample Player", "-epicuserid=00ff", "-epicapp=SampleApp", "AUTH_PASSWORD=notaflag"]
        #expect(LaunchSecrets.masked(arguments) == ["-nosplash", "-AUTH_LOGIN=unused", "-AUTH_PASSWORD=<hidden>", "-auth_password=<hidden>",
                                                    "-AUTH_TYPE=exchangecode", "-epicusername=<hidden>", "-epicuserid=<hidden>",
                                                    "-epicapp=SampleApp", "AUTH_PASSWORD=notaflag"])
    }

    @Test func argumentsWithoutAnEqualsSignAreLeftAlone() {
        #expect(LaunchSecrets.masked(["-AUTH_PASSWORD", "-x=-AUTH_PASSWORD=1"]) == ["-AUTH_PASSWORD", "-x=-AUTH_PASSWORD=1"])
    }

    @Test func textIsScrubbedUpToTheNextOptionAQuoteOrTheEndOfTheLine() {
        #expect(LaunchSecrets.scrub("run -AUTH_PASSWORD=abc -epicapp=A and \"-AUTH_PASSWORD=zzz\"") == "run -AUTH_PASSWORD=<hidden> -epicapp=A and \"-AUTH_PASSWORD=<hidden>\"")
        #expect(LaunchSecrets.scrub("nothing here") == "nothing here")
        #expect(LaunchSecrets.scrub("x -AUTH_PASSWORD=abc\nnext line") == "x -AUTH_PASSWORD=<hidden>\nnext line")
    }

    @Test func aNameWithSpacesIsHiddenWholeNotUpToItsFirstSpace() {
        let text = "failed: x.exe -epicusername=Sample Player Two -epicuserid=00ff -epiclocale=en"
        let scrubbed = LaunchSecrets.scrub(text)
        #expect(scrubbed == "failed: x.exe -epicusername=<hidden> -epicuserid=<hidden> -epiclocale=en")
        #expect(!scrubbed.contains("Player") && !scrubbed.contains("Two"))
        #expect(LaunchSecrets.scrub("-epicusername=Sample Player") == "-epicusername=<hidden>")
    }

    @Test func theLaunchLogDoesNotHoldTheCode() {
        let arguments = ["/g/Sample.exe", "-nosplash", "-AUTH_PASSWORD=0123456789abcdef0123456789abcdef", "-epicusername=Sample Player"]
        let header = WineLauncher.logHeader(engine: fakeEngine(), space: space(at: URL(fileURLWithPath: "/tmp/p")), backend: .dxvk,
                                            arguments: arguments, environment: ["WINEDLLOVERRIDES": "a=n"])
        #expect(header.contains("command: /g/Sample.exe -nosplash -AUTH_PASSWORD=<hidden> -epicusername=<hidden>\n"))
        #expect(!header.contains("0123456789abcdef") && !header.contains("Sample Player"))
    }
}
