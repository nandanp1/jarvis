import Foundation

final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let startListeningAutomatically = "startListeningAutomatically"
        static let wakePhrase = "wakePhrase"
        static let voiceEnabled = "voiceEnabled"
        static let activationSoundsEnabled = "activationSoundsEnabled"
        static let speakingRate = "speakingRate"
        static let voiceIdentifier = "voiceIdentifier"
        static let geminiModel = "geminiModel"
        static let homeAssistantURL = "homeAssistantURL"
        static let defaultLocation = "defaultLocation"
        static let maxConversationTurns = "maxConversationTurns"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.launchAtLogin: false,
            Key.startListeningAutomatically: false,
            Key.wakePhrase: "Hey Jarvis",
            Key.voiceEnabled: true,
            Key.activationSoundsEnabled: true,
            Key.speakingRate: 175.0,
            Key.geminiModel: "gemini-3.6-flash",
            Key.homeAssistantURL: "http://homeassistant.local:8123",
            Key.defaultLocation: "",
            Key.maxConversationTurns: 12
        ])
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    var startListeningAutomatically: Bool {
        get { defaults.bool(forKey: Key.startListeningAutomatically) }
        set { defaults.set(newValue, forKey: Key.startListeningAutomatically) }
    }

    var wakePhrase: String {
        get { defaults.string(forKey: Key.wakePhrase) ?? "Hey Jarvis" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.wakePhrase) }
    }

    var voiceEnabled: Bool {
        get { defaults.bool(forKey: Key.voiceEnabled) }
        set { defaults.set(newValue, forKey: Key.voiceEnabled) }
    }

    var activationSoundsEnabled: Bool {
        get { defaults.bool(forKey: Key.activationSoundsEnabled) }
        set { defaults.set(newValue, forKey: Key.activationSoundsEnabled) }
    }

    var speakingRate: Float {
        get { Float(defaults.double(forKey: Key.speakingRate)) }
        set { defaults.set(Double(newValue), forKey: Key.speakingRate) }
    }

    var voiceIdentifier: String? {
        get { defaults.string(forKey: Key.voiceIdentifier) }
        set { defaults.set(newValue, forKey: Key.voiceIdentifier) }
    }

    var geminiModel: String {
        get { defaults.string(forKey: Key.geminiModel) ?? "gemini-3.6-flash" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.geminiModel) }
    }

    var homeAssistantURL: String {
        get { defaults.string(forKey: Key.homeAssistantURL) ?? "http://homeassistant.local:8123" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.homeAssistantURL) }
    }

    var defaultLocation: String {
        get { defaults.string(forKey: Key.defaultLocation) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.defaultLocation) }
    }

    var maxConversationTurns: Int {
        get { max(2, defaults.integer(forKey: Key.maxConversationTurns)) }
        set { defaults.set(max(2, newValue), forKey: Key.maxConversationTurns) }
    }
}
