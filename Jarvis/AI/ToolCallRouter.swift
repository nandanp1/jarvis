import Foundation

final class ToolCallRouter {
    private let homeProvider: HomeControlProvider
    private let resolver: DeviceResolver
    private let routineExecutor: RoutineExecutor
    private let macCommands: MacCommandService
    private let queue = DispatchQueue(label: "com.nandan.jarvis.tool-confirmation")
    private var pendingCommand: HomeCommand?
    private var pendingCommandDescription: String?
    private var pendingExpiry: DispatchWorkItem?

    init(
        homeProvider: HomeControlProvider,
        resolver: DeviceResolver = DeviceResolver(),
        routineExecutor: RoutineExecutor,
        macCommands: MacCommandService
    ) {
        self.homeProvider = homeProvider
        self.resolver = resolver
        self.routineExecutor = routineExecutor
        self.macCommands = macCommands
    }

    var tools: [GeminiToolDefinition] {
        let referenceProperty: [String: Any] = [
            "type": "string",
            "description": "Natural device reference such as bedroom ceiling light, desk lamp, or fan"
        ]
        let referenceSchema: [String: Any] = [
            "type": "object",
            "properties": ["device": referenceProperty],
            "required": ["device"]
        ]

        return [
            GeminiToolDefinition(name: "list_home_devices", description: "Lists real devices currently available through Home Assistant.", parameters: ["type": "object", "properties": [:]]),
            GeminiToolDefinition(name: "get_device_state", description: "Gets the current state of one real smart-home device.", parameters: referenceSchema),
            GeminiToolDefinition(name: "turn_on_device", description: "Turns a real smart-home device on.", parameters: referenceSchema),
            GeminiToolDefinition(name: "turn_off_device", description: "Turns a real smart-home device off.", parameters: referenceSchema),
            GeminiToolDefinition(name: "set_light_brightness", description: "Sets a real light brightness from 0 to 100 percent.", parameters: ["type": "object", "properties": ["device": referenceProperty, "percent": ["type": "integer", "minimum": 0, "maximum": 100]], "required": ["device", "percent"]]),
            GeminiToolDefinition(name: "set_light_color", description: "Sets a real light to an RGB color.", parameters: ["type": "object", "properties": ["device": referenceProperty, "red": ["type": "integer", "minimum": 0, "maximum": 255], "green": ["type": "integer", "minimum": 0, "maximum": 255], "blue": ["type": "integer", "minimum": 0, "maximum": 255]], "required": ["device", "red", "green", "blue"]]),
            GeminiToolDefinition(name: "set_light_color_temperature", description: "Sets a real light color temperature in Kelvin.", parameters: ["type": "object", "properties": ["device": referenceProperty, "kelvin": ["type": "integer", "minimum": 1000, "maximum": 40000]], "required": ["device", "kelvin"]]),
            GeminiToolDefinition(name: "set_fan_speed", description: "Sets a fan speed from 0 to 100 percent.", parameters: ["type": "object", "properties": ["device": referenceProperty, "percent": ["type": "integer", "minimum": 0, "maximum": 100]], "required": ["device", "percent"]]),
            GeminiToolDefinition(name: "set_temperature", description: "Sets a thermostat target temperature in Celsius.", parameters: ["type": "object", "properties": ["device": referenceProperty, "celsius": ["type": "number"]], "required": ["device", "celsius"]]),
            GeminiToolDefinition(name: "set_hvac_mode", description: "Sets a thermostat HVAC mode such as heat, cool, auto, or off.", parameters: ["type": "object", "properties": ["device": referenceProperty, "mode": ["type": "string"]], "required": ["device", "mode"]]),
            GeminiToolDefinition(name: "activate_scene", description: "Activates a Home Assistant scene.", parameters: referenceSchema),
            GeminiToolDefinition(name: "run_home_script", description: "Runs a Home Assistant script.", parameters: referenceSchema),
            GeminiToolDefinition(name: "control_media_player", description: "Controls a Home Assistant media player. Volume requires percent.", parameters: ["type": "object", "properties": ["device": referenceProperty, "action": ["type": "string", "enum": ["play", "pause", "stop", "next", "previous", "mute", "unmute", "volume"]], "percent": ["type": "integer", "minimum": 0, "maximum": 100]], "required": ["device", "action"]]),
            GeminiToolDefinition(name: "control_cover", description: "Opens, closes, stops, or positions a cover. Opening requires user confirmation because the entity may be an access door.", parameters: ["type": "object", "properties": ["device": referenceProperty, "action": ["type": "string", "enum": ["open", "close", "stop", "position"]], "percent": ["type": "integer", "minimum": 0, "maximum": 100]], "required": ["device", "action"]]),
            GeminiToolDefinition(name: "lock_device", description: "Locks a smart lock.", parameters: referenceSchema),
            GeminiToolDefinition(name: "unlock_device", description: "Requests unlocking a smart lock. Jarvis always asks the user for explicit confirmation before execution.", parameters: referenceSchema),
            GeminiToolDefinition(name: "control_alarm", description: "Arms, disarms, or triggers an alarm control panel. Disarm and trigger always require confirmation.", parameters: ["type": "object", "properties": ["device": referenceProperty, "action": ["type": "string", "enum": ["arm_home", "arm_away", "arm_night", "disarm", "trigger"]], "code": ["type": "string"]], "required": ["device", "action"]]),
            GeminiToolDefinition(name: "run_routine", description: "Runs a configured Jarvis routine such as Goodnight, Gaming, Movie, Study, Wake Up, or Away.", parameters: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]),
            GeminiToolDefinition(name: "set_mac_volume", description: "Sets this Mac's output volume from 0 to 100 percent.", parameters: ["type": "object", "properties": ["percent": ["type": "integer", "minimum": 0, "maximum": 100]], "required": ["percent"]]),
            GeminiToolDefinition(name: "mute_mac", description: "Mutes or unmutes this Mac.", parameters: ["type": "object", "properties": ["muted": ["type": "boolean"]], "required": ["muted"]]),
            GeminiToolDefinition(name: "open_mac_application", description: "Opens an installed Mac application by name through the allowlisted Mac command service.", parameters: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]])
        ]
    }

    func execute(_ call: GeminiFunctionCall) async -> GeminiToolExecutionResult {
        do {
            switch call.name {
            case "list_home_devices":
                let devices = try await homeProvider.listDevices()
                let descriptions = devices.map { device -> [String: Any] in
                    ["id": device.id, "name": device.name, "room": device.room ?? "", "type": device.type.rawValue]
                }
                return .init(success: true, message: "Found \(devices.count) devices.", data: ["devices": descriptions])
            case "get_device_state":
                let device = try await resolveDevice(arguments: call.arguments)
                let state = try await homeProvider.getState(deviceID: device.id)
                resolver.recordUsage(of: device)
                return .init(success: true, message: "Read \(device.name).", data: stateData(state))
            case "turn_on_device":
                return try await executeHome(.turnOn(deviceID: resolveDeviceID(call.arguments)), description: "turn on the device")
            case "turn_off_device":
                return try await executeHome(.turnOff(deviceID: resolveDeviceID(call.arguments)), description: "turn off the device")
            case "set_light_brightness":
                return try await executeHome(.setBrightness(deviceID: resolveDeviceID(call.arguments), percent: try integer("percent", in: call.arguments)), description: "set the brightness")
            case "set_light_color":
                let color = LightColor(red: try integer("red", in: call.arguments), green: try integer("green", in: call.arguments), blue: try integer("blue", in: call.arguments))
                return try await executeHome(.setColor(deviceID: resolveDeviceID(call.arguments), color: color), description: "set the light color")
            case "set_light_color_temperature":
                return try await executeHome(.setColorTemperature(deviceID: resolveDeviceID(call.arguments), kelvin: try integer("kelvin", in: call.arguments)), description: "set the color temperature")
            case "set_fan_speed":
                return try await executeHome(.setFanSpeed(deviceID: resolveDeviceID(call.arguments), percent: try integer("percent", in: call.arguments)), description: "set the fan speed")
            case "set_temperature":
                return try await executeHome(.setTemperature(deviceID: resolveDeviceID(call.arguments), celsius: try number("celsius", in: call.arguments)), description: "set the thermostat")
            case "set_hvac_mode":
                return try await executeHome(.setHVACMode(deviceID: resolveDeviceID(call.arguments), mode: try string("mode", in: call.arguments)), description: "set the thermostat mode")
            case "activate_scene":
                return try await executeHome(.activateScene(deviceID: resolveDeviceID(call.arguments)), description: "activate the scene")
            case "run_home_script":
                return try await executeHome(.runScript(deviceID: resolveDeviceID(call.arguments)), description: "run the script")
            case "control_media_player":
                let actionName = try string("action", in: call.arguments)
                let action: MediaAction
                switch actionName {
                case "play": action = .play
                case "pause": action = .pause
                case "stop": action = .stop
                case "next": action = .nextTrack
                case "previous": action = .previousTrack
                case "mute": action = .setMuted(true)
                case "unmute": action = .setMuted(false)
                case "volume": action = .setVolume(percent: try integer("percent", in: call.arguments))
                default: throw GeminiError.invalidRequest
                }
                return try await executeHome(.media(deviceID: resolveDeviceID(call.arguments), action: action), description: "control the media player")
            case "control_cover":
                let actionName = try string("action", in: call.arguments)
                let action: CoverAction
                switch actionName {
                case "open": action = .open
                case "close": action = .close
                case "stop": action = .stop
                case "position": action = .setPosition(percent: try integer("percent", in: call.arguments))
                default: throw GeminiError.invalidRequest
                }
                return try await executeHome(.cover(deviceID: resolveDeviceID(call.arguments), action: action), description: "control the cover")
            case "lock_device":
                return try await executeHome(.lock(deviceID: resolveDeviceID(call.arguments)), description: "lock the device")
            case "unlock_device":
                return try await executeHome(.unlock(deviceID: resolveDeviceID(call.arguments)), description: "unlock the device")
            case "control_alarm":
                let actionName = try string("action", in: call.arguments)
                let action: AlarmAction
                switch actionName {
                case "arm_home": action = .armHome
                case "arm_away": action = .armAway
                case "arm_night": action = .armNight
                case "disarm": action = .disarm
                case "trigger": action = .trigger
                default: throw GeminiError.invalidRequest
                }
                return try await executeHome(.alarm(deviceID: resolveDeviceID(call.arguments), action: action, code: call.arguments["code"] as? String), description: "control the alarm")
            case "run_routine":
                let name = try string("name", in: call.arguments)
                let report = try await executeRoutine(named: name)
                return .init(success: report.succeeded, message: report.spokenMessage)
            case "set_mac_volume":
                _ = try await macCommands.execute(.setVolume(percent: try integer("percent", in: call.arguments)))
                return .init(success: true, message: "Mac volume changed.")
            case "mute_mac":
                _ = try await macCommands.execute(try bool("muted", in: call.arguments) ? .mute : .unmute)
                return .init(success: true, message: "Mac mute state changed.")
            case "open_mac_application":
                let name = try string("name", in: call.arguments)
                guard let application = application(named: name) else {
                    throw HomeControlError.unsupportedCommand("\(name) is not on Jarvis's application allowlist.")
                }
                _ = try await macCommands.execute(.openApplication(application))
                return .init(success: true, message: "Application opened.")
            default:
                return .init(success: false, message: "Jarvis does not allow the requested tool \(call.name).")
            }
        } catch {
            if case HomeControlError.confirmationRequired(let prompt) = error {
                return .init(success: false, message: prompt, data: ["requires_confirmation": true])
            }
            return .init(success: false, message: error.localizedDescription)
        }
    }

    func executeLocal(_ intents: [LocalIntent]) async throws -> String {
        guard !intents.isEmpty else {
            throw HomeControlError.unsupportedCommand("I couldn’t match that to an offline command.")
        }
        var messages: [String] = []
        for intent in intents {
            switch intent {
            case .power(let reference, let on, let all):
                let devices = try await homeProvider.listDevices()
                let matches = all
                    ? resolver.resolveAll(reference, among: devices).filter { $0.capabilities.contains(.power) }
                    : resolver.resolve(reference, among: devices).map { [$0] } ?? []
                guard !matches.isEmpty else { throw HomeControlError.deviceNotFound(reference) }
                for device in matches {
                    try await homeProvider.execute(command: on ? .turnOn(deviceID: device.id) : .turnOff(deviceID: device.id))
                    resolver.recordUsage(of: device)
                }
                messages.append("Turned \(matches.count == 1 ? matches[0].name : "\(matches.count) devices") \(on ? "on" : "off").")
            case .brightness(let reference, let percent):
                let device = try await resolveDevice(reference: reference)
                try await homeProvider.execute(command: .setBrightness(deviceID: device.id, percent: percent))
                resolver.recordUsage(of: device)
                messages.append("Set \(device.name) to \(percent) percent.")
            case .fan(let reference, let on):
                let device = try await resolveDevice(reference: reference)
                try await homeProvider.execute(command: on ? .turnOn(deviceID: device.id) : .turnOff(deviceID: device.id))
                resolver.recordUsage(of: device)
                messages.append("Turned \(device.name) \(on ? "on" : "off").")
            case .routine(let name):
                let report = try await executeRoutine(named: name)
                messages.append(report.spokenMessage)
            case .macVolume(let percent):
                _ = try await macCommands.execute(.setVolume(percent: percent))
                messages.append("Set Mac volume to \(percent) percent.")
            case .macMute(let muted):
                _ = try await macCommands.execute(muted ? .mute : .unmute)
                messages.append(muted ? "Muted the Mac." : "Unmuted the Mac.")
            }
        }
        return messages.joined(separator: " ")
    }

    func confirmPendingAction(confirmed: Bool) async -> GeminiToolExecutionResult? {
        let pending: (HomeCommand, String)? = queue.sync {
            defer {
                pendingExpiry?.cancel()
                pendingExpiry = nil
                pendingCommand = nil
                pendingCommandDescription = nil
            }
            guard let command = pendingCommand else { return nil }
            return (command, pendingCommandDescription ?? "perform the action")
        }
        guard let pending = pending else { return nil }
        guard confirmed else { return .init(success: false, message: "Cancelled.") }
        do {
            try await homeProvider.execute(command: pending.0.confirmedByUser())
            return .init(success: true, message: "Confirmed and completed: \(pending.1).")
        } catch {
            return .init(success: false, message: error.localizedDescription)
        }
    }

    var hasPendingConfirmation: Bool { queue.sync { pendingCommand != nil } }

    func cancelPendingAction() {
        queue.sync {
            pendingExpiry?.cancel()
            pendingExpiry = nil
            pendingCommand = nil
            pendingCommandDescription = nil
        }
    }

    private func executeHome(_ unresolvedCommand: HomeCommand, description: String) async throws -> GeminiToolExecutionResult {
        let device = try await resolveDevice(reference: unresolvedCommand.deviceID)
        let command = replacingDeviceID(in: unresolvedCommand, with: device.id)
        if command.requiresConfirmation {
            queue.sync {
                pendingExpiry?.cancel()
                pendingCommand = command
                pendingCommandDescription = "\(description) for \(device.name)"
                let expiry = DispatchWorkItem { [weak self] in
                    self?.pendingCommand = nil
                    self?.pendingCommandDescription = nil
                    self?.pendingExpiry = nil
                }
                pendingExpiry = expiry
                queue.asyncAfter(deadline: .now() + 30, execute: expiry)
            }
            throw HomeControlError.confirmationRequired(command.confirmationPrompt ?? "Please confirm this action.")
        }
        try await homeProvider.execute(command: command)
        resolver.recordUsage(of: device)
        let refreshed = try await homeProvider.getState(deviceID: device.id)
        return .init(success: true, message: "\(device.name) updated successfully.", data: stateData(refreshed))
    }

    private func resolveDeviceID(_ arguments: [String: Any]) throws -> String {
        try string("device", in: arguments)
    }

    private func resolveDevice(arguments: [String: Any]) async throws -> SmartDevice {
        try await resolveDevice(reference: string("device", in: arguments))
    }

    private func resolveDevice(reference: String) async throws -> SmartDevice {
        let devices = try await homeProvider.listDevices()
        guard let device = resolver.resolve(reference, among: devices) ?? devices.first(where: { $0.id == reference }) else {
            throw HomeControlError.deviceNotFound(reference)
        }
        return device
    }

    private func replacingDeviceID(in command: HomeCommand, with id: String) -> HomeCommand {
        switch command {
        case .turnOn: return .turnOn(deviceID: id)
        case .turnOff: return .turnOff(deviceID: id)
        case .setBrightness(_, let value): return .setBrightness(deviceID: id, percent: value)
        case .setColor(_, let value): return .setColor(deviceID: id, color: value)
        case .setColorTemperature(_, let value): return .setColorTemperature(deviceID: id, kelvin: value)
        case .setFanSpeed(_, let value): return .setFanSpeed(deviceID: id, percent: value)
        case .setTemperature(_, let value): return .setTemperature(deviceID: id, celsius: value)
        case .setHVACMode(_, let value): return .setHVACMode(deviceID: id, mode: value)
        case .activateScene: return .activateScene(deviceID: id)
        case .runScript: return .runScript(deviceID: id)
        case .media(_, let action): return .media(deviceID: id, action: action)
        case .cover(_, let action): return .cover(deviceID: id, action: action)
        case .lock: return .lock(deviceID: id)
        case .unlock: return .unlock(deviceID: id)
        case .alarm(_, let action, let code): return .alarm(deviceID: id, action: action, code: code)
        case .confirmed(let command): return .confirmed(replacingDeviceID(in: command, with: id))
        }
    }

    private func stateData(_ state: DeviceState) -> [String: Any] {
        var result: [String: Any] = ["device_id": state.deviceID, "state": state.rawState, "available": state.isAvailable]
        if let value = state.isOn { result["is_on"] = value }
        if let value = state.brightnessPercent { result["brightness_percent"] = value }
        if let value = state.fanSpeedPercent { result["fan_speed_percent"] = value }
        if let value = state.currentTemperatureCelsius { result["current_temperature_celsius"] = value }
        if let value = state.targetTemperatureCelsius { result["target_temperature_celsius"] = value }
        return result
    }

    private func executeRoutine(named rawName: String) async throws -> RoutineExecutionResult {
        let normalized = rawName.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let routine = DefaultRoutines.all.first(where: { routine in
            routine.id.replacingOccurrences(of: "_", with: " ") == normalized ||
                routine.name.lowercased() == normalized ||
                routine.invocationPhrases.contains(where: { $0.lowercased() == normalized })
        }) else {
            throw HomeControlError.unsupportedCommand("I couldn't find a \(rawName) routine.")
        }
        return try await routineExecutor.execute(routine, policy: .continueAfterFailure)
    }

    private func application(named rawName: String) -> MacApplication? {
        let normalized = rawName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return MacApplication.allCases.first {
            $0.displayName.lowercased() == normalized ||
                $0.rawValue.lowercased() == normalized ||
                String(describing: $0).lowercased() == normalized
        }
    }

    private func string(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.invalidRequest
        }
        return value
    }

    private func integer(_ key: String, in arguments: [String: Any]) throws -> Int {
        if let value = arguments[key] as? Int { return value }
        if let value = arguments[key] as? NSNumber { return value.intValue }
        throw GeminiError.invalidRequest
    }

    private func number(_ key: String, in arguments: [String: Any]) throws -> Double {
        if let value = arguments[key] as? Double { return value }
        if let value = arguments[key] as? NSNumber { return value.doubleValue }
        throw GeminiError.invalidRequest
    }

    private func bool(_ key: String, in arguments: [String: Any]) throws -> Bool {
        if let value = arguments[key] as? Bool { return value }
        if let value = arguments[key] as? NSNumber { return value.boolValue }
        throw GeminiError.invalidRequest
    }
}
