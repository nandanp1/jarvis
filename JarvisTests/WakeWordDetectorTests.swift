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

    func testPhraseOnlyPartialWaitsForTail() {
        let resolver = WakeWordTailResolver()
        let decision = resolver.consume(
            transcript: "Hey Jarvis",
            configuredPhrase: "Hey Jarvis",
            isFinal: false
        )

        XCTAssertEqual(
            decision,
            .waitForTail(WakeWordMatch(phrase: "Hey Jarvis", trailingCommand: nil))
        )
        XCTAssertTrue(resolver.isWaiting)
    }

    func testTrailingCommandEmitsImmediatelyDuringGrace() {
        let resolver = WakeWordTailResolver()
        _ = resolver.consume(
            transcript: "Hey Jarvis",
            configuredPhrase: "Hey Jarvis",
            isFinal: false
        )

        let decision = resolver.consume(
            transcript: "Hey Jarvis turn the desk light off",
            configuredPhrase: "Hey Jarvis",
            isFinal: false
        )

        XCTAssertEqual(
            decision,
            .emit(WakeWordMatch(phrase: "Hey Jarvis", trailingCommand: "turn the desk light off"))
        )
        XCTAssertFalse(resolver.isWaiting)
    }

    func testCorrectedPartialCancelsPendingWake() {
        let resolver = WakeWordTailResolver()
        _ = resolver.consume(transcript: "Jarvis", configuredPhrase: "Hey Jarvis", isFinal: false)

        XCTAssertEqual(
            resolver.consume(transcript: "jar versus", configuredPhrase: "Hey Jarvis", isFinal: false),
            .cancelPending
        )
        XCTAssertNil(resolver.expire())
    }

    func testPhraseOnlyWakeEmitsWhenGraceExpires() {
        let resolver = WakeWordTailResolver()
        _ = resolver.consume(transcript: "Hey Jarvis", configuredPhrase: "Hey Jarvis", isFinal: false)

        XCTAssertEqual(
            resolver.expire(),
            WakeWordMatch(phrase: "Hey Jarvis", trailingCommand: nil)
        )
        XCTAssertFalse(resolver.isWaiting)
    }
}

final class AudioServiceReliabilityTests: XCTestCase {
    func testSpeechRecognitionStopCompletionRunsOnMainThread() {
        let service = SpeechRecognitionService(microphone: MicrophoneService())
        let completion = expectation(description: "stop completion")

        service.stop {
            XCTAssertTrue(Thread.isMainThread)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
    }

    func testSpeechTimeoutAllowsMoreTimeForSlowerVoices() {
        let text = Array(repeating: "Jarvis", count: 80).joined(separator: " ")

        let slow = SpeechSynthesisService.timeoutInterval(for: text, rate: 90)
        let fast = SpeechSynthesisService.timeoutInterval(for: text, rate: 300)

        XCTAssertGreaterThan(slow, fast)
        XCTAssertGreaterThanOrEqual(fast, 12)
        XCTAssertLessThanOrEqual(slow, 180)
    }
}
