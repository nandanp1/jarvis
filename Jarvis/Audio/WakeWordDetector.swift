import Foundation
import Speech

struct WakeWordMatch: Equatable {
    let phrase: String
    let trailingCommand: String?
}

protocol WakeWordDetector: AnyObject {
    var isRunning: Bool { get }
    var usesOnDeviceRecognition: Bool { get }
    func start(onWake: @escaping (WakeWordMatch) -> Void, onError: @escaping (Error) -> Void)
    func stop()
}

enum WakeWordError: LocalizedError {
    case unavailable
    case onDeviceRecognitionUnavailable
    case recognitionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Wake phrase recognition is not currently available. Manual Talk still works."
        case .onDeviceRecognitionUnavailable:
            return "This Mac does not have on-device Speech Recognition for the selected language. Hands-free mode is off to keep idle room audio local; Manual Talk still works."
        case .recognitionFailed(let error):
            return "Wake phrase recognition stopped: \(error.localizedDescription)"
        }
    }
}

final class NativeSpeechWakeWordDetector: WakeWordDetector {
    private let microphone: MicrophoneService
    private let recognizer: SFSpeechRecognizer?
    private let phraseProvider: () -> String
    private let queue = DispatchQueue(label: "com.nandan.jarvis.wake-word")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionID: UUID?
    private var rotationWorkItem: DispatchWorkItem?
    private var wakeCallback: ((WakeWordMatch) -> Void)?
    private var errorCallback: ((Error) -> Void)?
    private var desiredRunning = false
    private var running = false

    var isRunning: Bool { queue.sync { running } }
    var usesOnDeviceRecognition: Bool { recognizer?.supportsOnDeviceRecognition == true }

    init(
        microphone: MicrophoneService,
        phraseProvider: @escaping () -> String,
        locale: Locale = Locale(identifier: "en-US")
    ) {
        self.microphone = microphone
        self.phraseProvider = phraseProvider
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start(onWake: @escaping (WakeWordMatch) -> Void, onError: @escaping (Error) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.desiredRunning = true
            self.wakeCallback = onWake
            self.errorCallback = onError
            self.startSessionLocked()
        }
    }

    func stop() {
        queue.sync {
            desiredRunning = false
            stopSessionLocked()
            wakeCallback = nil
            errorCallback = nil
        }
    }

    private func startSessionLocked() {
        stopSessionLocked()
        guard desiredRunning else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            report(WakeWordError.unavailable)
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            desiredRunning = false
            report(WakeWordError.onDeviceRecognitionUnavailable)
            return
        }

        let sessionID = UUID()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = [phraseProvider(), "Jarvis"]
        self.sessionID = sessionID
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.queue.async {
                guard let self = self, self.sessionID == sessionID else { return }
                if let transcript = result?.bestTranscription.formattedString,
                   let match = Self.match(in: transcript, configuredPhrase: self.phraseProvider()) {
                    let callback = self.wakeCallback
                    self.desiredRunning = false
                    self.stopSessionLocked()
                    DispatchQueue.main.async { callback?(match) }
                    return
                }

                if let error = error, self.desiredRunning {
                    self.stopSessionLocked()
                    self.report(WakeWordError.recognitionFailed(error))
                }
            }
        }

        do {
            try microphone.start(sessionID: sessionID) { [weak request] buffer, _ in request?.append(buffer) }
            running = true
        } catch {
            desiredRunning = false
            stopSessionLocked()
            report(error)
            return
        }

        let rotation = DispatchWorkItem { [weak self] in
            guard let self = self, self.desiredRunning, self.sessionID == sessionID else { return }
            self.stopSessionLocked()
            self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.startSessionLocked() }
        }
        rotationWorkItem = rotation
        queue.asyncAfter(deadline: .now() + 48, execute: rotation)
    }

    private func stopSessionLocked() {
        rotationWorkItem?.cancel()
        rotationWorkItem = nil
        if let sessionID = sessionID { microphone.stop(sessionID: sessionID) }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        sessionID = nil
        running = false
    }

    private func report(_ error: Error) {
        let callback = errorCallback
        DispatchQueue.main.async { callback?(error) }
    }

    static func match(in transcript: String, configuredPhrase: String) -> WakeWordMatch? {
        let candidates = [configuredPhrase, "Hey Jarvis", "Jarvis"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        for phrase in candidates {
            guard let range = transcript.range(
                of: phrase,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) else { continue }

            let beforeOK = range.lowerBound == transcript.startIndex || !transcript[transcript.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == transcript.endIndex || !transcript[range.upperBound].isLetter
            guard beforeOK, afterOK else { continue }

            let tail = transcript[range.upperBound...]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            return WakeWordMatch(phrase: phrase, trailingCommand: tail.isEmpty ? nil : tail)
        }
        return nil
    }
}
