import AVFoundation
import Foundation
import Speech

enum AudioPermissionStatus: Equatable {
    case authorized
    case denied(String)
}

enum AudioPermissions {
    static var currentStatus: AudioPermissionStatus {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()

        if microphone == .denied || microphone == .restricted {
            return .denied("Microphone access is disabled. Enable Jarvis in System Preferences › Security & Privacy › Microphone.")
        }
        if speech == .denied || speech == .restricted {
            return .denied("Speech Recognition access is disabled. Enable Jarvis in System Preferences › Security & Privacy › Speech Recognition.")
        }
        return microphone == .authorized && speech == .authorized
            ? .authorized
            : .denied("Jarvis needs microphone and Speech Recognition access.")
    }

    static func request(completion: @escaping (AudioPermissionStatus) -> Void) {
        requestMicrophone { microphoneGranted in
            guard microphoneGranted else {
                DispatchQueue.main.async {
                    completion(.denied("Jarvis cannot listen until microphone access is enabled in System Preferences."))
                }
                return
            }

            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    switch status {
                    case .authorized:
                        completion(.authorized)
                    case .denied, .restricted:
                        completion(.denied("Jarvis cannot transcribe speech until Speech Recognition access is enabled in System Preferences."))
                    case .notDetermined:
                        completion(.denied("Speech Recognition permission was not granted."))
                    @unknown default:
                        completion(.denied("Speech Recognition permission has an unknown status."))
                    }
                }
            }
        }
    }

    private static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
}
