import AVFoundation
import Foundation

final class VoiceActivityDetector {
    enum Event: Equatable {
        case speechStarted
        case speechEnded
    }

    struct Configuration {
        var startMarginDB: Float = 11
        var endMarginDB: Float = 7
        var minimumSpeechDuration: TimeInterval = 0.18
        var endSilenceDuration: TimeInterval = 1.25
        var initialNoiseFloorDB: Float = -58
    }

    private let configuration: Configuration
    private var noiseFloorDB: Float
    private var speechDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0
    private(set) var hasDetectedSpeech = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        noiseFloorDB = configuration.initialNoiseFloorDB
    }

    func reset() {
        noiseFloorDB = configuration.initialNoiseFloorDB
        speechDuration = 0
        silenceDuration = 0
        hasDetectedSpeech = false
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Event? {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0,
              buffer.format.sampleRate > 0 else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        let count = max(1, channelCount * frameCount)
        let rms = sqrt(sum / Float(count))
        let db = max(-96, 20 * log10(max(rms, 0.000_001)))
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate

        if !hasDetectedSpeech {
            noiseFloorDB = (noiseFloorDB * 0.96) + (min(db, noiseFloorDB + 3) * 0.04)
            let startThreshold = min(-30, max(-52, noiseFloorDB + configuration.startMarginDB))
            if db >= startThreshold {
                speechDuration += duration
                if speechDuration >= configuration.minimumSpeechDuration {
                    hasDetectedSpeech = true
                    silenceDuration = 0
                    return .speechStarted
                }
            } else {
                speechDuration = max(0, speechDuration - duration)
            }
            return nil
        }

        let endThreshold = min(-34, max(-58, noiseFloorDB + configuration.endMarginDB))
        if db < endThreshold {
            silenceDuration += duration
            if silenceDuration >= configuration.endSilenceDuration {
                silenceDuration = 0
                return .speechEnded
            }
        } else {
            silenceDuration = 0
        }
        return nil
    }
}
