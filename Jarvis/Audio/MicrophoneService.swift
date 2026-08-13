import AVFoundation
import Foundation

enum MicrophoneError: LocalizedError {
    case unavailable
    case invalidFormat
    case alreadyInUse
    case engineFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "No microphone is available. Check the Mac’s audio input device."
        case .invalidFormat:
            return "The selected microphone reported an invalid audio format."
        case .alreadyInUse:
            return "The microphone is already being used by another Jarvis listening session."
        case .engineFailed(let error):
            return "The microphone audio engine could not start: \(error.localizedDescription)"
        }
    }
}

/// The sole owner of Jarvis's AVAudioEngine input tap.
final class MicrophoneService {
    typealias BufferHandler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let engine = AVAudioEngine()
    private let controlQueue = DispatchQueue(label: "com.nandan.jarvis.microphone")
    private var activeSessionID: UUID?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?

    var onConfigurationChange: (() -> Void)?

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.controlQueue.async {
                guard self?.activeSessionID != nil else { return }
                self?.stopLocked()
                DispatchQueue.main.async { self?.onConfigurationChange?() }
            }
        }
    }

    deinit {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stop()
    }

    func start(sessionID: UUID, bufferSize: AVAudioFrameCount = 1_024, handler: @escaping BufferHandler) throws {
        try controlQueue.sync {
            guard activeSessionID == nil else { throw MicrophoneError.alreadyInUse }

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw MicrophoneError.invalidFormat
            }

            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }

            input.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: handler)
            tapInstalled = true
            engine.prepare()

            do {
                try engine.start()
                activeSessionID = sessionID
            } catch {
                input.removeTap(onBus: 0)
                tapInstalled = false
                engine.reset()
                throw MicrophoneError.engineFailed(error)
            }
        }
    }

    func stop(sessionID: UUID? = nil) {
        controlQueue.sync {
            guard sessionID == nil || sessionID == activeSessionID else { return }
            stopLocked()
        }
    }

    private func stopLocked() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.reset()
        activeSessionID = nil
    }
}
