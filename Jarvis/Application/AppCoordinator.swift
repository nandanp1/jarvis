import AppKit

final class AppCoordinator {
    private let preferences: Preferences
    private let windowController = JarvisWindowController()
    private let menuBarController = MenuBarController()
    private var state: AssistantState = .idle

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
    }

    func start() {
        configureActions()
        menuBarController.updateLaunchAtLogin(preferences.launchAtLogin)
        publishState()
        windowController.present()
        JarvisLog.info("Jarvis application started")
    }

    func shutdown() {
        JarvisLog.info("Jarvis application is shutting down")
    }

    private func configureActions() {
        let content = windowController.contentController
        content.onTalk = { [weak self] in self?.manualTalk() }
        content.onStop = { [weak self] in self?.stopListening() }
        content.onOpenSettings = { [weak self] in self?.showSettingsPlaceholder() }

        menuBarController.onTalk = { [weak self] in self?.manualTalk() }
        menuBarController.onStopListening = { [weak self] in self?.stopListening() }
        menuBarController.onOpenJarvis = { [weak self] in self?.windowController.present() }
        menuBarController.onOpenSettings = { [weak self] in self?.showSettingsPlaceholder() }
        menuBarController.onClearConversation = { [weak self] in self?.clearConversation() }
        menuBarController.onToggleLaunchAtLogin = { [weak self] enabled in
            self?.preferences.launchAtLogin = enabled
            self?.menuBarController.updateLaunchAtLogin(enabled)
        }
        menuBarController.onQuit = { NSApp.terminate(nil) }
    }

    private func manualTalk() {
        state = .listening
        publishState(detail: "Microphone services are initializing…")
    }

    private func stopListening() {
        state = .idle
        publishState()
    }

    private func clearConversation() {
        windowController.contentController.update(state: state, userText: "", jarvisText: "", detail: nil)
    }

    private func showSettingsPlaceholder() {
        let alert = NSAlert()
        alert.messageText = "Jarvis Settings"
        alert.informativeText = "Voice, Gemini, smart-home, and privacy settings are available in the completed settings panel."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func publishState(detail: String? = nil) {
        windowController.contentController.update(state: state, userText: nil, jarvisText: nil, detail: detail)
        menuBarController.update(state: state, lastRequest: nil, deviceCount: nil)
    }
}

