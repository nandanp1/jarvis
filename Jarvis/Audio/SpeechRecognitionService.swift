import Foundation
import Speech

enum SpeechRecognitionError: LocalizedError {
    case unavailable
    case noSpeech
    case timedOut
    case emptyTranscription
    case recognitionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Speech Recognition is not currently available."
        case .noSpeech: return "I didn’t hear anything. Try speaking a little closer to the microphone."
        case .timedOut: return "That command was too long, so I stopped listening."
        case .emptyTranscription: return "I heard audio but couldn’t understand the words."
        case .recognitionFailed(let error): return "Speech Recognition failed: \(error.localizedDescription)"
        }
    }
}

final class SpeechRecognitionService {
    struct Configuration {
        var noSpeechTimeout: TimeInterval = 7
        var maximumDuration: TimeInterval = 30
        var finalResultGracePeriod: TimeInterval = 1.8
    }

    private let microphone: MicrophoneService
    private let recognizer: SFSpeechRecognizer?
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.nandan.jarvis.command-recognition")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionID: UUID?
    private var vad = VoiceActivityDetector()
    private var latestTranscript = ""
    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?
    private var onError: ((Error) -> Void)?
    private var noSpeechWorkItem: DispatchWorkItem?
    private var maximumDurationWorkItem: DispatchWorkItem?
    private var finalizationWorkItem: DispatchWorkItem?
    private var isFinalizing = false

    init(
        microphone: MicrophoneService,
        locale: Locale = Locale(identifier: "en-US"),
        configuration: Configuration = Configuration()
    ) {
        self.microphone = microphone
        recognizer = SFSpeechRecognizer(locale: locale)
        self.configuration = configuration
    }

    func start(
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        queue.async { [weak self] in
            self?.startLocked(onPartial: onPartial, onFinal: onFinal, onError: onError)
        }
    }

    func stop(cancelled: Bool = true) {
        queue.async { [weak self] in self?.stopLocked(cancelled: cancelled) }
    }

    private func startLocked(
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        stopLocked(cancelled: true)
        guard let recognizer = recognizer, recognizer.isAvailable else {
            DispatchQueue.main.async { onError(SpeechRecognitionError.unavailable) }
            return
        }

        let sessionID = UUID()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Jarvis", "Home Assistant", "goodnight", "movie mode"]
        self.sessionID = sessionID
        self.request = request
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError
        latestTranscript = ""
        isFinalizing = false
        vad.reset()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.queue.async {
                self?.handleRecognition(result: result, error: error, sessionID: sessionID)
            }
        }

        do {
            try microphone.start(sessionID: sessionID) { [weak self, weak request] buffer, _ in
                request?.append(buffer)
                guard let event = self?.vad.process(buffer) else { return }
                self?.queue.async {
                    guard self?.sessionID == sessionID else { return }
                    if event == .speechStarted {
                        self?.noSpeechWorkItem?.cancel()
                    } else if event == .speechEnded {
                        self?.beginFinalization(sessionID: sessionID)
                    }
                }
            }
        } catch {
            stopLocked(cancelled: true)
            DispatchQueue.main.async { onError(error) }
            return
        }

        scheduleTimeouts(sessionID: sessionID)
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }

        if let result = result {
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            latestTranscript = text
            DispatchQueue.main.async { [weak self] in self?.onPartial?(text) }
            if result.isFinal {
                complete(text: text)
                return
            }
        }

        if let error = error, !isFinalizing {
            fail(SpeechRecognitionError.recognitionFailed(error))
        }
    }

    private func beginFinalization(sessionID: UUID) {
        guard self.sessionID == sessionID, !isFinalizing else { return }
        isFinalizing = true
        microphone.stop(sessionID: sessionID)
        request?.endAudio()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.sessionID == sessionID else { return }
            if self.latestTranscript.isEmpty {
                self.fail(SpeechRecognitionError.emptyTranscription)
            } else {
                self.complete(text: self.latestTranscript)
            }
        }
        finalizationWorkItem = work
        queue.asyncAfter(deadline: .now() + configuration.finalResultGracePeriod, execute: work)
    }

    private func scheduleTimeouts(sessionID: UUID) {
        let noSpeech = DispatchWorkItem { [weak self] in
            guard let self = self, self.sessionID == sessionID else { return }
            self.fail(SpeechRecognitionError.noSpeech)
        }
        noSpeechWorkItem = noSpeech
        queue.asyncAfter(deadline: .now() + configuration.noSpeechTimeout, execute: noSpeech)

        let maximum = DispatchWorkItem { [weak self] in
            guard let self = self, self.sessionID == sessionID else { return }
            if self.latestTranscript.isEmpty {
                self.fail(SpeechRecognitionError.timedOut)
            } else {
                self.complete(text: self.latestTranscript)
            }
        }
        maximumDurationWorkItem = maximum
        queue.asyncAfter(deadline: .now() + configuration.maximumDuration, execute: maximum)
    }

    private func complete(text: String) {
        let callback = onFinal
        let errorCallback = onError
        stopLocked(cancelled: false)
        guard !text.isEmpty else {
            DispatchQueue.main.async { errorCallback?(SpeechRecognitionError.emptyTranscription) }
            return
        }
        DispatchQueue.main.async { callback?(text) }
    }

    private func fail(_ error: Error) {
        let callback = onError
        stopLocked(cancelled: true)
        DispatchQueue.main.async { callback?(error) }
    }

    private func stopLocked(cancelled: Bool) {
        noSpeechWorkItem?.cancel()
        maximumDurationWorkItem?.cancel()
        finalizationWorkItem?.cancel()
        noSpeechWorkItem = nil
        maximumDurationWorkItem = nil
        finalizationWorkItem = nil

        if let sessionID = sessionID { microphone.stop(sessionID: sessionID) }
        if cancelled { request?.endAudio() }
        task?.cancel()
        request = nil
        task = nil
        sessionID = nil
        latestTranscript = ""
        onPartial = nil
        onFinal = nil
        onError = nil
        isFinalizing = false
    }
}
