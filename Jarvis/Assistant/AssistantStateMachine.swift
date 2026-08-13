import Foundation

final class AssistantStateMachine {
    private let queue = DispatchQueue(label: "com.nandan.jarvis.state-machine")
    private var storedState: AssistantState = .idle

    var state: AssistantState { queue.sync { storedState } }

    @discardableResult
    func transition(to newState: AssistantState) -> Bool {
        queue.sync {
            guard isAllowed(from: storedState, to: newState) else {
                JarvisLog.error("Rejected assistant state transition from \(storedState.rawValue) to \(newState.rawValue)")
                return false
            }
            storedState = newState
            return true
        }
    }

    private func isAllowed(from oldState: AssistantState, to newState: AssistantState) -> Bool {
        if oldState == newState { return true }
        if newState == .error || newState == .idle { return true }
        switch (oldState, newState) {
        case (.idle, .wakeDetected),
             (.idle, .listening),
             (.wakeDetected, .listening),
             (.listening, .processing),
             (.processing, .executing),
             (.processing, .speaking),
             (.executing, .processing),
             (.executing, .speaking),
             (.error, .listening):
            return true
        default:
            return false
        }
    }
}
