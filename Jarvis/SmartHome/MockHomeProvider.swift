import Foundation

actor MockHomeProvider: HomeControlProvider {
    private var devicesByID: [String: SmartDevice]
    private var statesByID: [String: DeviceState]

    init(devices: [SmartDevice] = [], states: [String: DeviceState] = [:]) {
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        statesByID = states
        for device in devices where statesByID[device.id] == nil {
            statesByID[device.id] = DeviceState(
                deviceID: device.id,
                rawState: "off",
                isOn: device.capabilities.contains(.power) ? false : nil
            )
        }
    }

    func listDevices() async throws -> [SmartDevice] {
        devicesByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func getState(deviceID: String) async throws -> DeviceState {
        guard let state = statesByID[deviceID] else {
            throw HomeControlError.deviceNotFound(deviceID)
        }
        return state
    }

    func execute(command: HomeCommand) async throws {
        if command.requiresConfirmation {
            throw HomeControlError.confirmationRequired(
                command.confirmationPrompt ?? "This smart-home action needs confirmation."
            )
        }
        let executable = command.commandAfterConfirmation
        guard let device = devicesByID[executable.deviceID],
              var state = statesByID[executable.deviceID] else {
            throw HomeControlError.deviceNotFound(executable.deviceID)
        }

        switch executable {
        case .turnOn:
            try require(.power, for: device)
            state.rawState = "on"; state.isOn = true
        case .turnOff:
            try require(.power, for: device)
            state.rawState = "off"; state.isOn = false
        case .setBrightness(_, let percent):
            try require(.brightness, for: device); try validatePercent(percent)
            state.rawState = "on"; state.isOn = true; state.brightnessPercent = percent
        case .setColor(_, let color):
            try require(.color, for: device)
            state.rawState = "on"; state.isOn = true; state.color = color
        case .setColorTemperature(_, let kelvin):
            try require(.colorTemperature, for: device)
            guard (1_000...40_000).contains(kelvin) else {
                throw HomeControlError.invalidValue("Color temperature must be between 1,000 K and 40,000 K.")
            }
            state.rawState = "on"; state.isOn = true; state.colorTemperatureKelvin = kelvin
        case .setFanSpeed(_, let percent):
            try require(.fanSpeed, for: device); try validatePercent(percent)
            state.rawState = percent == 0 ? "off" : "on"; state.isOn = percent > 0; state.fanSpeedPercent = percent
        case .setTemperature(_, let celsius):
            try require(.targetTemperature, for: device)
            guard celsius.isFinite else { throw HomeControlError.invalidValue("Temperature must be a number.") }
            state.targetTemperatureCelsius = celsius
        case .setHVACMode(_, let mode):
            try require(.hvacMode, for: device)
            state.rawState = mode.lowercased().replacingOccurrences(of: " ", with: "_")
            state.hvacMode = state.rawState
        case .activateScene, .runScript:
            try require(.activate, for: device); state.rawState = "active"
        case .media(_, let action):
            switch action {
            case .play, .playMedia: state.rawState = "playing"; state.mediaState = "playing"; state.isOn = true
            case .pause: state.rawState = "paused"; state.mediaState = "paused"
            case .stop: state.rawState = "idle"; state.mediaState = "idle"
            case .nextTrack, .previousTrack: break
            case .setMuted(let muted): state.isMuted = muted
            case .setVolume(let percent): try validatePercent(percent); state.volumePercent = percent
            }
        case .cover(_, let action):
            switch action {
            case .open: state.rawState = "open"; state.isOn = true; state.coverPositionPercent = 100
            case .close: state.rawState = "closed"; state.isOn = false; state.coverPositionPercent = 0
            case .stop: if state.rawState == "opening" || state.rawState == "closing" { state.rawState = "stopped" }
            case .setPosition(let percent): try validatePercent(percent); state.coverPositionPercent = percent; state.rawState = percent == 0 ? "closed" : "open"
            }
        case .lock:
            try require(.lock, for: device); state.rawState = "locked"
        case .unlock:
            try require(.unlock, for: device); state.rawState = "unlocked"
        case .alarm(_, let action, _):
            switch action {
            case .armHome: state.rawState = "armed_home"
            case .armAway: state.rawState = "armed_away"
            case .armNight: state.rawState = "armed_night"
            case .disarm: state.rawState = "disarmed"
            case .trigger: state.rawState = "triggered"
            }
        case .confirmed(let inner):
            try await execute(command: inner.commandAfterConfirmation)
            return
        }
        state.lastUpdated = Date()
        statesByID[device.id] = state
    }

    func replace(devices: [SmartDevice], states: [String: DeviceState]) {
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        statesByID = states
    }

    private func require(_ capability: DeviceCapability, for device: SmartDevice) throws {
        guard device.capabilities.contains(capability) else {
            throw HomeControlError.unsupportedCommand("\(device.name) does not support this action.")
        }
    }

    private func validatePercent(_ percent: Int) throws {
        guard (0...100).contains(percent) else {
            throw HomeControlError.invalidValue("Percentage values must be between 0 and 100.")
        }
    }
}
