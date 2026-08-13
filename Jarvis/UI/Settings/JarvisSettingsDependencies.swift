import AppKit
import Foundation

/// Non-secret values emitted after the user explicitly saves Jarvis Settings.
/// AppCoordinator can use this snapshot to immediately refresh menu-bar and
/// listening state without reaching into the settings view hierarchy.
struct JarvisSettingsSnapshot {
    let launchAtLogin: Bool
    let startListeningAutomatically: Bool
    let wakePhrase: String
    let voiceEnabled: Bool
    let voiceIdentifier: String?
    let speakingRate: Float
    let activationSoundsEnabled: Bool
    let geminiModel: String
    let homeAssistantURL: String
}

struct JarvisSettingsCallbacks {
    var onSettingsSaved: (JarvisSettingsSnapshot) -> Void
    var onClearConversation: () -> Void
    var onCredentialsCleared: () -> Void
    var onDevicesDiscovered: ([SmartDevice]) -> Void

    init(
        onSettingsSaved: @escaping (JarvisSettingsSnapshot) -> Void = { _ in },
        onClearConversation: @escaping () -> Void = {},
        onCredentialsCleared: @escaping () -> Void = {},
        onDevicesDiscovered: @escaping ([SmartDevice]) -> Void = { _ in }
    ) {
        self.onSettingsSaved = onSettingsSaved
        self.onClearConversation = onClearConversation
        self.onCredentialsCleared = onCredentialsCleared
        self.onDevicesDiscovered = onDevicesDiscovered
    }
}

/// Injectable boundary for the settings UI. Production defaults use the same
/// services as the assistant, while tests can supply deterministic async
/// connection checks without network or Keychain access.
struct JarvisSettingsDependencies {
    typealias Voice = (identifier: String, displayName: String)
    typealias GeminiConnectionTest = (_ apiKey: String, _ model: String) async throws -> String
    typealias HomeAssistantConnectionTest = (_ baseURL: String, _ accessToken: String) async throws -> [SmartDevice]

    let preferences: Preferences
    let keychain: KeychainService
    let launchAtLogin: LaunchAtLoginService
    let availableVoices: () -> [Voice]
    let testGeminiConnection: GeminiConnectionTest
    let testHomeAssistantConnection: HomeAssistantConnectionTest
    let callbacks: JarvisSettingsCallbacks

    init(
        preferences: Preferences,
        keychain: KeychainService,
        launchAtLogin: LaunchAtLoginService,
        availableVoices: @escaping () -> [Voice],
        testGeminiConnection: @escaping GeminiConnectionTest,
        testHomeAssistantConnection: @escaping HomeAssistantConnectionTest,
        callbacks: JarvisSettingsCallbacks = JarvisSettingsCallbacks()
    ) {
        self.preferences = preferences
        self.keychain = keychain
        self.launchAtLogin = launchAtLogin
        self.availableVoices = availableVoices
        self.testGeminiConnection = testGeminiConnection
        self.testHomeAssistantConnection = testHomeAssistantConnection
        self.callbacks = callbacks
    }

    static func live(
        preferences: Preferences = .shared,
        keychain: KeychainService = .shared,
        launchAtLogin: LaunchAtLoginService = LaunchAtLoginService(),
        speechSynthesis: SpeechSynthesisService = SpeechSynthesisService(),
        callbacks: JarvisSettingsCallbacks = JarvisSettingsCallbacks()
    ) -> JarvisSettingsDependencies {
        JarvisSettingsDependencies(
            preferences: preferences,
            keychain: keychain,
            launchAtLogin: launchAtLogin,
            availableVoices: { speechSynthesis.availableVoices },
            testGeminiConnection: { apiKey, model in
                let service = GeminiService(
                    apiKeyProvider: { apiKey },
                    modelProvider: { model },
                    maximumTurnsProvider: { 2 }
                )
                return try await service.testConnection()
            },
            testHomeAssistantConnection: { baseURL, accessToken in
                let service = HomeAssistantService(
                    baseURL: { baseURL },
                    accessToken: { accessToken }
                )
                try await service.testConnection()
                let provider = HomeAssistantProvider(service: service)
                return try await provider.listDevices()
            },
            callbacks: callbacks
        )
    }
}
