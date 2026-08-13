import Foundation

actor HomeAssistantProvider: HomeControlProvider {
    private struct ServiceInvocation {
        let domain: String
        let name: String
        let fields: [String: JSONValue]
        let requiredCapability: DeviceCapability?
    }

    private let service: HomeAssistantService
    private var devicesByID: [String: SmartDevice] = [:]
    private var statesByID: [String: DeviceState] = [:]

    init(service: HomeAssistantService) {
        self.service = service
    }

    @discardableResult
    func testConnection() async throws -> Bool {
        try await service.testConnection()
    }

    func listDevices() async throws -> [SmartDevice] {
        let entities = try await service.fetchStates()
        let mapped = entities.compactMap(Self.device(from:))
        devicesByID = Dictionary(uniqueKeysWithValues: mapped.map { ($0.id, $0) })
        for entity in entities where devicesByID[entity.entityID] != nil {
            statesByID[entity.entityID] = Self.deviceState(from: entity)
        }
        return mapped.sorted {
            let leftRoom = $0.room ?? ""
            let rightRoom = $1.room ?? ""
            if leftRoom.localizedCaseInsensitiveCompare(rightRoom) != .orderedSame {
                return leftRoom.localizedCaseInsensitiveCompare(rightRoom) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func getState(deviceID: String) async throws -> DeviceState {
        let entity = try await service.fetchState(entityID: deviceID)
        guard Self.device(from: entity) != nil else {
            throw HomeControlError.unsupportedDevice(deviceID)
        }
        let state = Self.deviceState(from: entity)
        statesByID[deviceID] = state
        return state
    }

    func execute(command: HomeCommand) async throws {
        let confirmed: Bool
        switch command {
        case .confirmed:
            confirmed = true
        default:
            confirmed = false
        }

        if command.requiresConfirmation && !confirmed {
            throw HomeControlError.confirmationRequired(
                command.confirmationPrompt ?? "This smart-home action needs confirmation."
            )
        }

        let executable = command.commandAfterConfirmation
        let before = try await service.fetchState(entityID: executable.deviceID)
        guard let device = Self.device(from: before) else {
            throw HomeControlError.unsupportedDevice(executable.deviceID)
        }
        devicesByID[device.id] = device
        statesByID[device.id] = Self.deviceState(from: before)

        let invocation = try Self.invocation(for: executable, device: device, entity: before)
        if let capability = invocation.requiredCapability,
           !device.capabilities.contains(capability) {
            throw HomeControlError.unsupportedCommand(
                "\(device.name) does not report support for \(capability.rawValue.replacingOccurrences(of: "_", with: " "))."
            )
        }

        let refreshed = try await service.callService(
            domain: invocation.domain,
            service: invocation.name,
            entityID: device.id,
            fields: invocation.fields
        )
        let finalState = try await waitForConfirmation(of: executable, startingWith: refreshed)
        statesByID[device.id] = finalState
    }

    static func device(from entity: HomeAssistantEntity) -> SmartDevice? {
        let domain = domainName(for: entity.entityID)
        let attributes = entity.attributes
        let deviceClass = attributes["device_class"]?.stringValue?.lowercased()
        let type: DeviceType

        switch domain {
        case "light": type = .light
        case "switch": type = deviceClass == "outlet" ? .outlet : .switchDevice
        case "fan": type = .fan
        case "climate": type = .thermostat
        case "scene": type = .scene
        case "script": type = .script
        case "media_player": type = .mediaPlayer
        case "cover": type = deviceClass == "garage" ? .garageDoor : .cover
        case "lock": type = .lock
        case "alarm_control_panel": type = .alarm
        default: return nil
        }

        let fallbackName = entity.entityID
            .split(separator: ".", maxSplits: 1)
            .last
            .map(String.init)?
            .replacingOccurrences(of: "_", with: " ")
            .capitalized ?? entity.entityID
        let name = attributes["friendly_name"]?.stringValue?.nonEmpty ?? fallbackName
        let room = explicitRoom(in: attributes) ?? inferredRoom(from: name)
        let capabilities = capabilities(for: domain, type: type, attributes: attributes)
        return SmartDevice(id: entity.entityID, name: name, room: room, type: type, capabilities: capabilities)
    }

    static func deviceState(from entity: HomeAssistantEntity) -> DeviceState {
        let rawState = entity.state.lowercased()
        let domain = domainName(for: entity.entityID)
        let unavailable = rawState == "unavailable" || rawState == "unknown"
        let isOn: Bool?
        if unavailable {
            isOn = nil
        } else {
            switch domain {
            case "light", "switch", "fan":
                isOn = rawState == "on"
            case "climate":
                isOn = rawState != "off"
            case "media_player":
                isOn = rawState != "off" && rawState != "standby"
            case "cover":
                isOn = rawState != "closed" && rawState != "closing"
            default:
                isOn = nil
            }
        }

        let attributes = entity.attributes
        let brightness = attributes["brightness"]?.doubleValue.map {
            boundedPercent(($0 / 255.0) * 100.0)
        }
        let rgbValues = attributes["rgb_color"]?.doubleArrayValue
        let color: LightColor?
        if let rgb = rgbValues, rgb.count >= 3 {
            color = LightColor(red: Int(rgb[0].rounded()), green: Int(rgb[1].rounded()), blue: Int(rgb[2].rounded()))
        } else {
            color = nil
        }

        let kelvin: Int?
        if let value = attributes["color_temp_kelvin"]?.doubleValue {
            kelvin = Int(value.rounded())
        } else if let mireds = attributes["color_temp"]?.doubleValue, mireds > 0 {
            kelvin = Int((1_000_000.0 / mireds).rounded())
        } else {
            kelvin = nil
        }

        let volume = attributes["volume_level"]?.doubleValue.map { boundedPercent($0 * 100.0) }
        let updatedDate = parseISO8601(entity.lastUpdated ?? entity.lastChanged)
        return DeviceState(
            deviceID: entity.entityID,
            rawState: rawState,
            isAvailable: !unavailable,
            isOn: isOn,
            brightnessPercent: brightness,
            color: color,
            colorTemperatureKelvin: kelvin,
            fanSpeedPercent: attributes["percentage"]?.doubleValue.map(boundedPercent),
            currentTemperatureCelsius: attributes["current_temperature"]?.doubleValue,
            targetTemperatureCelsius: attributes["temperature"]?.doubleValue,
            hvacMode: domain == "climate" ? rawState : nil,
            mediaState: domain == "media_player" ? rawState : nil,
            volumePercent: volume,
            isMuted: attributes["is_volume_muted"]?.boolValue,
            coverPositionPercent: attributes["current_position"]?.doubleValue.map(boundedPercent),
            lastUpdated: updatedDate
        )
    }

    private func waitForConfirmation(
        of command: HomeCommand,
        startingWith entity: HomeAssistantEntity
    ) async throws -> DeviceState {
        var state = Self.deviceState(from: entity)
        if Self.isConfirmed(command, by: state) {
            return state
        }

        for _ in 0..<4 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let refreshed = try await service.fetchState(entityID: command.deviceID)
            state = Self.deviceState(from: refreshed)
            if Self.isConfirmed(command, by: state) {
                return state
            }
        }

        throw HomeControlError.actionNotConfirmed(
            "Home Assistant accepted the command, but the refreshed device state did not confirm the change."
        )
    }

    private static func invocation(
        for command: HomeCommand,
        device: SmartDevice,
        entity: HomeAssistantEntity
    ) throws -> ServiceInvocation {
        let domain = domainName(for: device.id)
        switch command {
        case .turnOn:
            guard ["light", "switch", "fan", "media_player"].contains(domain) else {
                throw HomeControlError.unsupportedCommand("\(device.name) cannot be turned on with this command.")
            }
            return ServiceInvocation(domain: domain, name: "turn_on", fields: [:], requiredCapability: .power)
        case .turnOff:
            guard ["light", "switch", "fan", "media_player"].contains(domain) else {
                throw HomeControlError.unsupportedCommand("\(device.name) cannot be turned off with this command.")
            }
            return ServiceInvocation(domain: domain, name: "turn_off", fields: [:], requiredCapability: .power)
        case .setBrightness(_, let percent):
            try validatePercent(percent)
            try requireDomain("light", actual: domain, device: device)
            return ServiceInvocation(
                domain: "light",
                name: "turn_on",
                fields: ["brightness_pct": .number(Double(percent))],
                requiredCapability: .brightness
            )
        case .setColor(_, let color):
            try requireDomain("light", actual: domain, device: device)
            return ServiceInvocation(
                domain: "light",
                name: "turn_on",
                fields: ["rgb_color": .array([.number(Double(color.red)), .number(Double(color.green)), .number(Double(color.blue))])],
                requiredCapability: .color
            )
        case .setColorTemperature(_, let kelvin):
            guard (1_000...40_000).contains(kelvin) else {
                throw HomeControlError.invalidValue("Color temperature must be between 1,000 K and 40,000 K.")
            }
            if let minimum = entity.attributes["min_color_temp_kelvin"]?.doubleValue,
               Double(kelvin) < minimum {
                throw HomeControlError.invalidValue("\(device.name) cannot go below \(Int(minimum.rounded())) K.")
            }
            if let maximum = entity.attributes["max_color_temp_kelvin"]?.doubleValue,
               Double(kelvin) > maximum {
                throw HomeControlError.invalidValue("\(device.name) cannot go above \(Int(maximum.rounded())) K.")
            }
            try requireDomain("light", actual: domain, device: device)
            return ServiceInvocation(
                domain: "light",
                name: "turn_on",
                fields: ["color_temp_kelvin": .number(Double(kelvin))],
                requiredCapability: .colorTemperature
            )
        case .setFanSpeed(_, let percent):
            try validatePercent(percent)
            try requireDomain("fan", actual: domain, device: device)
            return ServiceInvocation(
                domain: "fan",
                name: "set_percentage",
                fields: ["percentage": .number(Double(percent))],
                requiredCapability: .fanSpeed
            )
        case .setTemperature(_, let celsius):
            guard celsius.isFinite, (-100.0...100.0).contains(celsius) else {
                throw HomeControlError.invalidValue("The requested temperature is outside the supported range.")
            }
            if let minimum = entity.attributes["min_temp"]?.doubleValue, celsius < minimum {
                throw HomeControlError.invalidValue("\(device.name) cannot be set below \(minimum)°.")
            }
            if let maximum = entity.attributes["max_temp"]?.doubleValue, celsius > maximum {
                throw HomeControlError.invalidValue("\(device.name) cannot be set above \(maximum)°.")
            }
            try requireDomain("climate", actual: domain, device: device)
            return ServiceInvocation(
                domain: "climate",
                name: "set_temperature",
                fields: ["temperature": .number(celsius)],
                requiredCapability: .targetTemperature
            )
        case .setHVACMode(_, let mode):
            let normalized = mode.lowercased().replacingOccurrences(of: " ", with: "_")
            guard !normalized.isEmpty else {
                throw HomeControlError.invalidValue("Choose a thermostat mode.")
            }
            if let available = entity.attributes["hvac_modes"]?.stringArrayValue,
               !available.map({ $0.lowercased() }).contains(normalized) {
                throw HomeControlError.invalidValue("\(device.name) does not offer the \(mode) mode.")
            }
            try requireDomain("climate", actual: domain, device: device)
            return ServiceInvocation(
                domain: "climate",
                name: "set_hvac_mode",
                fields: ["hvac_mode": .string(normalized)],
                requiredCapability: .hvacMode
            )
        case .activateScene:
            try requireDomain("scene", actual: domain, device: device)
            return ServiceInvocation(domain: "scene", name: "turn_on", fields: [:], requiredCapability: .activate)
        case .runScript:
            try requireDomain("script", actual: domain, device: device)
            return ServiceInvocation(domain: "script", name: "turn_on", fields: [:], requiredCapability: .activate)
        case .media(_, let action):
            try requireDomain("media_player", actual: domain, device: device)
            return try mediaInvocation(action: action)
        case .cover(_, let action):
            try requireDomain("cover", actual: domain, device: device)
            return try coverInvocation(action: action)
        case .lock:
            try requireDomain("lock", actual: domain, device: device)
            return ServiceInvocation(domain: "lock", name: "lock", fields: [:], requiredCapability: .lock)
        case .unlock:
            try requireDomain("lock", actual: domain, device: device)
            return ServiceInvocation(domain: "lock", name: "unlock", fields: [:], requiredCapability: .unlock)
        case .alarm(_, let action, let code):
            try requireDomain("alarm_control_panel", actual: domain, device: device)
            var fields: [String: JSONValue] = [:]
            if let code = code, !code.isEmpty { fields["code"] = .string(code) }
            let serviceName: String
            let capability: DeviceCapability
            switch action {
            case .armHome: serviceName = "alarm_arm_home"; capability = .arm
            case .armAway: serviceName = "alarm_arm_away"; capability = .arm
            case .armNight: serviceName = "alarm_arm_night"; capability = .arm
            case .disarm: serviceName = "alarm_disarm"; capability = .disarm
            case .trigger: serviceName = "alarm_trigger"; capability = .arm
            }
            return ServiceInvocation(domain: "alarm_control_panel", name: serviceName, fields: fields, requiredCapability: capability)
        case .confirmed(let inner):
            return try invocation(for: inner.commandAfterConfirmation, device: device, entity: entity)
        }
    }

    private static func mediaInvocation(action: MediaAction) throws -> ServiceInvocation {
        switch action {
        case .play:
            return ServiceInvocation(domain: "media_player", name: "media_play", fields: [:], requiredCapability: .playback)
        case .pause:
            return ServiceInvocation(domain: "media_player", name: "media_pause", fields: [:], requiredCapability: .playback)
        case .stop:
            return ServiceInvocation(domain: "media_player", name: "media_stop", fields: [:], requiredCapability: .playback)
        case .nextTrack:
            return ServiceInvocation(domain: "media_player", name: "media_next_track", fields: [:], requiredCapability: .playback)
        case .previousTrack:
            return ServiceInvocation(domain: "media_player", name: "media_previous_track", fields: [:], requiredCapability: .playback)
        case .setMuted(let muted):
            return ServiceInvocation(domain: "media_player", name: "volume_mute", fields: ["is_volume_muted": .bool(muted)], requiredCapability: .volume)
        case .setVolume(let percent):
            try validatePercent(percent)
            return ServiceInvocation(domain: "media_player", name: "volume_set", fields: ["volume_level": .number(Double(percent) / 100.0)], requiredCapability: .volume)
        case .playMedia(let contentID, let contentType):
            guard !contentID.isEmpty, !contentType.isEmpty else {
                throw HomeControlError.invalidValue("Media content and its type are required.")
            }
            return ServiceInvocation(
                domain: "media_player",
                name: "play_media",
                fields: ["media_content_id": .string(contentID), "media_content_type": .string(contentType)],
                requiredCapability: .playback
            )
        }
    }

    private static func coverInvocation(action: CoverAction) throws -> ServiceInvocation {
        switch action {
        case .open:
            return ServiceInvocation(domain: "cover", name: "open_cover", fields: [:], requiredCapability: .openClose)
        case .close:
            return ServiceInvocation(domain: "cover", name: "close_cover", fields: [:], requiredCapability: .openClose)
        case .stop:
            return ServiceInvocation(domain: "cover", name: "stop_cover", fields: [:], requiredCapability: .openClose)
        case .setPosition(let percent):
            try validatePercent(percent)
            return ServiceInvocation(domain: "cover", name: "set_cover_position", fields: ["position": .number(Double(percent))], requiredCapability: .position)
        }
    }

    private static func isConfirmed(_ command: HomeCommand, by state: DeviceState) -> Bool {
        guard state.isAvailable else { return false }
        switch command {
        case .turnOn:
            return state.isOn == true
        case .turnOff:
            return state.isOn == false
        case .setBrightness(_, let percent):
            return approximately(state.brightnessPercent, percent, tolerance: 3)
        case .setColor(_, let requested):
            guard let actual = state.color else { return false }
            return abs(actual.red - requested.red) <= 8 &&
                abs(actual.green - requested.green) <= 8 &&
                abs(actual.blue - requested.blue) <= 8
        case .setColorTemperature(_, let kelvin):
            guard let actual = state.colorTemperatureKelvin else { return false }
            return abs(actual - kelvin) <= max(75, kelvin / 25)
        case .setFanSpeed(_, let percent):
            return approximately(state.fanSpeedPercent, percent, tolerance: 3)
        case .setTemperature(_, let celsius):
            guard let actual = state.targetTemperatureCelsius else { return false }
            return abs(actual - celsius) <= 0.25
        case .setHVACMode(_, let mode):
            return state.hvacMode == mode.lowercased().replacingOccurrences(of: " ", with: "_")
        case .activateScene, .runScript:
            return true
        case .media(_, let action):
            switch action {
            case .play: return state.mediaState == "playing"
            case .pause: return state.mediaState == "paused"
            case .stop: return ["idle", "off", "standby"].contains(state.mediaState ?? "")
            case .setMuted(let muted): return state.isMuted == muted
            case .setVolume(let percent): return approximately(state.volumePercent, percent, tolerance: 2)
            case .nextTrack, .previousTrack, .playMedia: return true
            }
        case .cover(_, let action):
            switch action {
            case .open: return state.rawState == "open" || state.rawState == "opening"
            case .close: return state.rawState == "closed" || state.rawState == "closing"
            case .stop: return state.rawState != "opening" && state.rawState != "closing"
            case .setPosition(let percent):
                if approximately(state.coverPositionPercent, percent, tolerance: 3) { return true }
                return state.rawState == "opening" || state.rawState == "closing"
            }
        case .lock:
            return state.rawState == "locked" || state.rawState == "locking"
        case .unlock:
            return state.rawState == "unlocked" || state.rawState == "unlocking"
        case .alarm(_, let action, _):
            switch action {
            case .armHome: return state.rawState == "armed_home" || state.rawState == "arming"
            case .armAway: return state.rawState == "armed_away" || state.rawState == "arming"
            case .armNight: return state.rawState == "armed_night" || state.rawState == "arming"
            case .disarm: return state.rawState == "disarmed" || state.rawState == "pending"
            case .trigger: return state.rawState == "triggered"
            }
        case .confirmed(let inner):
            return isConfirmed(inner.commandAfterConfirmation, by: state)
        }
    }

    private static func capabilities(
        for domain: String,
        type: DeviceType,
        attributes: [String: JSONValue]
    ) -> Set<DeviceCapability> {
        var values: Set<DeviceCapability> = [.queryState]
        let supportedFeatures = Int(attributes["supported_features"]?.doubleValue ?? 0)
        switch domain {
        case "light":
            values.insert(.power)
            let modes = Set(attributes["supported_color_modes"]?.stringArrayValue ?? [])
            if !modes.isDisjoint(with: ["brightness", "color_temp", "hs", "xy", "rgb", "rgbw", "rgbww", "white"]) || supportedFeatures & 1 != 0 {
                values.insert(.brightness)
            }
            if !modes.isDisjoint(with: ["hs", "xy", "rgb", "rgbw", "rgbww"]) || supportedFeatures & 16 != 0 {
                values.insert(.color)
            }
            if modes.contains("color_temp") || supportedFeatures & 2 != 0 {
                values.insert(.colorTemperature)
            }
        case "switch":
            values.insert(.power)
        case "fan":
            values.formUnion([.power, .fanSpeed])
        case "climate":
            values.formUnion([.targetTemperature, .hvacMode])
        case "scene", "script":
            values.insert(.activate)
        case "media_player":
            values.formUnion([.power, .playback, .volume])
        case "cover":
            values.insert(.openClose)
            if supportedFeatures & 4 != 0 || attributes["current_position"] != nil {
                values.insert(.position)
            }
        case "lock":
            values.formUnion([.lock, .unlock])
        case "alarm_control_panel":
            values.formUnion([.arm, .disarm])
        default:
            break
        }
        return values
    }

    private static func explicitRoom(in attributes: [String: JSONValue]) -> String? {
        for key in ["area_name", "room_name", "room", "area"] {
            if let room = attributes[key]?.stringValue?.nonEmpty { return room }
        }
        return nil
    }

    private static func inferredRoom(from name: String) -> String? {
        let lowercased = name.lowercased()
        let rooms = [
            "living room", "dining room", "bedroom", "office", "kitchen",
            "bathroom", "garage", "hallway", "basement", "attic", "patio"
        ]
        guard let room = rooms.first(where: { lowercased.contains($0) }) else { return nil }
        return room.capitalized
    }

    private static func domainName(for entityID: String) -> String {
        entityID.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
    }

    private static func requireDomain(_ expected: String, actual: String, device: SmartDevice) throws {
        guard actual == expected else {
            throw HomeControlError.unsupportedCommand("That action is not supported by \(device.name).")
        }
    }

    private static func validatePercent(_ value: Int) throws {
        guard (0...100).contains(value) else {
            throw HomeControlError.invalidValue("Percentage values must be between 0 and 100.")
        }
    }

    private static func boundedPercent(_ value: Double) -> Int {
        min(100, max(0, Int(value.rounded())))
    }

    private static func approximately(_ actual: Int?, _ requested: Int, tolerance: Int) -> Bool {
        guard let actual = actual else { return false }
        return abs(actual - requested) <= tolerance
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value = value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
