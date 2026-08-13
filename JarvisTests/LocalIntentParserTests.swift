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

    func testWordsContainingAllAreNeverBulkCommands() {
        XCTAssertEqual(
            parser.parse("turn hall light off"),
            [.power(reference: "hall light", on: false, all: false)]
        )
        XCTAssertEqual(
            parser.parse("turn small lamp on"),
            [.power(reference: "small lamp", on: true, all: false)]
        )
        XCTAssertEqual(
            parser.parse("turn fancy lamp off"),
            [.power(reference: "fancy lamp", on: false, all: false)]
        )
    }

    func testParseResultDistinguishesFullyLocalFromMixedRequest() {
        let local = parser.parseResult("turn the desk light off and turn the fan on")
        XCTAssertTrue(local.isFullyRecognized)
        XCTAssertEqual(local.intents.count, 2)

        let mixed = parser.parseResult("turn the desk light off and what's the weather tomorrow")
        XCTAssertFalse(mixed.isFullyRecognized)
        XCTAssertEqual(mixed.intents.count, 1)
        XCTAssertEqual(mixed.unrecognizedFragments.count, 1)
    }
}
