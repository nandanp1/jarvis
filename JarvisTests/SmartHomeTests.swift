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
        resolver.clearRecentContext()
        XCTAssertNil(resolver.resolve("turn it off", among: devices))
    }

    func testSensitiveCommandsRequireExplicitConfirmation() {
        let unlock = HomeCommand.unlock(deviceID: "lock.front_door")
        XCTAssertTrue(unlock.requiresConfirmation)
        XCTAssertFalse(unlock.confirmedByUser().requiresConfirmation)

        XCTAssertTrue(HomeCommand.cover(deviceID: "cover.garage", action: .open).requiresConfirmation)
        XCTAssertTrue(HomeCommand.cover(deviceID: "cover.garage", action: .setPosition(percent: 50)).requiresConfirmation)
        XCTAssertFalse(HomeCommand.cover(deviceID: "cover.garage", action: .close).requiresConfirmation)
        XCTAssertTrue(HomeCommand.alarm(deviceID: "alarm_control_panel.home", action: .disarm, code: nil).requiresConfirmation)
        XCTAssertTrue(HomeCommand.activateScene(deviceID: "scene.away").requiresConfirmation)
        XCTAssertTrue(HomeCommand.runScript(deviceID: "script.goodnight").requiresConfirmation)
    }

    func testBulkResolutionHonorsRoomAndRejectsUnknownScope() {
        let devices = [
            SmartDevice(id: "light.bedroom", name: "Ceiling", room: "Bedroom", type: .light, capabilities: [.power]),
            SmartDevice(id: "light.kitchen", name: "Ceiling", room: "Kitchen", type: .light, capabilities: [.power])
        ]
        let resolver = DeviceResolver()

        XCTAssertEqual(
            resolver.resolveAll("all bedroom lights", among: devices).map(\.id),
            ["light.bedroom"]
        )
        XCTAssertTrue(resolver.resolveAll("all downstairs lights", among: devices).isEmpty)
        XCTAssertTrue(resolver.resolveAll("all bedrom lights", among: devices).isEmpty)
    }

    func testFahrenheitClimateValuesAreNormalizedToCelsius() {
        let entity = HomeAssistantEntity(
            entityID: "climate.bedroom",
            state: "heat",
            attributes: ["current_temperature": .number(68), "temperature": .number(72)]
        )

        let state = HomeAssistantProvider.deviceState(from: entity, fallbackTemperatureUnit: "°F")
        XCTAssertEqual(state.currentTemperatureCelsius ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(state.targetTemperatureCelsius ?? 0, 22.222, accuracy: 0.001)
        XCTAssertEqual(
            HomeAssistantProvider.homeAssistantTemperature(fromCelsius: 20, attributes: [:], fallbackUnit: "°F"),
            68,
            accuracy: 0.001
        )
    }

    func testToolRouterQueuesEverySensitiveActionAndReportsPartialConfirmation() async throws {
        let frontDoor = SmartDevice(
            id: "lock.front_door",
            name: "Front Door",
            room: "Entry",
            type: .lock,
            capabilities: [.queryState, .lock, .unlock]
        )
        let backDoor = SmartDevice(
            id: "lock.back_door",
            name: "Back Door",
            room: "Kitchen",
            type: .lock,
            capabilities: [.queryState, .lock, .unlock]
        )
        let provider = MockHomeProvider(devices: [frontDoor, backDoor])
        let macCommands = MacCommandService()
        let router = ToolCallRouter(
            homeProvider: provider,
            routineExecutor: RoutineExecutor(homeProvider: provider, macCommandService: macCommands),
            macCommands: macCommands
        )

        let first = await router.execute(GeminiFunctionCall(
            id: "unlock-front",
            name: "unlock_device",
            arguments: ["device": "front door"]
        ))
        let second = await router.execute(GeminiFunctionCall(
            id: "unlock-back",
            name: "unlock_device",
            arguments: ["device": "back door"]
        ))

        XCTAssertEqual(first.data["requires_confirmation"] as? Bool, true)
        XCTAssertEqual(first.data["pending_confirmation_count"] as? Int, 1)
        XCTAssertEqual(second.data["pending_confirmation_count"] as? Int, 2)
        XCTAssertTrue(router.hasPendingConfirmation)
        XCTAssertTrue(router.armPendingConfirmationTimeout(seconds: 30))

        let frontState = try await provider.getState(deviceID: frontDoor.id)
        await provider.replace(devices: [frontDoor], states: [frontDoor.id: frontState])

        let confirmation = await router.confirmPendingAction(confirmed: true)
        XCTAssertEqual(confirmation?.success, false)
        XCTAssertEqual(confirmation?.data["confirmed_action_count"] as? Int, 2)
        XCTAssertEqual(confirmation?.data["completed_action_count"] as? Int, 1)
        XCTAssertEqual(confirmation?.data["failed_action_count"] as? Int, 1)
        XCTAssertFalse(router.hasPendingConfirmation)
        let confirmedFrontState = try await provider.getState(deviceID: frontDoor.id)
        XCTAssertEqual(confirmedFrontState.rawState, "unlocked")
    }

    func testSensitiveRoutineIsQueuedWithConfirmationMetadata() async {
        let provider = MockHomeProvider()
        let macCommands = MacCommandService()
        let router = ToolCallRouter(
            homeProvider: provider,
            routineExecutor: RoutineExecutor(homeProvider: provider, macCommandService: macCommands),
            macCommands: macCommands
        )

        let result = await router.execute(GeminiFunctionCall(
            id: "goodnight",
            name: "run_routine",
            arguments: ["name": "Goodnight"]
        ))

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.data["requires_confirmation"] as? Bool, true)
        XCTAssertEqual(result.data["pending_confirmation_count"] as? Int, 1)
        XCTAssertTrue(router.hasPendingConfirmation)
        let cancellation = await router.confirmPendingAction(confirmed: false)
        XCTAssertEqual(cancellation?.data["cancelled_action_count"] as? Int, 1)
        XCTAssertFalse(router.hasPendingConfirmation)
    }

    func testToolRouterCapsDeviceListingAndMarksTruncation() async {
        let devices = (0..<105).map { index in
            SmartDevice(
                id: "sensor.device_\(index)",
                name: "Device \(index)",
                room: nil,
                type: .sensor,
                capabilities: [.queryState]
            )
        }
        let provider = MockHomeProvider(devices: devices)
        let macCommands = MacCommandService()
        let router = ToolCallRouter(
            homeProvider: provider,
            routineExecutor: RoutineExecutor(homeProvider: provider, macCommandService: macCommands),
            macCommands: macCommands
        )

        let result = await router.execute(GeminiFunctionCall(
            id: "list",
            name: "list_home_devices",
            arguments: [:]
        ))

        XCTAssertTrue(result.success)
        XCTAssertEqual((result.data["devices"] as? [[String: Any]])?.count, 100)
        XCTAssertEqual(result.data["total_count"] as? Int, 105)
        XCTAssertEqual(result.data["returned_count"] as? Int, 100)
        XCTAssertEqual(result.data["truncated"] as? Bool, true)
    }

    func testMacStatusToolIsReadOnlyAndReturnsBoundedSystemFacts() async {
        let provider = MockHomeProvider()
        let macCommands = MacCommandService()
        let router = ToolCallRouter(
            homeProvider: provider,
            routineExecutor: RoutineExecutor(homeProvider: provider, macCommandService: macCommands),
            macCommands: macCommands
        )

        let result = await router.execute(GeminiFunctionCall(
            id: "mac-status",
            name: "get_mac_status",
            arguments: [:]
        ))

        XCTAssertTrue(result.success)
        XCTAssertNotNil(result.data["hardware_architecture"] as? String)
        XCTAssertNotNil(result.data["operating_system"] as? String)
        XCTAssertNotNil(result.data["processor_count"] as? Int)
        XCTAssertNotNil(result.data["system_uptime_seconds"] as? Double)
    }

    func testToolRouterClearContextClearsPendingActionAndResolverRecency() async {
        let door = SmartDevice(
            id: "lock.front_door",
            name: "Front Door",
            room: "Entry",
            type: .lock,
            capabilities: [.queryState, .lock, .unlock]
        )
        let provider = MockHomeProvider(devices: [door])
        let resolver = DeviceResolver()
        resolver.recordUsage(of: door)
        let macCommands = MacCommandService()
        let router = ToolCallRouter(
            homeProvider: provider,
            resolver: resolver,
            routineExecutor: RoutineExecutor(homeProvider: provider, macCommandService: macCommands),
            macCommands: macCommands
        )
        _ = await router.execute(GeminiFunctionCall(
            id: "unlock",
            name: "unlock_device",
            arguments: ["device": "front door"]
        ))
        XCTAssertTrue(router.hasPendingConfirmation)
        XCTAssertEqual(resolver.resolve("it", among: [door])?.id, door.id)

        router.clearContext()

        XCTAssertFalse(router.hasPendingConfirmation)
        XCTAssertNil(resolver.resolve("it", among: [door]))
        XCTAssertFalse(router.armPendingConfirmationTimeout(seconds: 30))
    }

    func testLocalExecutionKeepsSuccessfulActionsWhenAnotherIntentFails() async throws {
        let light = SmartDevice(
            id: "light.bedroom",
            name: "Bedroom Light",
            room: "Bedroom",
            type: .light,
            capabilities: [.queryState, .power]
        )
        let provider = MockHomeProvider(devices: [light])
        let macCommands = MacCommandService()
        let router = ToolCallRouter(
            homeProvider: provider,
            routineExecutor: RoutineExecutor(homeProvider: provider, macCommandService: macCommands),
            macCommands: macCommands
        )

        let result = try await router.executeLocal([
            .power(reference: "bedroom light", on: true, all: false),
            .fan(reference: "missing fan", on: true)
        ])

        XCTAssertTrue(result.contains("Turned Bedroom Light on."))
        XCTAssertTrue(result.contains("1 action failed"))
        let updatedLightState = try await provider.getState(deviceID: light.id)
        XCTAssertEqual(updatedLightState.isOn, true)
    }

    func testLocalExecutionThrowsWhenNothingSucceeds() async {
        let provider = MockHomeProvider()
        let macCommands = MacCommandService()
        let router = ToolCallRouter(
            homeProvider: provider,
            routineExecutor: RoutineExecutor(homeProvider: provider, macCommandService: macCommands),
            macCommands: macCommands
        )

        do {
            _ = try await router.executeLocal([
                .fan(reference: "missing fan", on: true),
                .brightness(reference: "missing light", percent: 50)
            ])
            XCTFail("Expected the all-failed local request to throw.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing fan"))
        }
    }

    func testLocalSensitiveRoutineReturnsSpokenConfirmationAndStaysQueued() async throws {
        let provider = MockHomeProvider()
        let macCommands = MacCommandService()
        let router = ToolCallRouter(
            homeProvider: provider,
            routineExecutor: RoutineExecutor(homeProvider: provider, macCommandService: macCommands),
            macCommands: macCommands
        )

        let response = try await router.executeLocal([.routine(name: "goodnight")])

        XCTAssertTrue(response.contains("Are you sure"))
        XCTAssertTrue(response.contains("1 action is waiting for confirmation"))
        XCTAssertTrue(router.hasPendingConfirmation)
        _ = await router.confirmPendingAction(confirmed: false)
    }
}
