import XCTest
@testable import Jarvis

final class SmartHomeTests: XCTestCase {
    func testMockProviderExecutesRealStateTransition() async throws {
        let light = SmartDevice(
            id: "light.bedroom",
            name: "Bedroom Light",
            room: "Bedroom",
            type: .light,
            capabilities: [.queryState, .power, .brightness]
        )
        let provider = MockHomeProvider(devices: [light])

        try await provider.execute(command: .setBrightness(deviceID: light.id, percent: 25))
        let state = try await provider.getState(deviceID: light.id)

        XCTAssertEqual(state.isOn, true)
        XCTAssertEqual(state.brightnessPercent, 25)
    }

    func testHomeAssistantLightMapping() {
        let entity = HomeAssistantEntity(
            entityID: "light.bedroom_ceiling",
            state: "on",
            attributes: [
                "friendly_name": .string("Bedroom Ceiling"),
                "brightness": .number(128),
                "rgb_color": .array([.number(10), .number(20), .number(30)]),
                "color_temp_kelvin": .number(3_000),
                "supported_color_modes": .array([.string("rgb"), .string("color_temp")])
            ]
        )

        let device = HomeAssistantProvider.device(from: entity)
        XCTAssertEqual(device?.type, .light)
        XCTAssertEqual(device?.room, "Bedroom")
        XCTAssertTrue(device?.capabilities.contains(.brightness) == true)
        XCTAssertTrue(device?.capabilities.contains(.color) == true)
        XCTAssertTrue(device?.capabilities.contains(.colorTemperature) == true)

        let state = HomeAssistantProvider.deviceState(from: entity)
        XCTAssertEqual(state.isOn, true)
        XCTAssertEqual(state.brightnessPercent, 50)
        XCTAssertEqual(state.color, LightColor(red: 10, green: 20, blue: 30))
        XCTAssertEqual(state.colorTemperatureKelvin, 3_000)
    }

    func testNaturalDeviceResolutionAndRecency() {
        let devices = [
            SmartDevice(
                id: "light.bedroom_ceiling",
                name: "Bedroom Ceiling",
                room: "Bedroom",
                type: .light,
                capabilities: [.power, .brightness]
            ),
            SmartDevice(
                id: "light.desk_lamp",
                name: "Desk Lamp",
                room: "Bedroom",
                type: .light,
                capabilities: [.power, .brightness]
            )
        ]
        let resolver = DeviceResolver()

        XCTAssertEqual(resolver.resolve("my ceiling light", among: devices)?.id, "light.bedroom_ceiling")
        XCTAssertNil(resolver.resolve("the light", among: devices))
        resolver.recordUsage(of: devices[1])
        XCTAssertEqual(resolver.resolve("the light", among: devices)?.id, "light.desk_lamp")
        XCTAssertEqual(resolver.resolve("turn it off", among: devices)?.id, "light.desk_lamp")
    }

    func testSensitiveCommandsRequireExplicitConfirmation() {
        let unlock = HomeCommand.unlock(deviceID: "lock.front_door")
        XCTAssertTrue(unlock.requiresConfirmation)
        XCTAssertFalse(unlock.confirmedByUser().requiresConfirmation)

        XCTAssertTrue(HomeCommand.cover(deviceID: "cover.garage", action: .open).requiresConfirmation)
        XCTAssertFalse(HomeCommand.cover(deviceID: "cover.garage", action: .close).requiresConfirmation)
        XCTAssertTrue(HomeCommand.alarm(deviceID: "alarm_control_panel.home", action: .disarm, code: nil).requiresConfirmation)
    }
}
