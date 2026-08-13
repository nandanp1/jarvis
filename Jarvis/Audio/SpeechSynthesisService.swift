import AppKit
import Foundation

final class SpeechSynthesisService: NSObject, NSSpeechSynthesizerDelegate {
    private let synthesizer = NSSpeechSynthesizer()
    private var completion: ((Bool) -> Void)?
    private var failsafeWorkItem: DispatchWorkItem?

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

        let estimatedSeconds = min(90, max(8, Double(text.count) / 10))
        let failsafe = DispatchWorkItem { [weak self] in self?.finish(false) }
        failsafeWorkItem = failsafe
        DispatchQueue.main.asyncAfter(deadline: .now() + estimatedSeconds, execute: failsafe)
    }

    func stop() {
        failsafeWorkItem?.cancel()
        failsafeWorkItem = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking() }
        completion = nil
    }

    func playActivationSound() {
        NSSound(named: NSSound.Name("Tink"))?.play()
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
}
