import Foundation

enum MediaAction: Hashable {
    case play
    case pause
    case stop
    case nextTrack
    case previousTrack
    case setMuted(Bool)
    case setVolume(percent: Int)
    case playMedia(contentID: String, contentType: String)
}

enum CoverAction: Hashable {
    case open
    case close
    case stop
    case setPosition(percent: Int)
}

enum AlarmAction: String, Codable, Hashable {
    case armHome = "arm_home"
    case armAway = "arm_away"
    case armNight = "arm_night"
    case disarm
    case trigger
}

enum SensitiveAction: String, Codable, Hashable {
    case unlockDoor = "unlock_door"
    case openAccessCover = "open_access_cover"
    case disableAlarm = "disable_alarm"
    case triggerAlarm = "trigger_alarm"
    case runAutomation = "run_automation"
}

indirect enum HomeCommand: Hashable {
    case turnOn(deviceID: String)
    case turnOff(deviceID: String)
    case setBrightness(deviceID: String, percent: Int)
    case setColor(deviceID: String, color: LightColor)
    case setColorTemperature(deviceID: String, kelvin: Int)
    case setFanSpeed(deviceID: String, percent: Int)
    case setTemperature(deviceID: String, celsius: Double)
    case setHVACMode(deviceID: String, mode: String)
    case activateScene(deviceID: String)
    case runScript(deviceID: String)
    case media(deviceID: String, action: MediaAction)
    case cover(deviceID: String, action: CoverAction)
    case lock(deviceID: String)
    case unlock(deviceID: String)
    case alarm(deviceID: String, action: AlarmAction, code: String?)

    /// This wrapper is deliberately not exposed as a Gemini tool argument. The
    /// assistant creates it only after the user explicitly confirms the pending
    /// action.
    case confirmed(HomeCommand)

    var deviceID: String {
        switch self {
        case .turnOn(let id), .turnOff(let id), .setBrightness(let id, _),
             .setColor(let id, _), .setColorTemperature(let id, _),
             .setFanSpeed(let id, _), .setTemperature(let id, _),
             .setHVACMode(let id, _), .activateScene(let id), .runScript(let id),
             .media(let id, _), .cover(let id, _), .lock(let id), .unlock(let id),
             .alarm(let id, _, _):
            return id
        case .confirmed(let command):
            return command.deviceID
        }
    }

    var sensitiveAction: SensitiveAction? {
        switch self {
        case .unlock:
            return .unlockDoor
        case .cover(_, .open):
            return .openAccessCover
        case .cover(_, .setPosition):
            return .openAccessCover
        case .activateScene, .runScript:
            // Scenes and scripts can contain lock, garage, or alarm actions.
            // Without a user-reviewed allowlist, confirmation is the safe default.
            return .runAutomation
        case .alarm(_, .disarm, _):
            return .disableAlarm
        case .alarm(_, .trigger, _):
            return .triggerAlarm
        case .confirmed:
            return nil
        default:
            return nil
        }
    }

    var requiresConfirmation: Bool {
        sensitiveAction != nil
    }

    var confirmationPrompt: String? {
        switch sensitiveAction {
        case .unlockDoor:
            return "Are you sure you want me to unlock this door?"
        case .openAccessCover:
            return "Are you sure you want me to move this cover or garage door?"
        case .disableAlarm:
            return "Are you sure you want me to disable the alarm?"
        case .triggerAlarm:
            return "Are you sure you want me to trigger the alarm?"
        case .runAutomation:
            switch self {
            case .activateScene:
                return "Are you sure you want me to activate this scene? It may contain security actions."
            case .runScript:
                return "Are you sure you want me to run this Home Assistant script? It may contain security actions."
            default:
                return "Are you sure you want me to run this Home Assistant automation?"
            }
        case nil:
            return nil
        }
    }

    func confirmedByUser() -> HomeCommand {
        requiresConfirmation ? .confirmed(self) : self
    }

    var commandAfterConfirmation: HomeCommand {
        switch self {
        case .confirmed(let command):
            return command.commandAfterConfirmation
        default:
            return self
        }
    }
}
