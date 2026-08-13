import XCTest
@testable import Jarvis

final class WakeWordDetectorTests: XCTestCase {
    func testMatchesConfiguredWakePhraseAndPreservesTrailingCommand() {
        let match = NativeSpeechWakeWordDetector.match(
            in: "Hey Jarvis, turn the bedroom lights off",
            configuredPhrase: "Hey Jarvis"
        )

        XCTAssertEqual(match?.phrase, "Hey Jarvis")
        XCTAssertEqual(match?.trailingCommand, "turn the bedroom lights off")
    }

    func testMatchesJarvisAlone() {
        let match = NativeSpeechWakeWordDetector.match(in: "Jarvis!", configuredPhrase: "Hey Jarvis")
        XCTAssertEqual(match, WakeWordMatch(phrase: "Jarvis", trailingCommand: nil))
    }

    func testDoesNotMatchInsideAnotherWord() {
        XCTAssertNil(NativeSpeechWakeWordDetector.match(in: "Jarvisian design", configuredPhrase: "Jarvis"))
    }
}
