import AppKit
import Foundation

final class SpeechSynthesisService: NSObject, NSSpeechSynthesizerDelegate {
    private let synthesizer = NSSpeechSynthesizer()
    private var completion: ((Bool) -> Void)?
    private var failsafeWorkItem: DispatchWorkItem?
    private var activationSound: NSSound?
    private var activationSoundReleaseWorkItem: DispatchWorkItem?

    var isSpeaking: Bool { synthesizer.isSpeaking }

    var availableVoices: [(identifier: String, displayName: String)] {
        NSSpeechSynthesizer.availableVoices.map { voice in
            let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
            let name = attributes[.name] as? String ?? voice.rawValue
            return (voice.rawValue, name)
        }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        _ text: String,
        voiceIdentifier: String?,
        rate: Float,
        completion: @escaping (Bool) -> Void
    ) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(true)
            return
        }

        if let identifier = voiceIdentifier, !identifier.isEmpty {
            _ = synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: identifier))
        }
        synthesizer.rate = rate
        self.completion = completion

        guard synthesizer.startSpeaking(text) else {
            self.completion = nil
            completion(false)
            return
        }

        let estimatedSeconds = Self.timeoutInterval(for: text, rate: rate)
        let failsafe = DispatchWorkItem { [weak self] in self?.handleTimeout() }
        failsafeWorkItem = failsafe
        DispatchQueue.main.asyncAfter(deadline: .now() + estimatedSeconds, execute: failsafe)
    }

    func stop() {
        failsafeWorkItem?.cancel()
        failsafeWorkItem = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking() }
        completion = nil
        activationSoundReleaseWorkItem?.cancel()
        activationSoundReleaseWorkItem = nil
        activationSound?.stop()
        activationSound = nil
    }

    /// Plays the system activation cue and returns its duration so callers can
    /// delay microphone capture until the speaker tail has cleared.
    @discardableResult
    func playActivationSound() -> TimeInterval {
        activationSoundReleaseWorkItem?.cancel()
        activationSound?.stop()

        guard let sound = NSSound(named: NSSound.Name("Tink")) else {
            activationSound = nil
            return 0
        }

        activationSound = sound
        let duration = max(0, sound.duration)
        _ = sound.play()

        let release = DispatchWorkItem { [weak self] in
            guard let self = self, self.activationSound === sound else { return }
            self.activationSound = nil
            self.activationSoundReleaseWorkItem = nil
        }
        activationSoundReleaseWorkItem = release
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1, execute: release)
        return duration
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        finish(finishedSpeaking)
    }

    private func finish(_ succeeded: Bool) {
        guard let callback = completion else { return }
        completion = nil
        failsafeWorkItem?.cancel()
        failsafeWorkItem = nil
        callback(succeeded)
    }

    private func handleTimeout() {
        guard completion != nil else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }
        // stopSpeaking() may synchronously deliver the delegate callback.
        finish(false)
    }

    static func timeoutInterval(for text: String, rate: Float) -> TimeInterval {
        let words = max(1, text.split(whereSeparator: { $0.isWhitespace }).count)
        let wordsPerMinute = min(400, max(60, Double(rate)))
        let nominalDuration = (Double(words) / wordsPerMinute) * 60
        return min(180, max(12, (nominalDuration * 1.75) + 6))
    }
}
