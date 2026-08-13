import Foundation

struct ConversationMessage: Equatable {
    enum Role: String {
        case user
        case jarvis
    }

    let role: Role
    let text: String
    let date: Date
}

final class ConversationManager {
    private let queue = DispatchQueue(label: "com.nandan.jarvis.conversation")
    private var messages: [ConversationMessage] = []
    private let maximumMessages: Int

    init(maximumTurns: Int) {
        maximumMessages = max(4, maximumTurns * 2)
    }

    func append(role: ConversationMessage.Role, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.sync {
            messages.append(ConversationMessage(role: role, text: trimmed, date: Date()))
            if messages.count > maximumMessages {
                messages.removeFirst(messages.count - maximumMessages)
            }
        }
    }

    func snapshot() -> [ConversationMessage] {
        queue.sync { messages }
    }

    func clear() {
        queue.sync { messages.removeAll(keepingCapacity: false) }
    }
}
