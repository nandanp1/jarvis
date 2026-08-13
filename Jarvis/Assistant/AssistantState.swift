import Foundation

enum AssistantState: String, CaseIterable {
    case idle
    case wakeDetected
    case listening
    case processing
    case executing
    case speaking
    case error

    var statusText: String {
        switch self {
        case .idle: return "Ready"
        case .wakeDetected: return "Wake phrase detected"
        case .listening: return "Listening…"
        case .processing: return "Thinking…"
        case .executing: return "Working…"
        case .speaking: return "Speaking…"
        case .error: return "Needs attention"
        }
    }

    var promptText: String {
        switch self {
        case .idle: return "Press Talk or enable hands-free listening"
        case .wakeDetected: return "I’m listening"
        case .listening: return "What can I do for you?"
        case .processing: return "Thinking…"
        case .executing: return "Taking care of it…"
        case .speaking: return ""
        case .error: return "Open Jarvis Settings to check the connection"
        }
    }
}
