import Foundation

enum DeviceType: String, Codable, CaseIterable {
    case light
    case switchDevice = "switch"
    case outlet
    case fan
    case thermostat
    case scene
    case script
    case mediaPlayer = "media_player"
    case cover
    case lock
    case garageDoor = "garage_door"
    case alarm
    case sensor
    case unknown

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .switchDevice: return "Switch"
        case .outlet: return "Outlet"
        case .fan: return "Fan"
        case .thermostat: return "Thermostat"
        case .scene: return "Scene"
        case .script: return "Script"
        case .mediaPlayer: return "Media Player"
        case .cover: return "Cover"
        case .lock: return "Lock"
        case .garageDoor: return "Garage Door"
        case .alarm: return "Alarm"
        case .sensor: return "Sensor"
        case .unknown: return "Device"
        }
    }
}

enum DeviceCapability: String, Codable, CaseIterable, Hashable {
    case queryState = "query_state"
    case power
    case brightness
    case color
    case colorTemperature = "color_temperature"
    case fanSpeed = "fan_speed"
    case targetTemperature = "target_temperature"
    case hvacMode = "hvac_mode"
    case activate
    case playback
    case volume
    case openClose = "open_close"
    case position
    case lock
    case unlock
    case arm
    case disarm
}

struct SmartDevice: Codable, Hashable {
    let id: String
    let name: String
    let room: String?
    let type: DeviceType
    let capabilities: Set<DeviceCapability>

    init(
        id: String,
        name: String,
        room: String? = nil,
        type: DeviceType,
        capabilities: Set<DeviceCapability>
    ) {
        self.id = id
        self.name = name
        self.room = room
        self.type = type
        self.capabilities = capabilities
    }
}

struct LightColor: Codable, Hashable {
    let red: Int
    let green: Int
    let blue: Int

    init(red: Int, green: Int, blue: Int) {
        self.red = min(255, max(0, red))
        self.green = min(255, max(0, green))
        self.blue = min(255, max(0, blue))
    }
}

struct DeviceState: Codable, Hashable {
    var deviceID: String
    var rawState: String
    var isAvailable: Bool
    var isOn: Bool?
    var brightnessPercent: Int?
    var color: LightColor?
    var colorTemperatureKelvin: Int?
    var fanSpeedPercent: Int?
    var currentTemperatureCelsius: Double?
    var targetTemperatureCelsius: Double?
    var hvacMode: String?
    var mediaState: String?
    var volumePercent: Int?
    var isMuted: Bool?
    var coverPositionPercent: Int?
    var lastUpdated: Date?

    init(
        deviceID: String,
        rawState: String,
        isAvailable: Bool = true,
        isOn: Bool? = nil,
        brightnessPercent: Int? = nil,
        color: LightColor? = nil,
        colorTemperatureKelvin: Int? = nil,
        fanSpeedPercent: Int? = nil,
        currentTemperatureCelsius: Double? = nil,
        targetTemperatureCelsius: Double? = nil,
        hvacMode: String? = nil,
        mediaState: String? = nil,
        volumePercent: Int? = nil,
        isMuted: Bool? = nil,
        coverPositionPercent: Int? = nil,
        lastUpdated: Date? = nil
    ) {
        self.deviceID = deviceID
        self.rawState = rawState
        self.isAvailable = isAvailable
        self.isOn = isOn
        self.brightnessPercent = brightnessPercent
        self.color = color
        self.colorTemperatureKelvin = colorTemperatureKelvin
        self.fanSpeedPercent = fanSpeedPercent
        self.currentTemperatureCelsius = currentTemperatureCelsius
        self.targetTemperatureCelsius = targetTemperatureCelsius
        self.hvacMode = hvacMode
        self.mediaState = mediaState
        self.volumePercent = volumePercent
        self.isMuted = isMuted
        self.coverPositionPercent = coverPositionPercent
        self.lastUpdated = lastUpdated
    }
}
