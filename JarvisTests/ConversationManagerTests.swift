import XCTest
@testable import Jarvis

final class ConversationManagerTests: XCTestCase {
    func testBoundsConversationHistoryByTurns() {
        let manager = ConversationManager(maximumTurns: 2)
        for index in 0..<8 {
            manager.append(role: index.isMultiple(of: 2) ? .user : .jarvis, text: "message \(index)")
        }

        XCTAssertEqual(manager.snapshot().map(\.text), ["message 4", "message 5", "message 6", "message 7"])
    }

    func testClearRemovesHistory() {
        let manager = ConversationManager(maximumTurns: 2)
        manager.append(role: .user, text: "Hello")
        manager.clear()
        XCTAssertTrue(manager.snapshot().isEmpty)
    }
}
