import AVFoundation
import XCTest
@testable import Jarvis

final class VoiceActivityDetectorTests: XCTestCase {
    func testSpeechStartsAndEndsAfterConfiguredSilence() throws {
        let detector = VoiceActivityDetector(configuration: .init(
            startMarginDB: 10,
            endMarginDB: 6,
            minimumSpeechDuration: 0.1,
            endSilenceDuration: 0.2,
            initialNoiseFloorDB: -60
        ))

        let speech = try makeBuffer(amplitude: 0.12)
        let silence = try makeBuffer(amplitude: 0)

        XCTAssertEqual(detector.process(speech), .speechStarted)
        XCTAssertNil(detector.process(silence))
        XCTAssertEqual(detector.process(silence), .speechEnded)
    }

    private func makeBuffer(amplitude: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 100
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<100 { samples[index] = amplitude }
        return buffer
    }
}
