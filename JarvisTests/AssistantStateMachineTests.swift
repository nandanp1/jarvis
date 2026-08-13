import XCTest
@testable import Jarvis

final class AssistantStateMachineTests: XCTestCase {
    func testNormalVoicePathIsAccepted() {
        let machine = AssistantStateMachine()
        XCTAssertTrue(machine.transition(to: .wakeDetected))
        XCTAssertTrue(machine.transition(to: .listening))
        XCTAssertTrue(machine.transition(to: .processing))
        XCTAssertTrue(machine.transition(to: .executing))
        XCTAssertTrue(machine.transition(to: .speaking))
        XCTAssertTrue(machine.transition(to: .idle))
    }

    func testInvalidTransitionIsRejected() {
        let machine = AssistantStateMachine()
        XCTAssertFalse(machine.transition(to: .speaking))
        XCTAssertEqual(machine.state, .idle)
    }
}
