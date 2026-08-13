import XCTest
@testable import Jarvis

final class LocalIntentParserTests: XCTestCase {
    private let parser = LocalIntentParser()

    func testParsesPowerAndBrightnessCommands() {
        XCTAssertEqual(
            parser.parse("turn bedroom light off"),
            [.power(reference: "bedroom light", on: false, all: false)]
        )
        XCTAssertEqual(
            parser.parse("set bedroom light to 50 percent"),
            [.brightness(reference: "bedroom light", percent: 50)]
        )
    }

    func testParsesAllLightsAndRoutine() {
        XCTAssertEqual(
            parser.parse("turn all lights off"),
            [.power(reference: "all lights", on: false, all: true)]
        )
        XCTAssertEqual(parser.parse("goodnight"), [.routine(name: "goodnight")])
    }

    func testRejectsOutOfRangeValuesAndQuestions() {
        XCTAssertTrue(parser.parse("set bedroom light to 150 percent").isEmpty)
        XCTAssertTrue(parser.parse("what's the weather tomorrow").isEmpty)
    }
}
